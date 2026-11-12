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
    local globalBindings = { config.hotkey }
    if not config.switchDoublePress.enabled then globalBindings[#globalBindings + 1] = config.switchHotkey end
    for _, binding in ipairs(globalBindings) do
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

    local function targetKey(choice, window)
        if window then return "window:" .. tostring(window.id) .. ":" .. tostring(window.windowId) end
        return choice.workspaceId
    end
    local function targets(choice)
        if not choice.workspaceId or choice.valid == false or not choice.windows then return {} end
        if #choice.windows == 0 then return { { key = targetKey(choice) } } end
        local out = {}
        for i, window in ipairs(choice.windows) do
            if window.id and window.windowId then
                out[#out + 1] = { key = targetKey(choice, window), window = window, index = i }
            end
        end
        return out
    end
    local function nowMs() return hs.timer.absoluteTime() / 1e6 end

    function self:resetSequence(redraw)
        local hadPrefix = self.pendingPrefix and self.pendingPrefix ~= ""
        if self.sequenceTimer then self.sequenceTimer:stop(); self.sequenceTimer = nil end
        self.sequenceGeneration = (self.sequenceGeneration or 0) + 1
        self.pendingPrefix, self.sequenceDeadline = "", nil
        if redraw and hadPrefix then self:draw() end
    end

    function self:begin(mode)
        self:resetSequence()
        self.previews:resetPanel()
        self.mode = mode or "move"
        self.placeholderKey = self.mode == "switch" and "switchPlaceholder" or "placeholder"
        self.searching = false
        self.shortcuts, self.shortcutCount, self.shortcutLength = {}, 0, nil
        self.value, self.row, self.offset, self.windowIndex = "", 1, 0, 1
        return self
    end
    self:begin("move")

    function self:assignShortcuts()
        if self.mode ~= "switch" then return end
        local groups, byId, ordered, missing = {}, {}, {}, 0
        for _, choice in ipairs(self.items) do
            local group = choice.displayId or choice.displayName or ""
            if not byId[group] then byId[group] = {}; groups[#groups + 1] = byId[group] end
            byId[group][#byId[group] + 1] = choice
        end
        for _, group in ipairs(groups) do
            for _, choice in ipairs(group) do
                for _, target in ipairs(targets(choice)) do
                    ordered[#ordered + 1] = target.key
                    if not self.shortcuts[target.key] then missing = missing + 1 end
                end
            end
        end
        if #ordered == 0 then return end
        local length = self.shortcutLength or 1
        while 26 ^ length < #ordered do length = length + 1 end
        if self.shortcutLength and self.shortcutCount + missing > 26 ^ length then length = length + 1 end
        if length ~= self.shortcutLength then
            self.shortcuts, self.shortcutCount, self.shortcutLength = {}, 0, length
            self:resetSequence()
        end
        for _, key in ipairs(ordered) do
            if not self.shortcuts[key] then
                local index, label = self.shortcutCount, ""
                for _ = 1, self.shortcutLength do
                    local digit = index % 26 + 1
                    label = letters:sub(digit, digit) .. label
                    index = math.floor(index / 26)
                end
                self.shortcuts[key] = label
                self.shortcutCount = self.shortcutCount + 1
            end
        end
        if self.pendingPrefix ~= "" then
            local matches = false
            for _, key in ipairs(ordered) do
                if self.shortcuts[key]:sub(1, #self.pendingPrefix) == self.pendingPrefix then matches = true; break end
            end
            if not matches then self:resetSequence() end
        end
    end

    function self:letter(letter)
        if self.sequenceDeadline and nowMs() >= self.sequenceDeadline then self:resetSequence() end
        local sequence, matched = self.pendingPrefix .. letter, false
        for row, choice in ipairs(self.filtered) do
            for _, target in ipairs(targets(choice)) do
                local label = self.shortcuts[target.key]
                if label == sequence then
                    self:select(row, target.index)
                    return
                end
                if label and label:sub(1, #sequence) == sequence then matched = true end
            end
        end
        self:resetSequence()
        if matched then
            self.pendingPrefix = sequence
            self.sequenceDeadline = nowMs() + config.shortcutSequenceTimeoutMs
            local generation = self.sequenceGeneration
            self.sequenceTimer = hs.timer.doAfter(config.shortcutSequenceTimeoutMs / 1000, function()
                if generation ~= self.sequenceGeneration then return end
                self:resetSequence(true)
            end)
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

    function self:badge(elements, key, centerX, centerY)
        local label = self.shortcuts[key]
        if not label or label:sub(1, #self.pendingPrefix) ~= self.pendingPrefix then return end
        local remaining = label:sub(#self.pendingPrefix + 1):upper()
        local size = math.max(36, #label * 10 + 16)
        local x, y = centerX - size / 2, centerY - size / 2
        elements[#elements + 1] = { type = "rectangle", action = "fill",
            roundedRectRadii = { xRadius = 8, yRadius = 8 }, fillColor = { white = 0, alpha = 0.4 },
            frame = { x = x, y = y, w = size, h = size } }
        elements[#elements + 1] = text(remaining, x, centerY - 11, size, 22, 15,
            { white = 1, alpha = 1 }, "center")
    end

    function self:fitSwitchWidth()
        if self.mode ~= "switch" or not self.screenFrame then return end
        local longestPreview, longestLabel = 0, 0
        local minimumPreview = math.max(36, (self.shortcutLength or 1) * 10 + 16)
        for _, choice in ipairs(self.items) do
            if choice.workspaceId then
                local width = 0
                for i, window in ipairs(choice.windows or {}) do
                    width = width + self.previews:get(window).width + (i > 1 and 12 or 0)
                end
                longestPreview = math.max(longestPreview, width, minimumPreview)
                longestLabel = math.max(longestLabel, choice.labelWidth or 0)
            end
        end
        local screen = self.screenFrame
        local desired = longestPreview > 0 and (20 + longestPreview + 10 + longestLabel + 20) or 320
        local width = math.min(desired, screen.w * 0.8, screen.w - 40)
        if self.frame.w ~= width then
            self.frame.w, self.frame.x = width, screen.x + (screen.w - width) / 2
            canvas:frame(self.frame)
        end
    end

    function self:draw()
        if not self.visible then return end
        self:fitSwitchWidth()
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
            iconX = 20
            labelWidth = math.min(longestLabel, math.max(1, frame.w - 20 - iconX - 10 - math.max(36, (self.shortcutLength or 1) * 10 + 16)))
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
                    if index == self.row and self.revealSelection then
                        local left = 0
                        for i, window in ipairs(windows) do
                            local width = self.previews:get(window).width
                            if i == self.windowIndex then
                                if left < scroll then scroll = left
                                elseif left + width > scroll + column.w then scroll = left + width - column.w end
                                break
                            end
                            left = left + width + 12
                        end
                        scroll = math.max(0, math.min(scroll, maxOffset))
                    end
                    self.previews.offsets[choice.workspaceId] = scroll
                    self.hitRows[#self.hitRows].maxPreviewOffset = maxOffset
                    local previewY, previewX = y + 12, column.x - scroll
                    elements[#elements + 1] = { type = "rectangle", action = "clip",
                        frame = { x = column.x, y = #windows > 0 and previewY or y,
                            w = column.w, h = #windows > 0 and Previews.height or rowHeight } }
                    self.hitRows[#self.hitRows].previews = {}
                    if #windows == 0 then
                        if choice.windows then
                            self:badge(elements, targetKey(choice), column.x + column.w / 2, y + rowHeight / 2)
                        else
                            elements[#elements + 1] = text(locale:text("loadingPreviews"),
                                column.x, y + (rowHeight - 24) / 2, column.w, 24, 16, muted)
                        end
                    end
                    for windowIndex, window in ipairs(windows) do
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
                        self.hitRows[#self.hitRows].previews[#self.hitRows[#self.hitRows].previews + 1] = {
                            index = windowIndex, left = previewX, right = previewX + preview.width }
                        if previewX + preview.width > column.x and previewX < column.x + column.w then
                            if index == self.row and windowIndex == self.windowIndex then
                                elements[#elements + 1] = { type = "rectangle", action = "stroke", strokeWidth = 2,
                                    strokeColor = { white = 1, alpha = 0.65 }, frame = {
                                        x = previewX + 1, y = previewY + 1, w = math.max(1, preview.width - 2), h = Previews.height - 2 } }
                            end
                            self:badge(elements, targetKey(choice, window), previewX + preview.width / 2, previewY + Previews.height / 2)
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
                if self.mode ~= "switch" and choice.workspaceId and choice.valid ~= false and index <= 9 then
                    elements[#elements + 1] = text("⌘" .. index, frame.w - 58, y + 13, 36, 22, 15, muted, "right")
                end
            end
        end
        self.revealSelection = false
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
        local choice = self:selectedRowContents()
        self.windowIndex = math.max(1, math.min(self.windowIndex, #(choice.windows or {})))
        self:draw()
    end
    function self:query(value)
        if value == nil then return self.value end
        if self.value ~= value then self.value, self.row, self.offset = value, 1, 0; self:filter() end
        return self
    end
    function self:choices(items)
        local selected = self:selectedRowContents()
        local selectedWindow = selected.windows and selected.windows[self.windowIndex]
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
        local current = self:selectedRowContents()
        if selectedWindow then
            for i, window in ipairs(current.windows or {}) do
                if targetKey(current, window) == targetKey(selected, selectedWindow) then
                    self.windowIndex, self.revealSelection = i, true
                    break
                end
            end
        end
        self:draw()
        return self
    end
    function self:selectedRow(row)
        if not row then return self.row end
        local nextRow = math.max(1, math.min(row, #self.filtered))
        if nextRow ~= self.row then self:resetSequence() end
        self.row = nextRow
        self.windowIndex = math.max(1, math.min(self.windowIndex, #(self:selectedRowContents().windows or {})))
        self.revealSelection = true
        self:draw(); return self
    end
    function self:moveWindow(step)
        self:resetSequence()
        local count = #(self:selectedRowContents().windows or {})
        self.windowIndex = math.max(1, math.min(self.windowIndex + step, count))
        self.revealSelection = true
        self:draw()
    end
    function self:moveSelection(step)
        self:resetSequence()
        local count = #self.filtered
        if count == 0 then return end
        local row = self.row
        for _ = 1, count do
            row = (row - 1 + step) % count + 1
            local choice = self.filtered[row]
            if choice.workspaceId and choice.valid ~= false then
                self:selectedRow(row)
                return
            end
        end
    end
    function self:selectedRowContents(row) return self.filtered[row or self.row] or {} end
    function self:isVisible() return self.visible end
    function self:hide()
        self:resetSequence()
        self.visible = false
        self.previews:resetPanel()
        self.tap:stop()
        canvas:hide()
        canvas:replaceElements()
    end
    function self:cancel() self:hide(); completion(nil); return self end
    function self:select(row, windowIndex)
        local choice = self:selectedRowContents(row)
        if not choice.workspaceId or choice.valid == false then return end
        if self.mode == "switch" then
            if not choice.windows then return end
            if #choice.windows > 0 then
                local window = choice.windows[windowIndex or self.windowIndex]
                if not window or not window.id or not window.windowId then return end
                choice = { workspaceId = choice.workspaceId, window = { id = window.id, windowId = window.windowId } }
            end
        end
        self:hide()
        completion(choice)
    end
    function self:previewAt(hit, x)
        local column = self.previewColumn
        if not column or x < column.x or x >= column.x + column.w then return nil end
        for _, preview in ipairs(hit.previews or {}) do
            if x >= preview.left and x < preview.right then return preview.index end
        end
    end
    function self:show()
        if hs.eventtap.isSecureInputEnabled() then
            self:cancel(); hs.alert.show(locale:text("keyboardUnavailable"), 4); return self
        end
        local screen = hs.screen.mainScreen():frame()
        self.screenFrame = screen
        local width = math.min(screen.w - 40, math.max(320, screen.w * (self.mode == "switch" and 0.8 or config.width / 100)))
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
        if self.onInput and kind ~= types.mouseMoved and kind ~= types.keyUp then self.onInput(event) end
        if kind == types.mouseMoved then
            local point, f = event:location(), self.frame
            if point.x >= f.x + padding and point.x < f.x + f.w - padding then
                local y = point.y - f.y
                for _, hit in ipairs(self.hitRows or {}) do
                    if y >= hit.top and y < hit.bottom then
                        local choice = self.filtered[hit.index]
                        if choice and choice.workspaceId and choice.valid ~= false then
                            local windowIndex = self.mode == "switch" and self:previewAt(hit, point.x - f.x)
                            if hit.index ~= self.row or (windowIndex and windowIndex ~= self.windowIndex) then
                                self:resetSequence()
                                self.row = hit.index
                                self.windowIndex = windowIndex or math.max(1, math.min(self.windowIndex, #(choice.windows or {})))
                                self:draw()
                            end
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
                    if y >= hit.top and y < hit.bottom then
                        if self.mode == "switch" then
                            local choice = self.filtered[hit.index]
                            local windowIndex = self:previewAt(hit, point.x - f.x)
                            self:resetSequence()
                            self:selectedRow(hit.index)
                            if windowIndex then self:select(hit.index, windowIndex)
                            elseif choice.windows and #choice.windows == 0 and point.x - f.x >= self.previewColumn.x
                                and point.x - f.x < self.previewColumn.x + self.previewColumn.w then
                                self:select(hit.index)
                            end
                        else self:select(hit.index) end
                        break
                    end
                end
            end
            return true
        end
        if kind == types.scrollWheel then
            self:resetSequence(true)
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
        local repeatProperty = hs.eventtap.event.properties.keyboardEventAutorepeat
        if self.mode == "switch" and repeatProperty and event.getProperty and event:getProperty(repeatProperty) ~= 0 then return true end
        local unmodified = not flags.cmd and not flags.ctrl and not flags.alt and not flags.shift and not flags.fn
        if self.mode == "switch" and code == keys.escape then
            if self.pendingPrefix ~= "" then self:resetSequence(true)
            elseif self.searching then
                self:resetSequence()
                self.searching = false
                self:query(""); self:draw()
            else self:cancel() end
        elseif self.mode == "switch" and not self.searching and unmodified and code == slashCode then
            self:resetSequence()
            self.searching = true
            self:draw()
        elseif self.mode == "switch" and not self.searching and unmodified and letterByCode[code] then
            self:letter(letterByCode[code])
        elseif code == keys.escape then self:cancel()
        elseif code == keys["return"] or code == keys.padenter then self:select()
        elseif code == keys.up then self:moveSelection(-1)
        elseif code == keys.down then self:moveSelection(1)
        elseif self.mode == "switch" and code == keys.left then self:moveWindow(-1)
        elseif self.mode == "switch" and code == keys.right then self:moveWindow(1)
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
