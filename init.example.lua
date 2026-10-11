-- Copy this into ~/.hammerspoon/init.lua (or append it if you already have one).
package.path = package.path .. ";/Users/ram/coding/opener/?.lua"

require("opener").setup({
  -- every folder in a root becomes a project...
  roots = { "~/coding", "~/coding/www" },
  -- ...except these, which are containers whose subfolders are the projects
  exclude = { "~/coding/www" },
  -- projects = { { name = "dotfiles", path = "~/.dotfiles" } },  -- extras
  -- codeBin = "/opt/homebrew/bin/code",
  -- switchKeys = false,  -- default steps with Option+] / Option+\ (Instant Space Switcher); false = Mission Control
  -- openHotkey = { { "alt", "cmd" }, "o" },   -- picker; ⇧↩ closes the selected project
  -- closeHotkey = { { "alt", "cmd" }, "w" },  -- close the project in the current Space
})
