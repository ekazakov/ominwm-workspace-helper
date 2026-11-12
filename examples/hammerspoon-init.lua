-- Copy the project to ~/.hammerspoon/omniwm-workspace-chooser first.
if omniwmWorkspaceChooser then omniwmWorkspaceChooser:stop() end
omniwmWorkspaceChooser = require("omniwm-workspace-chooser").new({
    hotkey = { modifiers = { "ctrl", "alt", "shift" }, key = "W" },
    switchHotkey = { modifiers = { "ctrl", "alt", "shift", "cmd" }, key = "W" },
    switchDoublePress = { enabled = true, modifiers = { "cmd" }, keyCode = 54, intervalMs = 400 },
    shortcutSequenceTimeoutMs = 300,
    maxIcons = 5,
    iconSize = 22,
    -- cliPath = "/opt/homebrew/bin/omniwmctl",
    -- debug = true,
}):start()
