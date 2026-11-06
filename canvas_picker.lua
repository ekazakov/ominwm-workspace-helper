-- Non-activating palette: keyboard interception exists only while it is visible.
local M = {}
function M.new(hs, config, locale, completion)
    local self = { items = {}, filtered = {}, row = 1, offset = 0, value = "", visible = false }
    local types, keys = hs.eventtap.event.types, hs.keycodes.map
    -- hs.keycodes.map logs each fallback lookup on non-Latin layouts.
    -- Resolve keys once; event handlers compare only numeric codes.
    local hotkeyCode = keys[config.hotkey.key:lower()]
    local selectAllCode, pasteCode = keys.a, keys.v
    local expectedModifiers = {}
    for _, modifier in ipairs(config.hotkey.modifiers) do expectedModifiers[modifier] = true end
    local header, rowHeight, padding, groupHeight = 62, math.max(46, config.iconSize + 16), 12, 28
    local dark = config.theme == "dark"
    local foreground = { white = dark and 0.95 or 0.12 }
    local muted = { white = dark and 0.6 or 0.4 }
    local canvas = assert(hs.canvas.new({ x = 0, y = 0, w = 640, h = 400 }))
    canvas:level("overlay"):behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary" }):clickActivating(false)
    self.canvas = canvas
    local function lower(value)
        -- hs.styledtext:lower() returns nil for empty text, unlike string.lower().
        if value == "" then return "" end
        return hs.styledtext.new(value):lower():getString()
    end

    local function text(value, x, y, w, h, size, color, alignment)
        return { type = "text", text = value, textFont = ".AppleSystemUIFont", textSize = size,
            textColor = color or foreground, textAlignment = alignment or "left", textLineBreak = "truncateTail",
            frame = { x = x, y = y, w = math.max(1, w), h = h } }
    end

    function self:draw()
        if not self.visible then return end
        local frame = self.frame
        local rows = config.rows
        self.offset = math.max(0, math.min(self.offset, math.max(0, #self.filtered - 1)))
        if self.row <= self.offset then self.offset = math.max(0, self.row - 1) end
        if self.row > self.offset + rows then self.offset = self.row - rows end
        -- Headers occupy vertical space, but never consume a keyboard selection index.
        local function layout()
            local entries, y, previous, last = {}, header + padding, nil, self.offset
            for index = self.offset + 1, math.min(#self.filtered, self.offset + rows) do
                local choice = self.filtered[index]
                local group = choice.displayId or choice.displayName or ""
                local isHeader = choice.workspaceId and group ~= previous
                local needed = rowHeight + (isHeader and groupHeight or 0)
                if y + needed > frame.h - padding then break end
                if isHeader then
                    entries[#entries + 1] = { heading = choice.displayName or "", y = y }
                    y = y + groupHeight
                end
                entries[#entries + 1] = { index = index, choice = choice, y = y }
                y, previous, last = y + rowHeight, group, index
            end
            return entries, last
        end
        local entries, last = layout()
        while self.row > last and self.offset < self.row - 1 do
            self.offset = self.offset + 1
            entries, last = layout()
        end
        self.hitRows = {}
        local elements = {
            { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 12, yRadius = 12 },
                fillColor = { white = dark and 0.13 or 0.96, alpha = 0.98 },
                frame = { x = 0, y = 0, w = frame.w, h = frame.h } },
            text(self.value == "" and locale:text("placeholder") or self.value .. "│",
                20, 17, frame.w - 40, 34, 23, self.value == "" and muted or foreground),
            { type = "rectangle", action = "fill", fillColor = { white = 0.5, alpha = 0.25 },
                frame = { x = 0, y = header - 1, w = frame.w, h = 1 } },
        }
        if #self.filtered == 0 then
            elements[#elements + 1] = text(locale:text("noDestinations"), 20, header + 16, frame.w - 40, 30, 16, muted)
        end
        local iconWidth = (config.maxIcons + 1) * config.iconSize
        local textX, columnGap, longestLabel = 20, 24, 0
        for _, choice in ipairs(self.filtered) do
            if choice.workspaceId then longestLabel = math.max(longestLabel, choice.labelWidth or 0) end
        end
        -- Align all icons after the longest workspace label, rather than the window's right edge.
        -- Reserve space for icons/shortcuts; long labels truncate within the first column.
        local iconX = math.min(textX + longestLabel + columnGap, frame.w - iconWidth - 76)
        local labelWidth = math.max(1, iconX - textX - columnGap)
        for _, entry in ipairs(entries) do
            local y = entry.y
            if entry.heading then
                elements[#elements + 1] = text(entry.heading, 20, y + 4, frame.w - 40, 20, 12, muted)
            else
                local index, choice = entry.index, entry.choice
                self.hitRows[#self.hitRows + 1] = { index = index, top = y, bottom = y + rowHeight - 2 }
                if index == self.row then
                    elements[#elements + 1] = { type = "rectangle", action = "fill",
                        roundedRectRadii = { xRadius = 7, yRadius = 7 },
                        fillColor = { white = dark and 1 or 0, alpha = 0.12 },
                        frame = { x = padding, y = y, w = frame.w - padding * 2, h = rowHeight - 2 } }
                end
                if choice.image then
                    elements[#elements + 1] = { type = "image", image = choice.image,
                        imageScaling = "scaleProportionally", frame = {
                            x = iconX, y = y + (rowHeight - config.iconSize) / 2,
                            w = choice.imageWidth or config.iconSize, h = config.iconSize } }
                end
                elements[#elements + 1] = text(choice.text, textX, y + 12,
                    choice.workspaceId and labelWidth or frame.w - 40, 24, 16)
                if index <= 9 and choice.valid ~= false then
                    -- Native chooser uses 25 pt; 15 pt is exactly 40% smaller.
                    elements[#elements + 1] = text("⌘" .. index, frame.w - 58, y + 13, 36, 22, 15, muted, "right")
                end
            end
        end
        canvas:replaceElements((table.unpack or unpack)(elements))
    end

    function self:filter(selectedId)
        local query = lower(self.value)
        self.filtered = {}
        local groups, byId = {}, {}
        for _, choice in ipairs(self.items) do
            if query == "" or choice.foldedText:find(query, 1, true) then
                local id = choice.displayId or choice.displayName or ""
                if not byId[id] then byId[id] = {}; groups[#groups + 1] = byId[id] end
                byId[id][#byId[id] + 1] = choice
            end
        end
        for _, group in ipairs(groups) do
            for _, choice in ipairs(group) do self.filtered[#self.filtered + 1] = choice end
        end
        self.row = math.max(1, math.min(self.row, #self.filtered))
        if selectedId then
            for index, choice in ipairs(self.filtered) do
                if choice.workspaceId == selectedId then self.row = index; break end
            end
        end
        self:draw()
    end
    function self:query(value)
        if value == nil then return self.value end
        if self.value ~= value then self.value, self.row, self.offset = value, 1, 0; self:filter() end
        return self
    end
    function self:choices(items)
        local selected = self:selectedRowContents()
        self.items = items
        for _, choice in ipairs(items) do
            choice.foldedText = lower(choice.searchText or choice.text)
            -- Measure once per data refresh with the same font used by workspace rows.
            if choice.workspaceId then
                local label = hs.styledtext.new(choice.text, { font = { name = ".AppleSystemUIFont", size = 16 } })
                choice.labelWidth = math.ceil(canvas:minimumTextSize(label).w)
            end
        end
        self:filter(selected.workspaceId)
        return self
    end
    function self:selectedRow(row)
        if not row then return self.row end
        self.row = math.max(1, math.min(row, #self.filtered)); self:draw(); return self
    end
    function self:moveSelection(step)
        local count = #self.filtered
        if count == 0 then return end
        local row = self.row
        for _ = 1, count do
            row = (row - 1 + step) % count + 1
            local choice = self.filtered[row]
            if choice.workspaceId and choice.valid ~= false then
                if row ~= self.row then self:selectedRow(row) end
                return
            end
        end
    end
    function self:selectedRowContents(row) return self.filtered[row or self.row] or {} end
    function self:isVisible() return self.visible end
    function self:hide()
        self.visible = false
        self.tap:stop()
        canvas:hide()
    end
    function self:cancel() self:hide(); completion(nil); return self end
    function self:select(row)
        local choice = self:selectedRowContents(row)
        if not choice.workspaceId or choice.valid == false then return end
        self:hide()
        completion(choice)
    end
    function self:show()
        if hs.eventtap.isSecureInputEnabled() then
            self:cancel(); hs.alert.show(locale:text("keyboardUnavailable"), 4); return self
        end
        local screen = hs.screen.mainScreen():frame()
        local width = math.min(screen.w - 40, math.max(320, screen.w * config.width / 100))
        local groups, groupCount = {}, 0
        for _, choice in ipairs(self.items) do
            local id = choice.displayId or choice.displayName or ""
            if choice.workspaceId and not groups[id] then groups[id] = true; groupCount = groupCount + 1 end
        end
        local height = math.min(screen.h - 80, header + padding * 2 + config.rows * rowHeight
            + math.min(config.rows, groupCount) * groupHeight)
        self.frame = { x = screen.x + (screen.w - width) / 2, y = screen.y + math.max(20, (screen.h - height) / 3),
            w = width, h = height }
        canvas:frame(self.frame)
        self.visible = true
        self:draw()
        self.tap:start()
        if not self.tap:isEnabled() then
            self:cancel(); hs.alert.show(locale:text("keyboardUnavailable"), 4); return self
        end
        canvas:show()
        return self
    end

    self.tap = hs.eventtap.new({ types.keyDown, types.keyUp, types.mouseMoved, types.leftMouseDown, types.rightMouseDown,
        types.scrollWheel }, function(event)
        if not self.visible then return false end
        local kind = event:getType()
        if kind == types.mouseMoved then
            local point, f = event:location(), self.frame
            if point.x >= f.x + padding and point.x < f.x + f.w - padding then
                local y = point.y - f.y
                for _, hit in ipairs(self.hitRows or {}) do
                    if y >= hit.top and y < hit.bottom then
                        local choice = self.filtered[hit.index]
                        if choice and choice.workspaceId and choice.valid ~= false and hit.index ~= self.row then
                            self:selectedRow(hit.index)
                        end
                        break
                    end
                end
            end
            return false
        end
        if kind == types.leftMouseDown or kind == types.rightMouseDown then
            local point, f = event:location(), self.frame
            if point.x < f.x or point.x > f.x + f.w or point.y < f.y or point.y > f.y + f.h then
                self:cancel(); return false
            end
            if kind == types.leftMouseDown then
                local y = point.y - f.y
                for _, hit in ipairs(self.hitRows or {}) do
                    if y >= hit.top and y < hit.bottom then self:select(hit.index); break end
                end
            end
            return true
        end
        if kind == types.scrollWheel then
            local delta = event:getProperty(hs.eventtap.event.properties.scrollWheelEventDeltaAxis1)
            if delta ~= 0 then self:selectedRow(self.row + (delta < 0 and 1 or -1)) end
            return true
        end
        local code, flags = event:getKeyCode(), event:getFlags()
        -- Leave the configured global hotkey to hs.hotkey, including its key-up.
        local hotkey = code == hotkeyCode
        for _, modifier in ipairs({ "cmd", "alt", "ctrl", "shift" }) do
            if not not flags[modifier] ~= not not expectedModifiers[modifier] then hotkey = false end
        end
        if hotkey then return false end
        if kind == types.keyUp then return true end
        if code == keys.escape then self:cancel()
        elseif code == keys["return"] or code == keys.padenter then self:select()
        elseif code == keys.up then self:moveSelection(-1)
        elseif code == keys.down then self:moveSelection(1)
        elseif flags.cmd and code == selectAllCode then self:query("")
        elseif flags.cmd and code == pasteCode then
            local pasted = hs.pasteboard.getContents()
            if pasted then self:query(self.value .. pasted:gsub("[%c]", "")) end
        elseif flags.cmd and not flags.alt and not flags.ctrl then
            local digit = event:getUnicodeString()
            if digit:match("^[1-9]$") then self:select(tonumber(digit)) end
        elseif code == keys.delete or code == keys.forwarddelete then
            if flags.cmd then self:query("")
            elseif flags.alt then self:query(self.value:gsub("%s*%S+%s*$", ""))
            else self:query(self.value:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")) end
        elseif not flags.cmd and not flags.ctrl then
            local character = event:getUnicodeString()
            if character and character ~= "" and not character:find("%c") then self:query(self.value .. character) end
        end
        return true
    end)
    function self:delete() self:hide(); canvas:delete(); self.items, self.filtered = {}, {} end
    return self
end
return M
