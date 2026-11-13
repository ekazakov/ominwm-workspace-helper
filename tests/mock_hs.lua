local F = require("tests.fixtures")
local M = {}
local function encode(value)
    if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
    local keys, parts = {}, {}
    for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. "=" .. encode(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
function M.new()
    local e = { pending = {}, timers = {}, tasks = {}, calls = {}, alerts = {}, logs = {},
        nativeId = 101, now = 0, hotkeys = 0, canvases = 0, iconLoads = {}, records = F.copy({
            capabilities = F.capabilities, workspaces = F.workspaces, ["workspace-bar"] = F.bar,
            ["focused-window"] = F.focused, windows = F.windows,
        }) }
    local hs = {}
    e.hs = hs
    hs.fs = { attributes = function() return { mode = "file" } end }
    hs.window = { frontmostWindow = function()
        if not e.nativeId then return nil end
        local id = e.nativeId
        return { id = function() return id end }
    end }
    e.captures, e.snapshots = {}, {}
    hs.window.snapshotForID = function(id)
        e.captures[#e.captures + 1] = id
        local size = e.snapshots[id]
        if size == "throw" then error("Capture failed") end
        if not size then return nil end
        local image = { dimensions = F.copy(size), snapshotId = id }
        function image:size(value)
            if value then self.dimensions = F.copy(value); return self end
            return self.dimensions
        end
        return image
    end
    function e:previewFrame()
        for _, timer in ipairs(self.timers) do
            if timer.active and timer.delay == 0 then
                timer.active = false; timer.callback(); return true
            end
        end
        return false
    end
    function e:flushPreviews()
        local frames = 0
        while self:previewFrame() do frames = frames + 1; assert(frames < 2000, "preview loop") end
    end
    hs.logger = { new = function()
        return { w = function(msg) e.logs[#e.logs + 1] = msg end, df = function() end }
    end }
    hs.alert = { show = function(msg) e.alerts[#e.alerts + 1] = msg end }
    hs.keycodes = { map = { w = 13, a = 0, v = 9, escape = 53, ["return"] = 36, padenter = 76,
        up = 126, down = 125, left = 123, right = 124, delete = 51, forwarddelete = 117 } }
    hs.eventtap = {
        event = { types = { keyDown = 10, keyUp = 11, flagsChanged = 12, otherMouseDown = 25, mouseMoved = 5,
            leftMouseDown = 1, rightMouseDown = 3, scrollWheel = 22 }, properties = { scrollWheelEventDeltaAxis1 = 1, scrollWheelEventDeltaAxis2 = 2, keyboardEventAutorepeat = 3 } },
        isSecureInputEnabled = function() return false end,
        new = function(_, callback)
            return { callback = callback, start = function(self) self.enabled = true end,
                stop = function(self) self.enabled = false end,
                isEnabled = function(self) return self.enabled end }
        end,
    }
    hs.screen = { mainScreen = function()
        return { frame = function() return { x = 0, y = 0, w = 1440, h = 900 } end }
    end }
    hs.styledtext = { new = function(value)
        return { lower = function() return { getString = function() return value:lower() end } end }
    end }
    local tokens, sequence = {}, 0
    hs.json = { encode = encode, decode = function(token) return assert(tokens[token], "invalid JSON") end }
    function e:token(value) sequence = sequence + 1; local token = "json:" .. sequence; tokens[token] = value; return token end
    hs.timer = {
        absoluteTime = function() e.now = e.now + 1000000; return e.now end,
        doAfter = function(delay, callback)
            local timer = { delay = delay, callback = callback, active = true, stop = function(self) self.active = false end }
            e.timers[#e.timers + 1] = timer
            return timer
        end,
    }
    hs.task = { new = function(path, callback, ...)
        local streamCallback, args
        if select("#", ...) > 0 then
            local third, fourth = ...
            assert(type(third) == "table" or type(third) == "function",
                "expected table or function for argument 3")
            if type(third) == "table" then args = third
            else streamCallback, args = third, fourth end
        end
        args = args or {}
        local task = { path = path, callback = callback, streamCallback = streamCallback, launchArgs = args }
        if path == "/bin/sh" then
            task.stdoutPath, task.stderrPath = args[4], args[5]
            task.args = {}
            for i = 7, #args do task.args[#task.args + 1] = args[i] end
        else task.args = args end
        function task:output(stdout, stderr)
            local out = assert(io.open(self.stdoutPath, "wb")); out:write(stdout or ""); out:close()
            local err = assert(io.open(self.stderrPath, "wb")); err:write(stderr or ""); err:close()
        end
        function task:start()
            if e.failStart then return false end
            e.pending[#e.pending + 1] = self
            e.calls[#e.calls + 1] = self.args
            return self
        end
        function task:setCallback(cb) self.callback = cb; return self end
        function task:terminate() self.terminated = true; return self end
        e.tasks[#e.tasks + 1] = task
        return task
    end }
    function e:drain()
        local timers = {}
        for _, timer in ipairs(self.timers) do
            if timer.active and timer.delay == 0.01 then timers[#timers + 1] = timer end
        end
        for _, timer in ipairs(timers) do timer.active = false; timer.callback() end
    end
    function e:step(hook)
        local task = table.remove(self.pending, 1)
        assert(task, "no pending task")
        if not task.callback then return end
        local args = task.args
        local payload, code, stderr = nil, 0, ""
        if hook then payload, code, stderr = hook(args, task) end
        code, stderr = code or 0, stderr or ""
        if payload == nil then
            if args[1] == "query" then payload = F.envelope(args[2], F.copy(self.records[args[2]]))
            elseif args[1] == "window" and args[2] == "focus" then
                if not self.refuseFocus then self.nativeId = 101; self.records.windows.windows[1].isFocused = true end
                payload = { ok = true, result = {} }
            else payload = { ok = true, result = {} } end
        end
        local output = type(payload) == "string" and payload or self:token(payload)
        if task.stdoutPath then task:output(output, stderr); task.callback(code, "", "")
        else task.callback(code, output, stderr) end
        self:drain()
    end
    function e:flush()
        local n = 0
        while #self.pending > 0 do n = n + 1; assert(n < 100, "task loop"); self:step() end
    end
    function e:moves()
        local out = {}
        for _, args in ipairs(self.calls) do if args[1] == "command" then out[#out + 1] = args end end
        return out
    end
    hs.image = { imageFromAppBundle = function(bundle)
        e.iconLoads[bundle] = (e.iconLoads[bundle] or 0) + 1
        if bundle == "missing" then return nil end
        return { image = bundle }
    end }
    hs.canvas = { new = function()
        e.canvases = e.canvases + 1
        local canvas = {}
        for _, method in ipairs({ "level", "behaviorAsLabels", "clickActivating", "frame", "show", "hide" }) do
            canvas[method] = function(self) return self end
        end
        function canvas:minimumTextSize() return { w = 100, h = 20 } end
        function canvas:size(size) self.dimensions = size; return self end
        function canvas:replaceElements(...) self.elements = { ... }; return self end
        function canvas:imageFromCanvas() return { elements = F.copy(self.elements), size = F.copy(self.dimensions) } end
        function canvas:delete() self.deleted = true; e.canvases = e.canvases - 1 end
        return canvas
    end }
    hs.hotkey = { bind = function(_, _, callback)
        e.hotkeys = e.hotkeys + 1
        return { callback = callback, delete = function() e.hotkeys = e.hotkeys - 1 end }
    end }
    hs.chooser = { new = function(callback)
        local c = { callback = callback, visible = false, items = {}, queryString = "", row = 1 }
        e.chooser = c
        for _, method in ipairs({ "rows", "width", "bgDark", "searchSubText", "enableDefaultForQuery", "placeholderText",
            "fgColor", "subTextColor", "invalidCallback" }) do
            c[method] = function(self, value) self["_" .. method] = value; return self end
        end
        function c:query(value) if value ~= nil then self.queryString = value; return self end; return self.queryString end
        function c:choices(value) self.items = value; return self end
        function c:filtered()
            local out = {}
            for _, item in ipairs(self.items) do
                local haystack = item.text .. (self._searchSubText and (item.subText or "") or "")
                if haystack:lower():find(self.queryString:lower(), 1, true) then out[#out + 1] = item end
            end
            return out
        end
        function c:selectedRow(value) if value then self.row = value; return self end; return self.row end
        function c:selectedRowContents(row) return self:filtered()[row or self.row] or {} end
        function c:show() self.visible = true; e.nativeId = 999; return self end
        function c:isVisible() return self.visible end
        function c:cancel() self.visible = false; e.nativeId = 101; self.callback(nil); return self end
        function c:select(row)
            local item = self:selectedRowContents(row)
            if item.valid == false then return end
            self.visible = false
            self.callback(item)
        end
        function c:delete() self.deleted = true end
        return c
    end }
    return e
end
return M
