-- Previews stay in memory until the helper stops.
local M = { height = 90 }
local function ratio(size)
    local w, h = size and size.w, size and size.h
    if type(w) == "number" and type(h) == "number" and w > 0 and h > 0
        and w < math.huge and h < math.huge then return w / h end
    return 1
end
local function key(window)
    return tostring(window.id) .. ":" .. tostring(window.windowId)
end
function M.new(hs, changed, fallback)
    local self = { images = {}, offsets = {}, generation = 0 }
    function self:clear()
        self.generation = self.generation + 1
        if self.timer then self.timer:stop(); self.timer = nil end
        self.images, self.offsets, self.visible, self.pending = {}, {}, {}, {}
        self.dirty = false
    end
    function self:get(window)
        local cached = self.images[key(window)]
        if cached then return cached end
        return { width = M.height * ratio(window.frame) }
    end
    function self:resetPanel()
        self.offsets, self.visible = {}, {}
    end
    function self:sync(windows, refresh)
        local live = {}
        for _, window in ipairs(windows) do
            local id = key(window)
            live[id] = true
            if refresh or not self.images[id] then self.pending[id] = window end
        end
        for id in pairs(self.images) do
            if not live[id] then self.images[id] = nil end
        end
        for id in pairs(self.pending) do
            if not live[id] then self.pending[id] = nil end
        end
        local visible = {}
        for _, window in ipairs(self.visible) do
            if live[key(window)] then visible[#visible + 1] = window end
        end
        self.visible = visible
        self:schedule()
    end
    function self:update(windows)
        self.visible = windows
        self:schedule()
    end
    function self:schedule()
        if self.timer then return end
        local function nextWindow()
            -- Fill blank previews before refreshing images that are already usable.
            for _, window in ipairs(self.visible) do
                if not self.images[key(window)] then return window end
            end
            for _, window in ipairs(self.visible) do
                if self.pending[key(window)] then return window end
            end
            local _, window = next(self.pending)
            return window
        end
        if not nextWindow() then return end
        local generation = self.generation
        self.timer = hs.timer.doAfter(0, function()
            if generation ~= self.generation then return end
            self.timer = nil
            local window = nextWindow()
            if not window then return end
            self.pending[key(window)] = nil
            local result = { width = M.height * ratio(window.frame) }
            local ok, image
            if window.windowId then ok, image = pcall(hs.window.snapshotForID, window.windowId) end
            if ok and image then
                local resized, value = pcall(function()
                    local size = image:size()
                    assert(size and size.w > 0 and size.h > 0, "Invalid snapshot dimensions")
                    result.width = M.height * ratio(size)
                    return image:size({ w = result.width, h = M.height }, true)
                end)
                if resized then result.image = value end
            end
            local previous = self.images[key(window)]
            if not result.image and previous and previous.image and not previous.fallback then
                result = previous
            end
            if not result.image then
                result.fallback = true
                if fallback then
                    local found, icon = pcall(fallback, window.bundleId)
                    if found then result.image = icon end
                end
            end
            if generation ~= self.generation then return end
            self.images[key(window)] = result
            for _, candidate in ipairs(self.visible) do
                if key(candidate) == key(window) then self.dirty = true; break end
            end
            -- Publish visible previews together instead of rebuilding the canvas per capture.
            local visiblePending = false
            for _, candidate in ipairs(self.visible) do
                if self.pending[key(candidate)] or not self.images[key(candidate)] then
                    visiblePending = true
                    break
                end
            end
            if not visiblePending and self.dirty then
                self.dirty = false
                changed()
            end
            self:schedule()
        end)
    end
    self:clear()
    return self
end
return M
