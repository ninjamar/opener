# Opener

Quick tools to open/close spaces on my mac. Each project, and each Obsidian vault, gets its own desktop.

[Hammerspoon](https://www.hammerspoon.org) runs everything and [Amethyst](https://ianyh.com/amethyst/) handles layout. Both tools are menus: press the shortcut, type to filter, press Enter.

| Shortcut | Tool | Enter | Shift + Enter |
| --- | --- | --- | --- |
| Option + Command + O | Projects | Open the project, or jump to it if it's open | Close it and remove its desktop |
| Option + Command + V | Obsidian vaults | Open the vault, or jump to it if it's open | Close it and remove its desktop |
| Option + Command + S | Obsidian scratch | Link a file or folder and open it, or open an existing link | Remove the link |

Open items show a `●` and sort first.

## Setup

1. Install Hammerspoon, VS Code (with the `code` command) and iTerm2. Obsidian is only needed for `obsidian.lua`.
2. Copy `init.example.lua` into `~/.hammerspoon/init.lua` and adjust the paths. The options are documented in comments in that file.
3. Give Hammerspoon Accessibility permission. Reload its config.

Moving between desktops uses the Instant Space Switcher shortcuts, Option + `]` and Option + `\`. Set `switchKeys = false` to use Mission Control instead, which is slower.
