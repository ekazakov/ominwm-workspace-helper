-- Copy the project to ~/.hammerspoon/omniwm-workspace-chooser first.
if omniwmWorkspaceChooser then omniwmWorkspaceChooser:stop() end
omniwmWorkspaceChooser = require("omniwm-workspace-chooser").new({
    hotkey = { modifiers = { "ctrl", "alt", "shift" }, key = "W" },
    maxIcons = 5,
    iconSize = 22,
    -- cliPath = "/opt/homebrew/bin/omniwmctl",
    -- debug = true,
}):start()
