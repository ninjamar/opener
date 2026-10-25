-- obsidian: pick an Obsidian vault from a chooser and open it, and open loose
-- files/folders through a git-ignored scratch folder inside a vault.
-- The vault list comes from Obsidian's own config, so there is nothing to
-- configure or keep in sync, and no state is stored here. Which vaults are open
-- is read from Obsidian's window titles ("note - vault - Obsidian 1.x"), since
-- the "open" flag in the config is not kept up to date.

local opener = require("opener")

local M = {}

local CONFIG_PATH = os.getenv("HOME") .. "/Library/Application Support/obsidian/obsidian.json"

local cfg = {}
local chooser
local windowFilter -- all-Spaces Obsidian window filter, so other desktops are visible

local function basename(path)
  return path:match("([^/]+)/*$") or path
end

-- Obsidian windows showing `name`. Titles end in " - <vault> - Obsidian <version>".
local function vaultWindows(name)
  local suffix = " - " .. name
  local found = {}
  for _, w in ipairs(windowFilter:getWindows()) do
    local title = (w:title() or ""):gsub(" %- Obsidian.*$", "")
    if title == name or title:sub(-#suffix) == suffix then found[#found + 1] = w end
  end
  return found
end

-- Vaults Obsidian knows about whose folder still exists, open ones (a window
-- is showing them) first, then most recently used.
local function loadVaults()
  local ok, config = pcall(hs.json.read, CONFIG_PATH)
  if not (ok and type(config) == "table" and type(config.vaults) == "table") then
    return nil
  end
  local vaults = {}
  for id, v in pairs(config.vaults) do
    if v.path and hs.fs.attributes(v.path, "mode") == "directory" then
      local name = basename(v.path)
      vaults[#vaults + 1] = {
        id = id,
        name = name,
        path = v.path,
        ts = v.ts or 0,
        open = #vaultWindows(name) > 0,
      }
    end
  end
  table.sort(vaults, function(a, b)
    if a.open ~= b.open then return a.open end
    if a.ts ~= b.ts then return a.ts > b.ts end
    return a.name:lower() < b.name:lower()
  end)
  return vaults
end

-- Space the vault's window is on (nil if it can't be told).
local function windowSpace(win)
  local spaces = hs.spaces.windowSpaces(win)
  return spaces and spaces[1]
end

local function vaultURL(vault, file)
  local url = "obsidian://open?vault=" .. hs.http.encodeForQuery(vault.id)
  -- paneType=tab: a new tab, instead of replacing the note that's showing
  if file then url = url .. "&file=" .. hs.http.encodeForQuery(file) .. "&paneType=tab" end
  return url
end

local opening = false -- an open into a new Space is in flight

-- Opens the vault (and `file`, a path inside it, if given) in a new Space, or
-- jumps to its Space if it's already open.
function M.open(vault, file)
  if opening then return end

  local existing = vaultWindows(vault.name)[1]
  if existing then
    -- Already open: go to it rather than making a Space. A just-made link needs
    -- a moment to be indexed, or Obsidian may not find the file.
    local function openFile()
      if file then
        opener.after(0.5, function() hs.urlevent.openURL(vaultURL(vault, file)) end)
      end
    end
    local space = windowSpace(existing)
    if space then
      opener.switchTo(space, openFile)
    else
      existing:focus()
      openFile()
    end
    return
  end

  local space = opener.createSpace()
  if not space then return end
  opening = true
  opener.switchTo(space, function()
    local known = {}
    for _, w in ipairs(windowFilter:getWindows()) do known[w:id()] = true end
    hs.urlevent.openURL(vaultURL(vault, file))
    -- Don't drag the view back to the new Space while waiting: macOS may jump to
    -- wherever Obsidian puts its window, and fighting that flips desktops.
    -- Wait for the window, then move it here.
    opener.waitFor(function()
      for _, w in ipairs(vaultWindows(vault.name)) do
        if not known[w:id()] then return w end
      end
    end, 20, function(win)
      opening = false
      if not win then
        hs.alert.show(vault.name .. ": window didn't appear")
        return
      end
      hs.spaces.moveWindowToSpace(win, space)
      opener.switchTo(space)
    end)
  end)
end

-- Closes the vault's window(s), and its Space if nothing else is on it.
-- Accessibility only reliably sees windows on the current Space, so go to the
-- window's Space first.
function M.close(vault)
  local wins = vaultWindows(vault.name)
  if #wins == 0 then
    hs.alert.show(vault.name .. " isn't open")
    return
  end
  local space = windowSpace(wins[1])
  opener.switchTo(space or opener.activeSpace(), function()
    for _, w in ipairs(vaultWindows(vault.name)) do w:close() end
    opener.waitFor(function() return #vaultWindows(vault.name) == 0 end, 5, function(closed)
      if not closed then
        hs.alert.show(vault.name .. ": a window is still open")
      elseif space then
        opener.after(0.3, function() opener.removeSpaceIfEmpty(space) end)
      end
    end)
  end)
end

function M.showPicker()
  local vaults = loadVaults()
  if not vaults or #vaults == 0 then
    hs.alert.show("obsidian: no vaults found in " .. CONFIG_PATH)
    return
  end
  if not chooser then
    chooser = hs.chooser.new(function(choice)
      if not choice then return end
      if hs.eventtap.checkKeyboardModifiers().shift then
        M.close(choice)
      else
        M.open(choice)
      end
    end)
    chooser:placeholderText("Open Obsidian vault (⇧↩ closes)")
  end
  local choices = {}
  for _, v in ipairs(vaults) do
    choices[#choices + 1] = {
      text = (v.open and "● " or "") .. v.name,
      subText = v.path .. (v.open and "  (open — ↩ jumps, ⇧↩ closes)" or ""),
      id = v.id,
      name = v.name,
    }
  end
  chooser:choices(choices)
  chooser:show()
end

-- scratch ---------------------------------------------------------------

local GIT = "/usr/bin/git"
local NOTE_EXTENSIONS = { md = true, canvas = true }

local scratch -- { vault, dir } for the open scratch chooser
local scratchChooser

-- True when `folder` can't end up in a commit: the vault isn't a git repo, or
-- the folder is git-ignored.
local function scratchIsIgnored(vault)
  local q = opener.shellQuote
  local _, inRepo = hs.execute(GIT .. " -C " .. q(vault.path) .. " rev-parse --is-inside-work-tree")
  if not inRepo then return true end
  local _, ignored = hs.execute(GIT .. " -C " .. q(vault.path) .. " check-ignore -q -- " .. q(cfg.scratch.folder .. "/x"))
  return ignored == true
end

-- A typed path as an absolute path (nil unless it looks like a path):
-- trims, drops quotes and shell escapes, expands ~.
local function parsePath(query)
  local q = query:gsub("^%s+", ""):gsub("%s+$", "")
  q = q:match("^'(.*)'$") or q:match('^"(.*)"$') or q
  q = q:gsub("\\(.)", "%1")
  if q:sub(1, 1) ~= "/" and q:sub(1, 1) ~= "~" then return nil end
  q = q:gsub("^~", os.getenv("HOME")):gsub("(.)/+$", "%1")
  return q
end

-- Name to link `target` under in `dir`: the existing link to it if there is
-- one, else its basename, else basename-2, basename-3, ...
local function linkName(dir, target)
  local name = basename(target)
  local base, ext = name:match("^(.*)(%.[^.]+)$")
  if not base then base, ext = name, "" end
  local n = 1
  while true do
    local candidate = n == 1 and name or (base .. "-" .. n .. ext)
    local attrs = hs.fs.symlinkAttributes(dir .. "/" .. candidate)
    if not attrs then return candidate, false end
    if attrs.mode == "link" and attrs.target == target then return candidate, true end
    n = n + 1
  end
end

-- The note to open for scratch entry `name`: the file itself, or for a folder
-- its README.md / index.md / first .md file (nil if it has none).
local function noteFor(name)
  local rel = cfg.scratch.folder .. "/" .. name
  local full = scratch.dir .. "/" .. name
  if hs.fs.attributes(full, "mode") ~= "directory" then return rel end
  local notes, preferred = {}, nil
  for entry in hs.fs.dir(full) do
    local lower = entry:lower()
    if lower:match("%.md$") then notes[#notes + 1] = entry end
    if lower == "readme.md" or (lower == "index.md" and not preferred) then preferred = entry end
  end
  table.sort(notes)
  local note = preferred or notes[1]
  return note and (rel .. "/" .. note)
end

local function openEntry(name)
  local file = noteFor(name)
  if not file then hs.alert.show(name .. ": no notes in this folder, opening the vault") end
  M.open(scratch.vault, file)
end

local function linkAndOpen(target)
  if not scratchIsIgnored(scratch.vault) then
    hs.alert.show(cfg.scratch.folder .. "/ isn't git-ignored in " .. scratch.vault.name
      .. ". Add it to .gitignore first.", 4)
    return
  end
  target = hs.fs.pathToAbsolute(target) or target
  hs.fs.mkdir(scratch.dir)
  local name, exists = linkName(scratch.dir, target)
  if not exists then
    local ok, err = hs.fs.link(target, scratch.dir .. "/" .. name, true)
    if not ok then
      hs.alert.show("obsidian: couldn't link: " .. tostring(err))
      return
    end
  end
  local ext = target:match("%.([^./]+)$")
  if hs.fs.attributes(target, "mode") == "file" and not NOTE_EXTENSIONS[(ext or ""):lower()] then
    hs.alert.show("Obsidian only shows .md and .canvas files; this one may not open", 3)
  end
  openEntry(name)
end

-- Only ever removes the link itself, never what it points to.
local function removeLink(name)
  local full = scratch.dir .. "/" .. name
  local attrs = hs.fs.symlinkAttributes(full)
  if not (attrs and attrs.mode == "link") then
    hs.alert.show(name .. " isn't a link, leaving it alone")
    return
  end
  os.remove(full)
end

local function scratchChoices(query)
  query = query or ""
  local typed = parsePath(query)
  if typed then
    local mode = hs.fs.attributes(typed, "mode")
    local kind = mode == "directory" and "folder" or mode == "file" and "file" or nil
    -- The text is the query itself so the chooser's own filter keeps the row.
    return { {
      text = query,
      subText = kind and ("Link this " .. kind .. " and open it — " .. typed) or "Not found",
      path = kind and typed or nil,
      invalid = not kind,
    } }
  end

  local entries = {}
  if hs.fs.attributes(scratch.dir, "mode") == "directory" then
    for name in hs.fs.dir(scratch.dir) do
      local attrs = name:sub(1, 1) ~= "." and hs.fs.symlinkAttributes(scratch.dir .. "/" .. name)
      if attrs and attrs.mode == "link" then
        entries[#entries + 1] = { name = name, target = attrs.target, modified = attrs.modification or 0 }
      end
    end
  end
  table.sort(entries, function(a, b) return a.modified > b.modified end)

  local choices = {}
  for _, e in ipairs(entries) do
    local mode = hs.fs.attributes(e.target, "mode")
    local sub = not mode and "⚠ broken link — ⇧↩ removes"
      or (e.target .. (mode == "directory" and "  (folder)" or "") .. "  (↩ opens, ⇧↩ removes)")
    choices[#choices + 1] = { text = e.name, subText = sub, link = e.name }
  end
  return choices
end

function M.showScratch()
  local vault
  for _, v in ipairs(loadVaults() or {}) do
    if v.name == cfg.scratch.vault then vault = v end
  end
  if not vault then
    hs.alert.show("obsidian: no vault named " .. cfg.scratch.vault)
    return
  end
  scratch = { vault = vault, dir = vault.path .. "/" .. cfg.scratch.folder }

  if not scratchChooser then
    scratchChooser = hs.chooser.new(function(choice)
      if not choice or choice.invalid then return end
      if choice.link then
        if hs.eventtap.checkKeyboardModifiers().shift then
          removeLink(choice.link)
        else
          openEntry(choice.link)
        end
      elseif choice.path then
        linkAndOpen(choice.path)
      end
    end)
    scratchChooser:placeholderText("Type a full path to a file or folder (⇧↩ removes a link)")
    scratchChooser:queryChangedCallback(function(query)
      scratchChooser:choices(scratchChoices(query))
    end)
  end
  scratchChooser:query(nil)
  scratchChooser:choices(scratchChoices(""))
  scratchChooser:show()
end

function M.setup(opts)
  cfg = opts or {}
  cfg.scratch = cfg.scratch or { vault = "Personal", folder = "_scratch" }
  windowFilter = hs.window.filter.new(false):setAppFilter("Obsidian", {})
  windowFilter:setCurrentSpace(nil)
  local key = cfg.hotkey or { { "alt", "cmd" }, "v" }
  hs.hotkey.bind(key[1], key[2], M.showPicker)
  local scratchKey = cfg.scratchHotkey or { { "alt", "cmd" }, "s" }
  hs.hotkey.bind(scratchKey[1], scratchKey[2], M.showScratch)
  return M
end

return M
