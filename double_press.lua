-- Observe modifier taps without consuming keys or changing the system modifiers.
local M = {}
function M.new(hs, configuration, callback)
    local self = { generation = 0 }
    local expected = {}
    for _, modifier in ipairs(configuration.modifiers) do expected[modifier] = true end
    local function now() return hs.timer.absoluteTime() / 1e6 end
    function self:reset()
        self.generation = self.generation + 1
        self.pressedAt, self.lastTap = nil, nil
        if self.timer then self.timer:stop(); self.timer = nil end
    end
    function self:interrupt(flags)
        self:reset()
        self.invalid = false
        for _, modifier in ipairs({ "ctrl", "alt", "shift", "cmd", "fn" }) do
            if flags[modifier] then self.invalid = true end
        end
    end
    local types = hs.eventtap.event.types
    self.tap = hs.eventtap.new({ types.flagsChanged, types.keyDown, types.leftMouseDown,
        types.rightMouseDown, types.otherMouseDown, types.scrollWheel }, function(event)
        if event:getType() ~= types.flagsChanged then
            self:interrupt(event:getFlags())
            return false
        end
        local flags = event:getFlags()
        local exact, clear, unexpected = true, true, false
        for _, modifier in ipairs({ "ctrl", "alt", "shift", "cmd", "fn" }) do
            if flags[modifier] then clear = false end
            if not not flags[modifier] ~= not not expected[modifier] then exact = false end
            if flags[modifier] and not expected[modifier] then unexpected = true end
        end
        if configuration.keyCode and event:getKeyCode() ~= configuration.keyCode then
            self:interrupt(flags)
            return false
        end
        if unexpected then self:reset(); self.invalid = true end
        if clear then
            local pressedAt = self.pressedAt
            local valid = not self.invalid and pressedAt and now() - pressedAt <= configuration.intervalMs
            self.pressedAt, self.invalid = nil, false
            if valid then
                local timestamp = now()
                if self.lastTap and timestamp - self.lastTap <= configuration.intervalMs then
                    self:reset()
                    callback()
                else
                    self:reset()
                    self.lastTap = timestamp
                    local generation = self.generation
                    self.timer = hs.timer.doAfter(configuration.intervalMs / 1000, function()
                        if generation == self.generation then self:reset() end
                    end)
                end
            elseif pressedAt then self:reset() end
        elseif exact and not self.invalid and not self.pressedAt then
            self.pressedAt = now()
        end
        return false
    end)
    function self:start()
        self:reset(); self.invalid = false
        self.tap:start()
        return self
    end
    function self:stop()
        self:reset(); self.tap:stop()
    end
    return self
end
return M
