local prefix = (...):match("^(.*%.)") or ""
local N = require(prefix .. "normalize")
local M = {}

local function safe(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil, tostring(result)
end

function M.findCLI(hs, configured)
    local candidates = configured and { configured } or {
        "/opt/homebrew/bin/omniwmctl", "/usr/local/bin/omniwmctl",
        "/Applications/OmniWM.app/Contents/MacOS/omniwmctl",
    }
    if not configured then
        for directory in (os.getenv("PATH") or ""):gmatch("[^:]+") do
            if directory:sub(1, 1) == "/" then candidates[#candidates + 1] = directory .. "/omniwmctl" end
        end
    end
    for _, path in ipairs(candidates) do
        local attr = hs.fs.attributes(path)
        if path:sub(1, 1) == "/" and attr and attr.mode == "file" then return path end
    end
    return nil, "omniwmctl not found; set cliPath to its absolute path"
end

function M.new(hs, config, logger)
    local self = { tasks = {}, stopped = false, ready = false }
    self.path, self.pathError = M.findCLI(hs, config.cliPath)

    function self:run(args, callback, raw)
        if self.stopped then return end
        if not self.path then callback(nil, self.pathError); return end
        local request = { done = false }
        local function finish(value, err)
            if request.done or self.stopped then return end
            request.done = true
            if request.timer then request.timer:stop() end
            self.tasks[request] = nil
            if err then logger.w(err) end
            callback(value, err)
        end
        local ok, task = pcall(hs.task.new, self.path, function(code, stdout, stderr)
            if request.done or self.stopped then return end
            local decoded, decodeError
            if not raw then decoded, decodeError = safe(hs.json.decode, stdout or "") end
            if code ~= 0 then
                finish(nil, "omniwmctl exit " .. code .. ": " .. tostring(
                    type(decoded) == "table" and (decoded.message or decoded.code) or stderr or stdout))
            elseif raw then finish(stdout)
            elseif not decoded then finish(nil, "Invalid CLI JSON: " .. tostring(decodeError or "empty response"))
            else
                local result, err = safe(N.unwrap, decoded, args[1] == "query" and args[2] or nil)
                finish(result, err)
            end
        end, args)
        if not ok or not task then finish(nil, "Cannot create omniwmctl task: " .. tostring(task)); return end
        request.task = task
        self.tasks[request] = true
        request.timer = hs.timer.doAfter(config.taskTimeout, function()
            finish(nil, "omniwmctl timed out; command outcome may be unknown")
            task:terminate()
        end)
        if not task:start() then finish(nil, "Cannot start omniwmctl at " .. self.path) end
    end

    function self:query(kind, callback, selectors)
        local args = { "query", kind }
        for _, arg in ipairs(selectors or {}) do args[#args + 1] = arg end
        args[#args + 1], args[#args + 2] = "--format", "json"
        self:run(args, callback)
    end

    function self:check(callback)
        self:query("capabilities", function(payload, err)
            if not payload then self.ready = false; callback(nil, err); return end
            local valid, why = safe(N.capabilities, payload)
            self.ready = valid == true
            callback(valid, why)
        end)
    end

    function self:refresh(callback)
        self:query("workspaces", function(payload, err)
            if not payload then callback(nil, err); return end
            local workspaces, why = safe(N.workspaces, payload)
            if not workspaces then callback(nil, why); return end
            if #workspaces == 0 then callback(nil, "No available workspaces"); return end
            self:query("workspace-bar", function(bar)
                local complete = bar and safe(N.mergeBar, workspaces, bar)
                if complete then callback(workspaces); return end
                self:query("windows", function(windows, windowError)
                    if not windows then callback(nil, windowError); return end
                    local merged, mergeError = safe(function() N.mergeWindows(workspaces, windows); return true end)
                    callback(merged and workspaces or nil, mergeError)
                end)
            end)
        end)
    end

    function self:column(source, callback)
        self:query("windows", function(payload, err)
            if not payload then callback(nil, err); return end
            local column, why = safe(N.column, payload, source)
            callback(column, why)
        end, { "--workspace", source.workspaceId })
    end

    function self:capture(callback, expectedNativeId)
        -- Native focus is captured at the keypress, before any asynchronous work.
        local native = hs.window.frontmostWindow()
        local nativeId = native and native:id()
        if not nativeId then callback(nil, "No native window focused"); return end
        if expectedNativeId and nativeId ~= expectedNativeId then
            callback(nil, "Focus changed since shortcut; try again"); return
        end
        self:query("focused-window", function(payload, err)
            if not payload then callback(nil, err); return end
            local source, why = safe(N.focused, payload)
            if not source then callback(nil, why); return end
            self:column(source, function(column, columnError)
                if not column then callback(nil, columnError); return end
                local current = hs.window.frontmostWindow()
                if column.windowId ~= nativeId or not current or current:id() ~= nativeId then
                    callback(nil, "Focus changed while capturing source; try again"); return
                end
                callback(column)
            end)
        end)
    end

    function self:move(source, destinationId, callback)
        if not self.ready then callback(nil, "OmniWM compatibility has not been verified"); return end
        self:query("workspaces", function(payload, err)
            if not payload then callback(nil, err); return end
            local workspaces, why = safe(N.workspaces, payload)
            if not workspaces then callback(nil, why); return end
            local destination, origin
            for _, ws in ipairs(workspaces) do
                if ws.id == destinationId then destination = ws end
                if ws.id == source.workspaceId then origin = ws end
            end
            if not destination or not origin then callback(nil, "Source or destination workspace was removed"); return end
            if destination.id == origin.id then callback(true); return end
            if origin.layout ~= "niri" or destination.layout ~= "niri" then
                callback(nil, "Both workspaces must use Niri layout"); return
            end
            self:column(source, function(current, columnError)
                if not current then callback(nil, columnError); return end
                if current.columnIndex ~= source.columnIndex or current.members ~= source.members then
                    callback(nil, "Source column changed while chooser was open; try again"); return
                end
                self:run({ "window", "focus", source.id }, function(focused, focusError)
                    if not focused then callback(nil, focusError); return end
                    -- Re-resolve UUID -> number after restoring focus, since the chooser or a
                    -- focus request may have been open long enough for configuration to change.
                    self:query("workspaces", function(latestPayload, latestError)
                        if not latestPayload then callback(nil, latestError); return end
                        local latest, parseError = safe(N.workspaces, latestPayload)
                        if not latest then callback(nil, parseError); return end
                        local target, sourceWorkspace
                        for _, ws in ipairs(latest) do
                            if ws.id == destinationId then target = ws end
                            if ws.id == source.workspaceId then sourceWorkspace = ws end
                        end
                        if not target or not sourceWorkspace or target.layout ~= "niri" or sourceWorkspace.layout ~= "niri" then
                            callback(nil, "Workspace was removed or its layout changed; move cancelled"); return
                        end
                        -- A successful focus command alone is insufficient: check live identity and membership.
                        self:column(source, function(verified, verifyError)
                            if not verified then callback(nil, verifyError); return end
                            local native = hs.window.frontmostWindow()
                            if not verified.isFocused or verified.members ~= source.members
                                or verified.columnIndex ~= source.columnIndex or not native or native:id() ~= source.windowId then
                                callback(nil, "Could not confirm original column focus; move cancelled"); return
                            end
                            -- 0.7.6 accepts a numeric workspace number, NOT the projection UUID.
                            -- Resolve it from the fresh authoritative snapshot, never from a label.
                            self:run({ "command", "move-column-to-workspace", tostring(target.number) }, function(result, moveError)
                                callback(result ~= nil and true or nil, moveError)
                            end)
                        end)
                    end)
                end)
            end)
        end)
    end

    function self:stop()
        self.stopped, self.ready = true, false
        for request in pairs(self.tasks) do
            request.done = true
            if request.timer then request.timer:stop() end
            request.task:setCallback(nil)
            request.task:terminate()
        end
        self.tasks = {}
    end
    return self
end
return M
