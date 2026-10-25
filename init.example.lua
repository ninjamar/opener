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
})

-- Vault picker; vaults are read from Obsidian's own config.
require("obsidian").setup({
  -- hotkey = { { "alt", "cmd" }, "v" },
  -- scratch = { vault = "Personal", folder = "_scratch" },  -- must be git-ignored in the vault
  -- scratchHotkey = { { "alt", "cmd" }, "s" },  -- link a loose file/folder into scratch and open it
})
