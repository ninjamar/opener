-- opener: open/close a project as its own macOS Space with VS Code + iTerm2.
-- Amethyst does the tiling; this only creates the Space and puts the windows in it.
--
-- Open projects are detected from what is actually on each Space (VS Code window
-- titles, iTerm working directories), not from stored state. The only thing
-- stored is a recents list, in ~/.local/state/opener/recent.json.

local M = {}

local VSCODE_BUNDLE = "com.microsoft.VSCode"
local ITERM_BUNDLE = "com.googlecode.iterm2"
local SPACE_SETTLE = 0.8 -- wait after a Mission Control switch (hs.spaces.gotoSpace)
local ARRIVE_SETTLE = 0.2 -- wait after a keyboard switch, for windows to become visible
local RECENT_DIR = os.getenv("HOME") .. "/.local/state/opener"
local RECENT_PATH = RECENT_DIR .. "/recent.json"

local cfg = {}
local recent = {} -- project path -> last-used unix time
local codeTitles = {} -- VS Code window id -> last seen title
local codeFilter -- all-Spaces VS Code window filter, kept alive for title lookups
local chooser
local spaceHistory = {} -- Space ids, most recently visited first
local spaceWatcher

-- helpers ---------------------------------------------------------------

local function expand(path)
  return (path:gsub("^~", os.getenv("HOME")))
end

local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

-- hs.timer.doAfter timers are garbage-collected unless something holds them.
local pending = {}
local function after(seconds, fn)
  local t
  t = hs.timer.doAfter(seconds, function()
    pending[t] = nil
    fn()
  end)
  pending[t] = true
end

-- Poll `fn` every `interval` (default 0.2s) until it returns a truthy value or
-- `timeout` passes.
local function waitFor(fn, timeout, done, interval)
  interval = interval or 0.2
  local waited = 0
  local timer
  timer = hs.timer.doEvery(interval, function()
    waited = waited + interval
    local result = fn()
    if result or waited >= timeout then
      timer:stop()
      done(result)
    end
  end)
end

local function setOf(list)
  local s = {}
  for _, v in ipairs(list or {}) do s[v] = true end
  return s
end

-- switching ---------------------------------------------------------------

local function activeSpace()
  return hs.spaces.activeSpaceOnScreen(hs.screen.mainScreen())
end

-- Go to `space`, then call `done`. Steps with the Instant Space Switcher
-- shortcuts (no animation, no Mission Control); falls back to gotoSpace.
local function switchTo(space, done)
  done = done or function() end
  local current = activeSpace()
  if current == space then return after(0, done) end

  local function viaMissionControl()
    hs.spaces.gotoSpace(space)
    after(SPACE_SETTLE, done)
  end

  local keys = cfg.switchKeys
  local from, to
  for i, id in ipairs(hs.spaces.spacesForScreen(hs.screen.mainScreen()) or {}) do
    if id == current then from = i end
    if id == space then to = i end
  end
  if not (keys and from and to) then return viaMissionControl() end

  local key = to > from and keys.right or keys.left
  for _ = 1, math.abs(to - from) do
    hs.eventtap.keyStroke(key[1], key[2], 60000)
    hs.timer.usleep(60000)
  end
  waitFor(function() return activeSpace() == space end, 1.0, function(arrived)
    if arrived then after(ARRIVE_SETTLE, done) else viaMissionControl() end
  end, 0.05)
end

local function rememberSpace()
  local id = activeSpace()
  if not id then return end
  for i, v in ipairs(spaceHistory) do
    if v == id then table.remove(spaceHistory, i) break end
  end
  table.insert(spaceHistory, 1, id)
  spaceHistory[21] = nil
end

-- recents -----------------------------------------------------------------

local function loadRecent()
  local ok, t = pcall(hs.json.read, RECENT_PATH)
  recent = (ok and type(t) == "table") and t or {}
end

local function touch(path)
  recent[path] = os.time()
  hs.execute("mkdir -p " .. shellQuote(RECENT_DIR))
  hs.json.write(recent, RECENT_PATH, true, true)
end

-- projects ----------------------------------------------------------------

local function discoverProjects()
  local found, seen = {}, {}
  local function add(name, path)
    if not seen[path] then
      seen[path] = true
      found[#found + 1] = { name = name, path = path }
    end
  end
  for _, p in ipairs(cfg.projects or {}) do
    add(p.name, expand(p.path))
  end
  local excluded = {}
  for _, path in ipairs(cfg.exclude or {}) do excluded[expand(path)] = true end
  for _, root in ipairs(cfg.roots or {}) do
    root = expand(root)
    local ok, iter, dir = pcall(hs.fs.dir, root)
    if ok then
      for entry in iter, dir do
        local full = root .. "/" .. entry
        if entry:sub(1, 1) ~= "." and not excluded[full] then
          local attrs = hs.fs.attributes(full)
          if attrs and attrs.mode == "directory" then add(entry, full) end
        end
      end
    end
  end
  return found
end

-- detection ---------------------------------------------------------------

-- VS Code titles look like "file — folder" (or just "folder").
local function folderFromTitle(title)
  local sep, last, i = " — ", 1, 1
  while true do
    local s, e = title:find(sep, i, true)
    if not s then break end
    last, i = e + 1, e + 1
  end
  local folder = title:sub(last)
  folder = folder:gsub(" %(Workspace%)$", ""):gsub(" %[.-%]$", "")
  return folder
end

local function matchTitle(projects, title)
  local folder = folderFromTitle(title)
  for _, p in ipairs(projects) do
    if basename(p.path) == folder then return p end
  end
end

-- Longest project path that contains `cwd`.
local function matchCwd(projects, cwd)
  local best
  for _, p in ipairs(projects) do
    if cwd == p.path or cwd:sub(1, #p.path + 1) == p.path .. "/" then
      if not best or #p.path > #best.path then best = p end
    end
  end
  return best
end

-- iTerm window id -> working directory (iTerm's window ids are CGWindowIDs).
local function itermCwds()
  local ok, out = hs.osascript.applescript([[
    if application "iTerm" is not running then return ""
    set res to ""
    tell application "iTerm"
      repeat with w in windows
        try
          set s to current session of w
          tell s to set p to (variable named "path")
          set res to res & (id of w) & "|" & p & linefeed
        end try
      end repeat
    end tell
    return res
  ]])
  local cwds = {}
  if ok and type(out) == "string" then
    for line in out:gmatch("[^\r\n]+") do
      local id, path = line:match("^(%d+)|(.*)$")
      if id then cwds[tonumber(id)] = path end
    end
  end
  return cwds
end

-- Accessibility only reliably shows windows on the current Space, so remember
-- titles whenever we see them.
local function refreshCodeTitles()
  local function add(w)
    if w and w:isStandard() then
      local t = w:title()
      if t and t ~= "" then codeTitles[w:id()] = t end
    end
  end
  local app = hs.application.get(VSCODE_BUNDLE)
  if app then
    for _, w in ipairs(app:allWindows()) do add(w) end
  end
  if codeFilter then
    for _, w in ipairs(codeFilter:getWindows()) do add(w) end
  end

  -- On the current Space we can see every VS Code window, so a cached title
  -- whose window is gone is stale (a closed window's ID can linger).
  local live = {}
  if app then
    for _, w in ipairs(app:allWindows()) do live[w:id()] = true end
  end
  for _, id in ipairs(hs.spaces.windowsForSpace(activeSpace()) or {}) do
    if codeTitles[id] and not live[id] then codeTitles[id] = nil end
  end
end

local function userSpaces()
  local list = {}
  for _, ids in pairs(hs.spaces.allSpaces() or {}) do
    for _, id in ipairs(ids) do
      if hs.spaces.spaceType(id) == "user" then list[#list + 1] = id end
    end
  end
  return list
end

-- Returns project path -> Space id for every project that is currently open.
function M.detect()
  local projects = discoverProjects()
  refreshCodeTitles()
  local cwds = itermCwds()
  local found = {}
  for _, space in ipairs(userSpaces()) do
    local byCode, byTerm
    for _, id in ipairs(hs.spaces.windowsForSpace(space) or {}) do
      if codeTitles[id] then
        byCode = byCode or matchTitle(projects, codeTitles[id])
      elseif cwds[id] then
        byTerm = byTerm or matchCwd(projects, cwds[id])
      end
    end
    local p = byCode or byTerm
    if p and not found[p.path] then found[p.path] = space end
  end
  return found
end

-- IDs of windows the apps themselves say exist. windowsForSpace() can keep
-- listing a window's ID after it has closed, so don't use it to check that.
-- (VS Code windows are only visible to us when their Space is the current one.)
local function liveWindowIds()
  local live = {}
  local code = hs.application.get(VSCODE_BUNDLE)
  if code then
    for _, w in ipairs(code:allWindows()) do
      if w:isStandard() then live[w:id()] = true end
    end
  end
  for id in pairs(itermCwds()) do live[id] = true end
  return live
end

-- launching -------------------------------------------------------------

local function windowIds(bundle)
  local ids = {}
  local app = hs.application.get(bundle)
  if app then
    for _, w in ipairs(app:allWindows()) do
      if w:isStandard() then ids[w:id()] = true end
    end
  end
  return ids
end

local function newWindow(bundle, known)
  local app = hs.application.get(bundle)
  if not app then return nil end
  for _, w in ipairs(app:allWindows()) do
    if w:isStandard() and not known[w:id()] then return w end
  end
end

-- Keep us on the project's Space (opening an app can make macOS jump away).
local switching = false
local function ensureOnSpace(space)
  if switching or activeSpace() == space then return end
  switching = true
  switchTo(space, function() switching = false end)
end

local function launchITerm(path)
  local cmd = ("cd %s && clear"):format(shellQuote(path))
  cmd = cmd:gsub("\\", "\\\\"):gsub('"', '\\"')
  hs.osascript.applescript(([[
    set wasRunning to application "iTerm" is running
    tell application "iTerm"
      if not wasRunning then
        activate
        repeat 50 times
          if (count of windows) > 0 then exit repeat
          delay 0.1
        end repeat
      else
        create window with default profile
      end if
      tell current session of current window to write text "%s"
    end tell
  ]]):format(cmd))
end

-- Opens VS Code then iTerm (so Amethyst makes VS Code the main pane) and
-- moves both windows into `space`.
local function launchInto(p, space)
  switchTo(space, function()
    local wins = {}
    local codeKnown = windowIds(VSCODE_BUNDLE)
    hs.task.new(cfg.codeBin, nil, { "-n", p.path }):start()
    waitFor(function()
      ensureOnSpace(space)
      return newWindow(VSCODE_BUNDLE, codeKnown)
    end, 20, function(codeWin)
      if codeWin then wins[#wins + 1] = codeWin end

      local termKnown = windowIds(ITERM_BUNDLE)
      launchITerm(p.path)
      waitFor(function()
        ensureOnSpace(space)
        return newWindow(ITERM_BUNDLE, termKnown)
      end, 20, function(termWin)
        if termWin then wins[#wins + 1] = termWin end
        if #wins < 2 then
          hs.alert.show(p.name .. ": only " .. #wins .. " of 2 windows appeared")
        end
        for _, w in ipairs(wins) do hs.spaces.moveWindowToSpace(w, space) end
        switchTo(space)
      end)
    end)
  end)
end

-- public actions --------------------------------------------------------

function M.open(p)
  touch(p.path)
  local existing = M.detect()[p.path]
  if existing then
    switchTo(existing)
    return
  end

  local screen = hs.screen.mainScreen()
  local before = setOf(hs.spaces.spacesForScreen(screen))
  local ok, err = hs.spaces.addSpaceToScreen(screen, true)
  if not ok then
    hs.alert.show("opener: couldn't create a Space: " .. tostring(err))
    return
  end
  local space
  for _, id in ipairs(hs.spaces.spacesForScreen(screen) or {}) do
    if not before[id] then space = id end
  end
  if not space then
    hs.alert.show("opener: couldn't find the new Space")
    return
  end
  launchInto(p, space)
end

-- A Space to land on after `space` is removed: the regular desktop you were
-- last on, else the nearest one (preferring the left). Never a full-screen
-- Space: Mission Control can't remove a desktop while one of those is active.
local function neighbourSpace(space)
  local list = hs.spaces.spacesForScreen(hs.screen.mainScreen()) or {}
  local exists = setOf(list)
  for _, id in ipairs(spaceHistory) do
    if id ~= space and exists[id] and hs.spaces.spaceType(id) == "user" then return id end
  end
  local at
  for i, id in ipairs(list) do
    if id == space then at = i end
  end
  if not at then return list[1] end
  for d = 1, #list do
    for _, i in ipairs({ at - d, at + d }) do
      local id = list[i]
      if id and hs.spaces.spaceType(id) == "user" then return id end
    end
  end
end

function M.close(p)
  local space = M.detect()[p.path]
  if not space then
    hs.alert.show(p.name .. " isn't open")
    return
  end

  -- Go there first: Accessibility only sees windows on the current Space.
  switchTo(space, function()
    local inSpace = setOf(hs.spaces.windowsForSpace(space))
    local targets = {}

    local code = hs.application.get(VSCODE_BUNDLE)
    if code then
      for _, w in ipairs(code:allWindows()) do
        if w:isStandard() and inSpace[w:id()] then
          targets[w:id()] = true
          w:close()
        end
      end
    end
    for id in pairs(itermCwds()) do
      if inSpace[id] then
        targets[id] = true
        hs.osascript.applescript(([[
          tell application "iTerm" to close (first window whose id is %d)
        ]]):format(id))
      end
    end

    waitFor(function()
      local live = liveWindowIds()
      for id in pairs(targets) do
        if live[id] then return false end
      end
      return true
    end, 5, function(allClosed)
      if not allClosed then
        -- e.g. VS Code is asking about unsaved files; keep the Space.
        hs.alert.show(p.name .. ": a window is still open (unsaved changes?), keeping Space")
        return
      end
      local dest = neighbourSpace(space)
      switchTo(dest, function()
        hs.spaces.removeSpace(space, true)
      end)
    end)
  end)
end

function M.closeCurrent()
  local current = activeSpace()
  local open = M.detect()
  for _, p in ipairs(discoverProjects()) do
    if open[p.path] == current then
      M.close(p)
      return
    end
  end
  hs.alert.show("opener: no open project on this Space")
end

-- picker ----------------------------------------------------------------

local function buildChoices()
  local open = M.detect()
  local current = activeSpace()
  local projects = discoverProjects()

  -- Using a project's Space counts as recent use.
  for _, p in ipairs(projects) do
    if open[p.path] == current then touch(p.path) end
  end

  table.sort(projects, function(a, b)
    local ao, bo = open[a.path] ~= nil, open[b.path] ~= nil
    if ao ~= bo then return ao end
    local ar, br = recent[a.path] or 0, recent[b.path] or 0
    if ar ~= br then return ar > br end
    return a.name:lower() < b.name:lower()
  end)

  local choices = {}
  for _, p in ipairs(projects) do
    local space = open[p.path]
    local sub = p.path
    if space then
      sub = sub .. (space == current and "  (this Space — ⇧↩ closes)" or "  (open — ↩ jumps, ⇧↩ closes)")
    end
    choices[#choices + 1] = {
      text = (space and "● " or "") .. p.name,
      subText = sub,
      name = p.name,
      path = p.path,
    }
  end
  return choices
end

function M.showPicker()
  if not chooser then
    chooser = hs.chooser.new(function(choice)
      if not choice then return end
      local p = { name = choice.name, path = choice.path }
      if hs.eventtap.checkKeyboardModifiers().shift then
        M.close(p)
      else
        M.open(p)
      end
    end)
    chooser:placeholderText("Open project (⇧↩ closes)")
  end
  chooser:choices(buildChoices())
  chooser:show()
end

-- setup -----------------------------------------------------------------

function M.setup(opts)
  cfg = opts or {}
  cfg.codeBin = cfg.codeBin or "/opt/homebrew/bin/code"
  cfg.roots = cfg.roots or { "~/coding" }
  -- Instant Space Switcher: Option+] = one desktop left, Option+\ = one right.
  -- Set switchKeys = false to always use Mission Control instead.
  if cfg.switchKeys == nil then
    cfg.switchKeys = { left = { { "alt" }, "]" }, right = { { "alt" }, "\\" } }
  end
  loadRecent()

  -- How long Hammerspoon lingers in Mission Control between steps (default 0.3).
  hs.spaces.MCwaitTime = cfg.mcWaitTime or 0.1

  rememberSpace()
  spaceWatcher = hs.spaces.watcher.new(rememberSpace)
  spaceWatcher:start()

  codeFilter = hs.window.filter.new(false):setAppFilter("Code", {})
  codeFilter:setCurrentSpace(nil)

  local open = cfg.openHotkey or { { "alt", "cmd" }, "o" }
  local close = cfg.closeHotkey or { { "alt", "cmd" }, "w" }
  hs.hotkey.bind(open[1], open[2], M.showPicker)
  hs.hotkey.bind(close[1], close[2], M.closeCurrent)
  return M
end

return M
