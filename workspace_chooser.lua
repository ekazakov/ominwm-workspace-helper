local M = {}

function M.new(hs, config, cli, icons, logger)
    local self = { cache = nil, active = false, moving = false, epoch = 0, stopped = false,
        metrics = {}, refreshWaiters = {} }
    local function now() return hs.timer.absoluteTime() / 1e6 end
    local function notify(err)
        logger.w(tostring(err))
        hs.alert.show("OmniWM: " .. tostring(err), 4)
    end
    local function metric(key, started)
        self.metrics[key] = now() - started
        if config.debug then logger.df("%s: %.1f ms", key, self.metrics[key]) end
    end

    function self:render()
        if not self.chooser or not self.cache then return end
        local choices, fingerprint = {}, {}
        for _, ws in ipairs(self.cache) do
            local current = self.source and self.source.workspaceId == ws.id
            if (config.showCurrentWorkspace or not current)
                and (config.showEmptyWorkspaces or (ws.count or #ws.apps) > 0) then
                local names = {}
                for _, app in ipairs(ws.apps) do names[#names + 1] = app.name end
                local text = tostring(ws.number)
                if ws.name ~= text then text = text .. " — " .. ws.name end
                if current then text = "● " .. text end
                local subText = #names > 0 and table.concat(names, ", ") or "Нет приложений"
                if ws.displayName ~= "" then subText = subText .. " · " .. ws.displayName end
                local ok, image = pcall(icons.composite, icons, ws.apps)
                if not ok then logger.w("Icon rendering failed: " .. tostring(image)); image = nil end
                choices[#choices + 1] = { text = text, subText = subText, image = image, workspaceId = ws.id }
                fingerprint[#fingerprint + 1] = { ws.id, text, subText, ws.apps }
            end
        end
        local signature = hs.json.encode(fingerprint)
        if signature == self.signature then return end
        self.signature = signature
        if #choices == 0 then
            choices = { { text = "Нет доступных назначений", subText = "Проверьте настройки фильтрации", valid = false } }
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
        if self.refreshing then return end
        self.refreshing = true
        local started = now()
        cli:refresh(function(workspaces, err)
            if self.stopped then return end
            self.refreshing = false
            metric("refreshMs", started)
            if workspaces then
                self.cache = workspaces
                if self.active and self.chooser:isVisible() then self:render() end
            end
            local waiters = self.refreshWaiters
            self.refreshWaiters = {}
            for _, waiter in ipairs(waiters) do waiter(workspaces, err) end
        end)
    end

    self.chooser = hs.chooser.new(function(choice)
        if self.stopped then return end
        local source = self.source
        self.active, self.source = false, nil
        self.epoch = self.epoch + 1
        if not choice or not choice.workspaceId or not source then return end
        self.moving = true
        local started = now()
        -- hs.chooser closes before invoking its completion callback.
        cli:move(source, choice.workspaceId, function(ok, err)
            if self.stopped then return end
            self.moving = false
            metric("moveMs", started)
            if not ok then notify(err); return end
            self:refresh()
        end)
    end)
    self.chooser:rows(config.rows):width(config.width):bgDark(config.theme == "dark")
        :searchSubText(config.searchAppNames):enableDefaultForQuery(false)
        :placeholderText("Перенести колонку → workspace…")
        :fgColor({ white = config.theme == "dark" and 0.95 or 0.1 })
        :subTextColor({ white = config.theme == "dark" and 0.65 or 0.4 })
        :invalidCallback(function() end)

    function self:cancel()
        self.active, self.source = false, nil
        self.epoch = self.epoch + 1
        if self.chooser:isVisible() then self.chooser:cancel() end
    end

    function self:toggle()
        if self.stopped or self.moving then return end
        if self.active then self:cancel(); return end
        self.active = true
        self.epoch = self.epoch + 1
        local epoch, started = self.epoch, now()
        local warm = self.cache ~= nil
        local native = hs.window.frontmostWindow()
        local nativeId = native and native:id()
        if not nativeId then self:cancel(); notify("No native window focused"); return end
        local function valid() return not self.stopped and self.active and self.epoch == epoch end
        local function fail(err) if valid() then self:cancel(); notify(err) end end
        local function capture()
            if not valid() then return end
            cli:capture(function(source, err)
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
                    if config.refreshOnOpen then
                        self:refresh(function(_, refreshError)
                            if valid() and refreshError then logger.w("Workspace refresh failed: " .. refreshError) end
                        end)
                    end
                else
                    -- Safe loading row: source was captured before chooser stole focus.
                    self.chooser:choices({ { text = "Загрузка воркспейсов…", valid = false } }):show()
                    self:refresh(function(workspaces, refreshError)
                        if not valid() then return end
                        if not workspaces then fail(refreshError); return end
                        metric("coldOpenMs", started)
                        self:render()
                    end)
                end
            end, nativeId)
        end
        if cli.ready then capture()
        else cli:check(function(ok, err) if ok then capture() else fail(err) end end) end
    end

    function self:stop()
        self:cancel()
        self.stopped = true
        self.chooser:delete()
        self.chooser, self.cache, self.refreshWaiters = nil, nil, {}
    end
    return self
end
return M
