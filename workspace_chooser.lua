local prefix = (...):match("^(.*%.)") or ""
local I18n = require(prefix .. "i18n")
local Picker = require(prefix .. "canvas_picker")
local M = {}

function M.new(hs, config, cli, icons, logger)
    local locale = I18n.new(hs)
    local self = { cache = nil, active = false, moving = false, epoch = 0, stopped = false,
        metrics = {}, refreshWaiters = {}, language = locale.language }
    local function now() return hs.timer.absoluteTime() / 1e6 end
    local function notify(err)
        logger.w(tostring(err))
        hs.alert.show("OmniWM: " .. locale:error(err), 4)
    end
    local function metric(key, started)
        self.metrics[key] = now() - started
        if config.debug then logger.df("%s: %.1f ms", key, self.metrics[key]) end
    end

    function self:render()
        if not self.chooser or not self.cache then return end
        local choices, fingerprint = {}, {}
        for _, ws in ipairs(self.cache) do
            local current = (self.mode == "switch" and ws.current)
                or (self.source and self.source.workspaceId == ws.id)
            if (config.showCurrentWorkspace or not current)
                and (config.showEmptyWorkspaces or (ws.count or #ws.apps) > 0) then
                local names = {}
                for _, app in ipairs(ws.apps) do
                    names[#names + 1] = app.name == "Unknown app" and locale:text("unknownApp") or app.name
                end
                local text = tostring(ws.number)
                if self.mode ~= "switch" then
                    if ws.name ~= text then text = text .. " — " .. ws.name end
                    if current then text = "● " .. text end
                end
                local subText = ws.displayName
                local searchText = text .. " " .. subText
                if config.searchAppNames then searchText = searchText .. " " .. table.concat(names, " ") end
                local ok, image = true, nil
                if self.mode ~= "switch" then ok, image = pcall(icons.composite, icons, ws.apps) end
                if not ok then logger.w("Icon rendering failed: " .. tostring(image)); image = nil end
                local cells = math.max(1, math.min(#ws.apps, config.maxIcons)) + (#ws.apps > config.maxIcons and 1 or 0)
                choices[#choices + 1] = { text = text, subText = subText, searchText = searchText,
                    number = ws.number, image = image, imageWidth = cells * config.iconSize, windows = ws.windows, workspaceId = ws.id,
                    displayId = ws.displayId, displayName = ws.displayName }
                fingerprint[#fingerprint + 1] = { ws.id, text, subText, ws.displayId, ws.apps, ws.windows }
            end
        end
        local signature = hs.json.encode(fingerprint)
        if signature == self.signature then return end
        self.signature = signature
        if #choices == 0 then
            choices = { { text = locale:text("noDestinations"), subText = locale:text("filters"), valid = false } }
        end
        local query = self.chooser:query()
        local selected = self.chooser:selectedRowContents()
        local row = self.chooser:selectedRow()
        self.chooser:choices(choices):query(query or "")
        local restored = false
        if selected and selected.workspaceId then
            for i = 1, #choices do
                local candidate = self.chooser:selectedRowContents(i)
                if candidate and candidate.workspaceId == selected.workspaceId then
                    self.chooser:selectedRow(i)
                    restored = true
                    break
                end
            end
        end
        if not restored and row and row > 0 then self.chooser:selectedRow(math.min(row, #choices)) end
    end

    function self:refresh(callback)
        if callback then self.refreshWaiters[#self.refreshWaiters + 1] = callback end
        if self.refreshing then
            if self.mode == "switch" and not self.refreshingPreviews then self.previewRefreshPending = true end
            return
        end
        self.refreshing = true
        self.refreshingPreviews = self.mode == "switch" or config.previewRefreshInterval > 0
        local started = now()
        cli:refresh(function(workspaces, err)
            if self.stopped then return end
            self.refreshing = false
            metric("refreshMs", started)
            if workspaces then
                self.cache = workspaces
                if self.refreshingPreviews then
                    local windows = {}
                    for _, ws in ipairs(workspaces) do
                        for _, window in ipairs(ws.windows or {}) do windows[#windows + 1] = window end
                    end
                    self.chooser.previews:sync(windows, self.backgroundCapture == true)
                end
                if self.active and self.chooser:isVisible() then self:render() end
            end
            local waiters = self.refreshWaiters
            self.refreshWaiters = {}
            for _, waiter in ipairs(waiters) do waiter(workspaces, err) end
            if self.previewRefreshPending then
                self.previewRefreshPending = false
                self:refresh()
            end
        end, self.refreshingPreviews)
    end

    self.chooser = Picker.new(hs, config, locale, function(choice)
        if self.stopped then return end
        local source = self.source
        self.active, self.source = false, nil
        self.epoch = self.epoch + 1
        if not choice or not choice.workspaceId or (self.mode ~= "switch" and not source) then return end
        self.moving = true
        local started = now()
        -- The non-activating palette is hidden before focus restoration.
        local switching = self.mode == "switch"
        local function completed(ok, err)
            if self.stopped then return end
            self.moving = false
            metric(switching and "switchMs" or "moveMs", started)
            if not ok then notify(err); return end
            self:refresh()
        end
        if switching and choice.window then cli:focusWindow(choice.window, completed)
        elseif switching then cli:switch(choice.workspaceId, completed)
        else cli:move(source, choice.workspaceId, completed) end
    end, function(bundle) return icons:app(bundle) end)

    function self:startBackgroundPreviews()
        if self.stopped or self.backgroundStarted then return end
        self.backgroundStarted = true
        local function tick()
            if self.stopped then return end
            if not self.refreshing and not self.chooser.previews.timer then
                self.backgroundCapture = true
                self:refresh(function(_, err)
                    self.backgroundCapture = false
                    if err then logger.w("Preview refresh failed: " .. tostring(err)) end
                end)
            end
            if config.previewRefreshInterval > 0 then
                self.backgroundTimer = hs.timer.doAfter(config.previewRefreshInterval, tick)
            end
        end
        if config.previewRefreshInterval > 0 then tick() else self:refresh() end
    end

    function self:cancel()
        self.active, self.source = false, nil
        self.epoch = self.epoch + 1
        if self.chooser:isVisible() then self.chooser:cancel() end
    end

    function self:toggle(mode)
        mode = mode or "move"
        if self.stopped or self.moving then return end
        if self.active then
            local previousMode = self.mode
            self:cancel()
            if previousMode == mode then return end
        end
        self.mode = mode
        self.chooser:begin(mode)
        self.active = true
        self.epoch = self.epoch + 1
        local epoch, started = self.epoch, now()
        local warm = self.cache ~= nil
        local native = hs.window.frontmostWindow()
        local nativeId = native and native:id()
        if mode ~= "switch" and not nativeId then self:cancel(); notify("No native window focused"); return end
        local function valid() return not self.stopped and self.active and self.epoch == epoch end
        local function fail(err) if valid() then self:cancel(); notify(err) end end
        local function capture()
            if not valid() then return end
            local function captured(source, err)
                if not valid() then return end
                if not source then fail(err); return end
                self.source, self.signature = source, nil
                self.chooser:query("")
                local function show()
                    if not valid() then return end
                    self:render()
                    self.chooser:show()
                    metric(warm and "warmOpenMs" or "coldOpenMs", started)
                end
                if self.cache then
                    show()
                    if config.refreshOnOpen or mode == "switch" then
                        self:refresh(function(_, refreshError)
                            if valid() and refreshError then logger.w("Workspace refresh failed: " .. refreshError) end
                        end)
                    end
                else
                    -- Loading rows cannot be selected.
                    self.chooser:choices({ { text = locale:text("loading"), valid = false } }):show()
                    self:refresh(function(workspaces, refreshError)
                        if not valid() then return end
                        if not workspaces then fail(refreshError); return end
                        metric("coldOpenMs", started)
                        self:render()
                    end)
                end
            end
            if mode == "switch" then captured({})
            else cli:capture(captured, nativeId) end
        end
        if cli.ready then capture()
        else cli:check(function(ok, err) if ok then capture() else fail(err) end end) end
    end

    function self:stop()
        self:cancel()
        self.stopped = true
        if self.backgroundTimer then self.backgroundTimer:stop(); self.backgroundTimer = nil end
        self.chooser:delete()
        self.chooser, self.cache, self.refreshWaiters = nil, nil, {}
    end
    return self
end
return M
