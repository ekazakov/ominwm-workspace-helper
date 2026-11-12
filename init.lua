local prefix = (...) and (...):gsub("%.init$", "") .. "." or ""
local defaults = require(prefix .. "config")
local OmniWM = require(prefix .. "omniwm")
local Icons = require(prefix .. "icons")
local Chooser = require(prefix .. "workspace_chooser")
local DoublePress = require(prefix .. "double_press")
local M = {}
local registryKey = "__omniwm_workspace_chooser_instance"

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

function M.new(overrides)
    local config = copy(defaults)
    for key, value in pairs(overrides or {}) do
        assert(defaults[key] ~= nil or key == "cliPath", "Unknown config key: " .. tostring(key))
        config[key] = copy(value)
    end
    for _, key in ipairs({ "maxIcons", "iconSize", "iconCacheLimit", "compositeCacheLimit", "rows" }) do
        assert(type(config[key]) == "number" and config[key] >= 1 and config[key] % 1 == 0, "Invalid " .. key)
    end
    assert(type(config.shortcutSequenceTimeoutMs) == "number" and config.shortcutSequenceTimeoutMs > 0
        and config.shortcutSequenceTimeoutMs % 1 == 0, "Invalid shortcutSequenceTimeoutMs")
    assert(type(config.previewRefreshInterval) == "number" and config.previewRefreshInterval >= 0
        and config.previewRefreshInterval < math.huge, "Invalid previewRefreshInterval")
    assert(type(config.width) == "number" and config.width > 0 and config.width <= 100, "Invalid width")
    assert(config.maxIcons <= 5, "maxIcons must be between 1 and 5")
    assert(config.theme == "dark" or config.theme == "light", "theme must be dark or light")
    assert(type(config.taskTimeout) == "number" and config.taskTimeout > 0, "Invalid taskTimeout")
    assert(type(config.hotkey) == "table" and type(config.hotkey.modifiers) == "table"
        and type(config.hotkey.key) == "string", "Invalid hotkey")
    assert(type(config.switchHotkey) == "table" and type(config.switchHotkey.modifiers) == "table"
        and type(config.switchHotkey.key) == "string", "Invalid switchHotkey")
    local gesture = config.switchDoublePress
    assert(type(gesture) == "table" and type(gesture.enabled) == "boolean"
        and type(gesture.modifiers) == "table" and #gesture.modifiers > 0
        and type(gesture.intervalMs) == "number" and gesture.intervalMs > 0
        and gesture.intervalMs % 1 == 0, "Invalid switchDoublePress")
    assert(gesture.keyCode == nil or (type(gesture.keyCode) == "number" and gesture.keyCode >= 0
        and gesture.keyCode <= 255 and gesture.keyCode % 1 == 0), "Invalid switchDoublePress keyCode")
    local seen = {}
    for _, modifier in ipairs(gesture.modifiers) do
        assert(({ ctrl = true, alt = true, shift = true, cmd = true, fn = true })[modifier]
            and not seen[modifier], "Invalid switchDoublePress modifier")
        seen[modifier] = true
    end
    assert(config.cliPath == nil or type(config.cliPath) == "string", "Invalid cliPath")
    for _, key in ipairs({ "showEmptyWorkspaces", "showCurrentWorkspace", "searchAppNames", "refreshOnOpen", "debug" }) do
        assert(type(config[key]) == "boolean", "Invalid " .. key)
    end
    local self = { config = config, running = false }

    function self:start()
        if self.running then return self end
        local previous = rawget(_G, registryKey)
        if previous and previous ~= self then previous:stop() end
        self.log = hs.logger.new("omniwm-chooser", config.debug and "debug" or "warning")
        self.cli = OmniWM.new(hs, config, self.log)
        self.icons = Icons.new(hs, config)
        self.ui = Chooser.new(hs, config, self.cli, self.icons, self.log)
        self.running = true
        rawset(_G, registryKey, self)
        self.hotkey = hs.hotkey.bind(config.hotkey.modifiers, config.hotkey.key, function() self.ui:toggle() end)
        if config.switchDoublePress.enabled then
            self.doublePress = DoublePress.new(hs, config.switchDoublePress, function()
                if self.running then self.ui:toggle("switch") end
            end):start()
            self.ui.chooser.onInput = function(event)
                if self.doublePress then self.doublePress:interrupt(event:getFlags()) end
            end
            if not self.doublePress.tap:isEnabled() then self.log.w("Cannot observe modifier double press") end
        else
            self.switchHotkey = hs.hotkey.bind(config.switchHotkey.modifiers, config.switchHotkey.key, function() self.ui:toggle("switch") end)
        end
        self.cli:check(function(ok, err)
            if not self.running then return end
            if ok then self.ui:startBackgroundPreviews() else self.log.w("Startup compatibility check failed: " .. tostring(err)) end
        end)
        return self
    end

    function self:toggle() if self.running then self.ui:toggle() end; return self end
    function self:toggleSwitch() if self.running then self.ui:toggle("switch") end; return self end
    function self:stop()
        if not self.running then return self end
        self.running = false
        if self.hotkey then self.hotkey:delete(); self.hotkey = nil end
        if self.switchHotkey then self.switchHotkey:delete(); self.switchHotkey = nil end
        if self.doublePress then self.doublePress:stop(); self.doublePress = nil end
        self.ui:stop()
        self.cli:stop()
        self.icons:stop()
        self.ui, self.cli, self.icons = nil, nil, nil
        if rawget(_G, registryKey) == self then rawset(_G, registryKey, nil) end
        return self
    end
    function self:diagnostics()
        return { running = self.running, cliPath = self.cli and self.cli.path,
            language = self.ui and self.ui.language,
            compatible = self.cli and self.cli.ready or false,
            workspaces = self.ui and self.ui.cache and #self.ui.cache or 0,
            metrics = self.ui and copy(self.ui.metrics) or {},
            iconBuilds = self.icons and self.icons.builds or 0,
            appCacheSize = self.icons and self.icons.apps.size or 0,
            compositeCacheSize = self.icons and self.icons.composites.size or 0 }
    end
    return self
end
return M
