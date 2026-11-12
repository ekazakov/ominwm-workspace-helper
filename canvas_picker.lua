-- Non-activating palette: keyboard interception exists only while it is visible.
local prefix = (...):match("^(.*%.)") or ""
local Previews = require(prefix .. "window_previews")
local M = {}
function M.new(hs, config, locale, completion, fallback)
    local self = { items = {}, filtered = {}, row = 1, offset = 0, value = "", visible = false }
    self.previews = Previews.new(hs, function() self:draw() end, fallback)
    local types, keys = hs.eventtap.event.types, hs.keycodes.map
    -- hs.keycodes.map logs each fallback lookup on non-Latin layouts.
    -- Resolve keys once; event handlers compare only numeric codes.
    local bindings = {}
    for _, binding in ipairs({ config.hotkey, config.switchHotkey }) do
        local expected = {}
        for _, modifier in ipairs(binding.modifiers) do expected[modifier] = true end
        bindings[#bindings + 1] = { code = keys[binding.key:lower()], modifiers = expected }
    end
    local letters = "asdfghjklqwertyuiopzxcvbnm"
    -- macOS virtual key codes identify physical keys, independent of input layout.
    local letterCodes = { 0, 1, 2, 3, 5, 4, 38, 40, 37, 12, 13, 14, 15,
        17, 16, 32, 34, 31, 35, 6, 7, 8, 9, 11, 45, 46 }
    local letterByCode = {}
    for i, code in ipairs(letterCodes) do letterByCode[code] = letters:sub(i, i) end
    local slashCode = 44

    function self:begin(mode)
        self.previews:resetPanel()
        self.mode = mode or "move"
        self.placeholderKey = self.mode == "switch" and "switchPlaceholder" or "placeholder"
        self.searching, self.pendingPrefix = false, ""
        self.shortcuts, self.shortcutCount, self.shortcutLength = {}, 0, nil
        self.value, self.row, self.offset = "", 1, 0
        return self
    end
    self:begin("move")

    function self:assignShortcuts()
        if self.mode ~= "switch" then return end
        local groups, byId, count = {}, {}, 0
        for _, choice in ipairs(self.items) do
            if choice.workspaceId and choice.valid ~= false then
                local group = choice.displayId or choice.displayName or ""
                if not byId[group] then byId[group] = {}; groups[#groups + 1] = byId[group] end
                byId[group][#byId[group] + 1] = choice
                count = count + 1
            end
        end
        if count == 0 then return end
        if not self.shortcutLength then self.shortcutLength = count > 26 and 2 or 1 end
        for _, group in ipairs(groups) do
            for _, choice in ipairs(group) do
                if not self.shortcuts[choice.workspaceId] and self.shortcutCount < 26 ^ self.shortcutLength then
                    local index = self.shortcutCount
                    local label = letters:sub(index % 26 + 1, index % 26 + 1)
                    if self.shortcutLength == 2 then
                        local first = math.floor(index / 26) + 1
                        label = letters:sub(first, first) .. label
                    end
                    self.shortcuts[choice.workspaceId] = label
                    self.shortcutCount = index + 1
                end
            end
        end
    end

    function self:letter(letter)
        local sequence = self.pendingPrefix .. letter
        self.pendingPrefix = ""
        for index, choice in ipairs(self.filtered) do
            if choice.valid ~= false and self.shortcuts[choice.workspaceId] == sequence then
                self:select(index)
                return
            end
        end
        if self.shortcutLength == 2 and #sequence == 1 then
            for _, choice in ipairs(self.filtered) do
                local label = self.shortcuts[choice.workspaceId]
                if choice.valid ~= false and label and label:sub(1, 1) == sequence then
                    self.pendingPrefix = sequence
                    break
                end
            end
        end
        self:draw()
    end

    local selectAllCode, pasteCode = keys.a, keys.v
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
        local rowHeight = self.mode == "switch" and (Previews.height + 24) or rowHeight
        local rows = self.mode == "switch" and #self.filtered or config.rows
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
                local height = rowHeight
                if self.mode == "switch" and choice.windows and #choice.windows == 0 then
                    height = math.floor(rowHeight / 3 + 0.5)
                end
                local needed = height + (isHeader and groupHeight or 0)
                if y + needed > frame.h - padding then break end
                if isHeader then
                    entries[#entries + 1] = { heading = choice.displayName or "", y = y }
                    y = y + groupHeight
                end
                entries[#entries + 1] = { index = index, choice = choice, y = y, height = height }
                y, previous, last = y + height, group, index
            end
            return entries, last
        end
        local entries, last = layout()
        while self.row > last and self.offset < self.row - 1 do
            self.offset = self.offset + 1
            entries, last = layout()
        end
        self.hitRows = {}
        local visibleWindows = {}
        local heading = self.value == "" and locale:text(self.placeholderKey) or self.value .. "│"
        if self.mode == "switch" then
            if self.searching then heading = locale:text("switchSearch") .. " " .. self.value .. "│"
            elseif self.pendingPrefix ~= "" then heading = locale:text("switchPrefix") .. " " .. self.pendingPrefix .. "…"
            else heading = locale:text("switchLetters") end
        end
        local elements = {
            { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 12, yRadius = 12 },
                fillColor = { white = dark and 0.13 or 0.96, alpha = 0.98 },
                frame = { x = 0, y = 0, w = frame.w, h = frame.h } },
            text(heading,
                20, 17, frame.w - 40, 34, self.mode == "switch" and 16 or 23,
                self.value == "" and muted or foreground),
            { type = "rectangle", action = "fill", fillColor = { white = 0.5, alpha = 0.25 },
                frame = { x = 0, y = header - 1, w = frame.w, h = 1 } },
        }
        if #self.filtered == 0 then
            elements[#elements + 1] = text(locale:text("noDestinations"), 20, header + 16, frame.w - 40, 30, 16, muted)
        end
        local iconWidth = (config.maxIcons + 1) * config.iconSize
        local textX, columnGap, longestLabel = 20, 24, 0
        for _, choice in ipairs(self.mode == "switch" and self.items or self.filtered) do
            if choice.workspaceId then longestLabel = math.max(longestLabel, choice.labelWidth or 0) end
        end
        -- Align all icons after the longest workspace label, rather than the window's right edge.
        -- Reserve space for icons/shortcuts; long labels truncate within the first column.
        local iconX = math.min(textX + longestLabel + columnGap, frame.w - iconWidth - 76)
        local labelWidth = math.max(1, iconX - textX - columnGap)
        if self.mode == "switch" then
            iconX = 20 + 36 + columnGap
            labelWidth = math.min(longestLabel, math.max(1, frame.w - 20 - iconX - 10 - Previews.height))
            textX = frame.w - 20 - labelWidth
            self.previewColumn = { x = iconX, w = math.max(1, textX - 10 - iconX) }
        end
        for _, entry in ipairs(entries) do
            local y = entry.y
            if entry.heading then
                elements[#elements + 1] = text(entry.heading, 20, y + 4, frame.w - 40, 20, 12, muted)
            else
                local index, choice = entry.index, entry.choice
                local rowHeight = entry.height
                self.hitRows[#self.hitRows + 1] = { index = index, top = y, bottom = y + rowHeight - 2 }
                if index == self.row then
                    elements[#elements + 1] = { type = "rectangle", action = "fill",
                        roundedRectRadii = { xRadius = 7, yRadius = 7 },
                        fillColor = { white = dark and 1 or 0, alpha = 0.12 },
                        frame = { x = padding, y = y, w = frame.w - padding * 2, h = rowHeight - 2 } }
                end
                if self.mode == "switch" and choice.workspaceId then
                    local column = self.previewColumn
                    local windows = choice.windows or {}
                    local totalWidth = 0
                    for i, window in ipairs(windows) do
                        visibleWindows[#visibleWindows + 1] = window
                        totalWidth = totalWidth + self.previews:get(window).width + (i > 1 and 12 or 0)
                    end
                    local maxOffset = math.max(0, totalWidth - column.w)
                    local scroll = math.max(0, math.min(self.previews.offsets[choice.workspaceId] or 0, maxOffset))
                    self.previews.offsets[choice.workspaceId] = scroll
                    self.hitRows[#self.hitRows].maxPreviewOffset = maxOffset
                    local previewY, previewX = y + 12, column.x - scroll
                    elements[#elements + 1] = { type = "rectangle", action = "clip",
                        frame = { x = column.x, y = #windows > 0 and previewY or y,
                            w = column.w, h = #windows > 0 and Previews.height or rowHeight } }
                    if #windows == 0 then
                        elements[#elements + 1] = text(locale:text(choice.windows and "emptyWorkspace" or "loadingPreviews"),
                            column.x, y + (rowHeight - 24) / 2, column.w, 24, 16, muted)
                    end
                    for _, window in ipairs(windows) do
                        local preview = self.previews:get(window)
                        if previewX + preview.width > column.x and previewX < column.x + column.w then
                            elements[#elements + 1] = { type = "rectangle", action = "fill",
                                fillColor = { white = 0.5, alpha = 0.15 },
                                frame = { x = previewX, y = previewY, w = preview.width, h = Previews.height } }
                            if preview.image then
                                local w = preview.fallback and math.min(48, preview.width) or preview.width
                                local h = preview.fallback and 48 or Previews.height
                                elements[#elements + 1] = { type = "image", image = preview.image,
                                    imageScaling = "scaleProportionally", frame = {
                                        x = previewX + (preview.width - w) / 2, y = previewY + (Previews.height - h) / 2, w = w, h = h } }
                            end
                        end
                        previewX = previewX + preview.width + 12
                    end
                    elements[#elements + 1] = { type = "resetClip" }
                elseif choice.image then
                    elements[#elements + 1] = { type = "image", image = choice.image,
                        imageScaling = "scaleProportionally", frame = {
                            x = iconX, y = y + (rowHeight - config.iconSize) / 2,
                            w = choice.imageWidth or config.iconSize, h = config.iconSize } }
                end
                elements[#elements + 1] = text(choice.text, choice.workspaceId and textX or 20, y + (self.mode == "switch" and choice.workspaceId and (rowHeight - 24) / 2 or 12),
                    choice.workspaceId and labelWidth or frame.w - 40, 24, 16,
                    self.mode == "switch" and choice.workspaceId and muted or foreground)
                local shortcut
                if choice.workspaceId and choice.valid ~= false then
                    if self.mode == "switch" then shortcut = self.shortcuts[choice.workspaceId]
                    elseif index <= 9 then shortcut = "⌘" .. index end
                end
                if shortcut then
                    if self.mode == "switch" then
                        local badgeX, badgeY, badgeSize = 20, y + (rowHeight - 36) / 2, 36
                        elements[#elements + 1] = { type = "rectangle", action = "fill",
                            roundedRectRadii = { xRadius = 8, yRadius = 8 },
                            fillColor = { white = 0, alpha = 0.4 },
                            frame = { x = badgeX, y = badgeY, w = badgeSize, h = badgeSize } }
                        elements[#elements + 1] = text(shortcut:upper(), badgeX, badgeY + 7,
                            badgeSize, 22, 15, { white = 1, alpha = 1 }, "center")
                    else
                        elements[#elements + 1] = text(shortcut, frame.w - 58, y + 13, 36, 22, 15, muted, "right")
                    end
                end
            end
        end
        canvas:replaceElements((table.unpack or unpack)(elements))
        if self.mode == "switch" then self.previews:update(visibleWindows) end
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
        self:assignShortcuts()
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
        self.previews:resetPanel()
        self.tap:stop()
        canvas:hide()
        canvas:replaceElements()
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
        local width = math.min(screen.w - 40, math.max(320, screen.w * (self.mode == "switch" and 0.9 or config.width / 100)))
        local groups, groupCount = {}, 0
        for _, choice in ipairs(self.items) do
            local id = choice.displayId or choice.displayName or ""
            if choice.workspaceId and not groups[id] then groups[id] = true; groupCount = groupCount + 1 end
        end
        local height = math.min(screen.h - 80, header + padding * 2 + config.rows * rowHeight
            + math.min(config.rows, groupCount) * groupHeight)
        if self.mode == "switch" then height = screen.h - 80 end
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
            local properties = hs.eventtap.event.properties
            local delta = event:getProperty(properties.scrollWheelEventDeltaAxis1)
            if self.mode == "switch" then
                local horizontal = event:getProperty(properties.scrollWheelEventDeltaAxis2)
                if event:getFlags().shift and horizontal == 0 then horizontal = delta end
                if horizontal ~= 0 then
                    local point, column = event:location(), self.previewColumn
                    if column and point.x >= self.frame.x + column.x and point.x < self.frame.x + column.x + column.w then
                        for _, hit in ipairs(self.hitRows or {}) do
                            local y = point.y - self.frame.y
                            local choice = self.filtered[hit.index]
                            if y >= hit.top and y < hit.bottom and choice.workspaceId then
                                local offset = self.previews.offsets[choice.workspaceId] or 0
                                self.previews.offsets[choice.workspaceId] = math.max(0,
                                    math.min(hit.maxPreviewOffset or 0, offset - horizontal * 20))
                                self:draw()
                                break
                            end
                        end
                    end
                    return true
                end
            end
            if delta ~= 0 then self:selectedRow(self.row + (delta < 0 and 1 or -1)) end
            return true
        end
        local code, flags = event:getKeyCode(), event:getFlags()
        -- Leave the configured global hotkey to hs.hotkey, including its key-up.
        for _, binding in ipairs(bindings) do
            local hotkey = code == binding.code
            local expected = binding.modifiers
            for _, modifier in ipairs({ "cmd", "alt", "ctrl", "shift" }) do
                if not not flags[modifier] ~= not not expected[modifier] then hotkey = false end
            end
            if hotkey then return false end
        end
        if kind == types.keyUp then return true end
        local unmodified = not flags.cmd and not flags.ctrl and not flags.alt and not flags.shift and not flags.fn
        if self.mode == "switch" and code == keys.escape then
            if self.searching then
                self.searching, self.pendingPrefix = false, ""
                self:query(""); self:draw()
            elseif self.pendingPrefix ~= "" then self.pendingPrefix = ""; self:draw()
            else self:cancel() end
        elseif self.mode == "switch" and not self.searching and unmodified and code == slashCode then
            self.searching, self.pendingPrefix = true, ""
            self:draw()
        elseif self.mode == "switch" and not self.searching and unmodified and letterByCode[code] then
            self:letter(letterByCode[code])
        elseif code == keys.escape then self:cancel()
        elseif code == keys["return"] or code == keys.padenter then self:select()
        elseif code == keys.up then self:moveSelection(-1)
        elseif code == keys.down then self:moveSelection(1)
        elseif self.mode == "switch" and not self.searching then
            -- Letter mode accepts only navigation and unmodified workspace letters.
            return true
        elseif flags.cmd and code == selectAllCode then self:query("")
        elseif flags.cmd and code == pasteCode then
            local pasted = hs.pasteboard.getContents()
            if pasted then self:query(self.value .. pasted:gsub("[%c]", "")) end
        elseif flags.cmd and not flags.alt and not flags.ctrl then
            local digit = event:getUnicodeString()
            if self.mode ~= "switch" and digit:match("^[1-9]$") then self:select(tonumber(digit)) end
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
    function self:delete() self:hide(); self.previews:clear(); canvas:delete(); self.items, self.filtered = {}, {} end
    return self
end
return M
