package.path = "./?.lua;./?/init.lua;" .. package.path
local F, Mock = require("tests.fixtures"), require("tests.mock_hs")
local N, OmniWM, Icons, Cache = require("normalize"), require("omniwm"), require("icons"), require("cache")
local Project = assert(loadfile("init.lua"))()
local passed, failed = 0, 0
local function eq(actual, expected) assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected)) end
local function rejects(fn, pattern)
    local ok, err = pcall(fn)
    assert(not ok and tostring(err):find(pattern), "expected rejection: " .. pattern .. "; got " .. tostring(err))
end
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("ok - " .. name)
    else failed = failed + 1; print("FAIL - " .. name .. ": " .. tostring(err)) end
end
local function cli()
    local e = Mock.new()
    local config = F.copy(require("config"))
    local api = OmniWM.new(e.hs, config, e.hs.logger.new())
    api.ready = true
    local source = N.column(F.windows, N.focused(F.focused))
    return e, api, source
end
local function app(overrides)
    local e = Mock.new()
    _G.hs = e.hs
    overrides = overrides or {}
    if overrides.previewRefreshInterval == nil then overrides.previewRefreshInterval = 0 end
    local instance = Project.new(overrides):start()
    e.chooser = instance.ui.chooser
    e:flush()
    return e, instance
end

test("nested protocol envelopes and explicit server errors", function()
    eq(N.unwrap(F.envelope("workspaces", F.workspaces), "workspaces"), F.workspaces)
    rejects(function() N.unwrap({ ok = false, message = "IPC disabled" }) end, "IPC disabled")
    rejects(function() N.unwrap(F.envelope("windows", {}), "workspaces") end, "Unexpected result kind")
end)
test("workspace UUIDs survive duplicate Unicode labels and numbers above 9", function()
    local rows = N.workspaces(F.workspaces)
    eq(rows[1].id, "uuid-source"); eq(rows[2].number, 12); eq(rows[1].name, rows[2].name)
    local invalid = F.copy(F.workspaces); invalid.workspaces[2].number = 12
    rejects(function() N.workspaces(invalid) end, "Duplicate workspace identity")
    rejects(function() N.workspaces({}) end, "Unexpected workspaces")
end)
test("workspace bar deduplicates apps and retains empty workspaces", function()
    local rows = N.workspaces(F.workspaces)
    eq(N.mergeBar(rows, F.bar), true); eq(#rows[1].apps, 1); eq(#rows[2].apps, 0)
    eq(N.mergeBar(rows, { monitors = {} }), false)
    N.mergeWindows(rows, F.windows); eq(#rows[1].apps, 1)
end)
test("missing bundles remain neutral distinct apps", function()
    local rows = N.workspaces(F.workspaces)
    N.mergeWindows(rows, { windows = {
        { workspace = { id = "uuid-source" }, app = { name = "Unknown A" } },
        { workspace = { id = "uuid-source" }, app = { name = "Unknown B" } },
    } })
    eq(#rows[1].apps, 2); eq(rows[1].apps[1].bundleId, nil)
end)
test("version and numeric command contract are gated", function()
    eq(N.capabilities(F.capabilities), true)
    local caps = F.copy(F.capabilities); caps.appVersion = "0.8.0"
    caps.protocolVersion = 22
    eq(N.capabilities(caps), true)
    caps.protocolVersion = 19
    rejects(function() N.capabilities(caps) end, "Supported OmniWM version")
    caps.appVersion = "0.9.0"
    rejects(function() N.capabilities(caps) end, "Supported OmniWM version")
    caps = F.copy(F.capabilities); caps.commands[1].arguments[1].kind = "string"
    rejects(function() N.capabilities(caps) end, "Required OmniWM")
end)
test("source rejects missing focus, floating windows and missing column data", function()
    rejects(function() N.focused({}) end, "no managed window")
    local rows = F.copy(F.windows); rows.windows[1].mode = "floating"
    rejects(function() N.column(rows, N.focused(F.focused)) end, "not in a Niri column")
    rows.windows[1].mode, rows.windows[1].columnIndex = "tiling", nil
    rejects(function() N.column(rows, N.focused(F.focused)) end, "not in a Niri column")
end)
test("LRU evicts oldest and stores negative results", function()
    local cache = Cache.new(2)
    cache:put("a", false); cache:put("b", 2); eq(cache:get("a"), false)
    cache:put("c", 3); eq(cache:get("b"), nil); eq(cache.size, 2)
    cache:clear(); eq(cache.size, 0)
end)
test("icons reuse one canvas, composites and application misses", function()
    local e = Mock.new(); local config = F.copy(require("config")); config.maxIcons = 1
    local icons = Icons.new(e.hs, config)
    local apps = { { key = "missing", bundleId = "missing" }, { key = "other", bundleId = "other" } }
    local image = icons:composite(apps)
    eq(icons:composite(apps), image); eq(icons.builds, 1); eq(e.iconLoads.missing, 1)
    eq(image.elements[2].text, "+1")
    icons:app("missing"); eq(e.iconLoads.missing, 1); eq(e.canvases, 1)
    icons:composite({}); eq(e.canvases, 1)
    icons:stop(); eq(e.canvases, 0)
end)
test("successful column move restores and verifies focus then sends current numeric destination", function()
    local e, api, source = cli(); local result
    e.nativeId = 999
    api:move(source, "uuid-dest", function(ok) result = ok end); e:flush()
    eq(result, true); eq(#e:moves(), 1); eq(e:moves()[1][2], "move-column-to-workspace")
    eq(e:moves()[1][3], "12"); eq(e.calls[3][1], "window"); eq(e.calls[5][2], "windows")
end)
test("same workspace is a no-op and deleted destination cancels", function()
    local e, api, source = cli(); local result
    api:move(source, source.workspaceId, function(ok) result = ok end); e:flush()
    eq(result, true); eq(#e:moves(), 0); eq(#e.calls, 1)
    api:move(source, "deleted", function(ok) result = ok end); e:flush()
    eq(result, nil); eq(#e:moves(), 0)
end)
test("closed source and changed column cancel without focusing anything else", function()
    for _, mutation in ipairs({
        function(e) table.remove(e.records.windows.windows, 1) end,
        function(e) e.records.windows.windows[2].columnIndex = 2 end,
        function(e) e.records.windows.windows[1].workspace.id = "moved" end,
        function(e) e.records.workspaces.workspaces[1].layout = "dwindle" end,
    }) do
        local e, api, source = cli(); local err
        mutation(e)
        api:move(source, "uuid-dest", function(_, why) err = why end); e:flush()
        assert(err); eq(#e:moves(), 0)
        for _, args in ipairs(e.calls) do assert(args[1] ~= "window") end
    end
end)
test("failed restore and native focus mismatch never dispatch a move", function()
    local e, api, source = cli(); local err
    e.refuseFocus, e.nativeId = true, 999
    api:move(source, "uuid-dest", function(_, why) err = why end); e:flush()
    assert(err); eq(#e:moves(), 0)
end)
test("source closes between restore and final verification", function()
    local e, api, source = cli(); local err
    api:move(source, "uuid-dest", function(_, why) err = why end)
    e:step(); e:step(); e:step(); table.remove(e.records.windows.windows, 1); e:flush()
    assert(err); eq(#e:moves(), 0)
end)
test("destination removed after focus restoration cancels before move", function()
    local e, api, source = cli(); local err
    api:move(source, "uuid-dest", function(_, why) err = why end)
    e:step(); e:step(); e:step(); table.remove(e.records.workspaces.workspaces, 1); e:flush()
    assert(err); eq(#e:moves(), 0)
end)
test("destination number is resolved again after focus restoration", function()
    local e, api, source = cli()
    api:move(source, "uuid-dest", function(ok, err) assert(ok, err) end)
    e:step(); e:step(); e:step(); e.records.workspaces.workspaces[1].number = 14; e:flush()
    eq(e:moves()[1][3], "14")
end)
test("invalid JSON and nonzero task exits propagate errors", function()
    local e, api = cli(); local err
    api:query("windows", function(_, why) err = why end)
    e:step(function() return "broken-json" end); assert(err:find("Invalid CLI JSON"))
    api:query("windows", function(_, why) err = why end)
    e:step(function() return { ok = false, message = "IPC unavailable" }, 2 end)
    assert(err:find("IPC unavailable"))
end)
test("task constructor rejects an explicit nil stream callback", function()
    local e = Mock.new()
    local callback = function() end
    local args = { "--version" }
    local task = e.hs.task.new("/usr/bin/true", callback, args)
    eq(task.launchArgs, args); eq(task.streamCallback, nil)
    local stream = function() return true end
    task = e.hs.task.new("/usr/bin/true", callback, stream, args)
    eq(task.launchArgs, args); eq(task.streamCallback, stream)
    rejects(function() e.hs.task.new("/usr/bin/true", callback, nil, args) end,
        "expected table or function for argument 3")
end)
test("large CLI responses are read intact from files without streaming callbacks", function()
    local e, api = cli(); local result, err
    api:query("capabilities", function(value, why) result, err = value, why end)
    local task = e.tasks[1]
    eq(task.path, "/bin/sh"); eq(task.streamCallback, nil)
    local output = string.rep(" ", 150000) .. e:token(F.envelope("capabilities", F.capabilities))
    local decode = e.hs.json.decode
    e.hs.json.decode = function(value) return decode(value:match("^%s*(.*)$")) end
    task:output(output, ""); task.callback(0, "", "")
    eq(err, nil); eq(N.capabilities(result), true)
    eq(io.open(task.stdoutPath, "rb"), nil); eq(io.open(task.stderrPath, "rb"), nil)
    eq(e.timers[1].active, false); eq(next(api.tasks), nil)
end)
test("file capture preserves stderr and raw stdout and reports completion only once", function()
    local e, api = cli(); local result, err, count = nil, nil, 0
    api:query("windows", function(value, why) result, err = value, why; count = count + 1 end)
    local task = e.tasks[1]
    task:output("", "permission denied"); task.callback(2, "", "")
    assert(err:find("permission denied")); eq(count, 1); eq(result, nil)
    task.callback(2, "ignored", "ignored"); eq(count, 1)
    api:run({ "version" }, function(value) result = value end, true)
    task = e.tasks[2]
    task:output("OmniWM", ""); task.callback(0, "", "")
    eq(result, "OmniWM")
end)
test("missing output files fail once and clean up both files", function()
    local e, api = cli(); local err
    api:query("focused-window", function(_, why) err = why end)
    local task = e.tasks[1]
    os.remove(task.stdoutPath)
    task.callback(0, "", "")
    assert(err:find("Cannot read CLI output"))
    eq(io.open(task.stderrPath, "rb"), nil); eq(next(api.tasks), nil)
end)
test("stop removes output files and ignores late process completion", function()
    local e, api = cli(); local count = 0
    api:query("windows", function() count = count + 1 end)
    local task = e.tasks[1]
    local late = task.callback
    api:stop()
    -- A child cancelled before exec can still open its output files before it exits.
    task:output("late output", "late error")
    late(0, "", "")
    eq(count, 0); eq(io.open(task.stdoutPath, "rb"), nil); eq(io.open(task.stderrPath, "rb"), nil)
    for _, timer in ipairs(e.timers) do eq(timer.active, false) end
end)
test("timeout reports once; late callbacks and stop cannot continue a transaction", function()
    local e, api = cli(); local count = 0
    api:query("windows", function() count = count + 1 end)
    local task = e.tasks[1]
    e.timers[1].callback(); eq(count, 1); eq(task.terminated, true)
    eq(io.open(task.stdoutPath, "rb"), nil); eq(io.open(task.stderrPath, "rb"), nil)
    e:step(); eq(count, 1)
    api:query("windows", function() count = count + 1 end)
    api:stop(); e:flush(); eq(count, 1); eq(next(api.tasks), nil)
end)
test("task launch failure releases timeout and pending references", function()
    local e, api = cli(); e.failStart = true; local err
    api:query("windows", function(_, why) err = why end)
    assert(err); eq(next(api.tasks), nil); eq(e.timers[1].active, false)
    eq(io.open(e.tasks[1].stdoutPath, "rb"), nil); eq(io.open(e.tasks[1].stderrPath, "rb"), nil)
end)
test("refresh falls back from incomplete workspace-bar to windows", function()
    local e, api = cli(); local rows
    e.records["workspace-bar"] = { monitors = {} }
    api:refresh(function(value) rows = value end); e:flush()
    eq(#rows, 2); eq(#rows[1].apps, 1); eq(e.calls[3][2], "windows")
end)
test("capture aborts if native focus changes during async lookup", function()
    local e, api = cli(); local err
    api:capture(function(_, why) err = why end)
    e:step(); e.nativeId = 202; e:flush(); assert(err:find("Focus changed"))
end)
test("start, warm chooser, Escape, repeat start and stop free resources", function()
    local e, instance = app()
    eq(e.hotkeys, 1); instance:start(); eq(e.hotkeys, 1)
    instance:toggle(); e:flush(); eq(e.chooser.visible, true); eq(#e.chooser.items, 2)
    local builds = instance.icons.builds
    e.chooser:cancel(); eq(#e:moves(), 0)
    instance:toggle(); e:flush(); eq(instance.icons.builds, builds)
    assert(instance:diagnostics().metrics.warmOpenMs)
    instance:stop(); instance:stop(); eq(e.hotkeys, 0); eq(e.canvases, 0); eq(e.chooser.canvas.deleted, true)
end)
test("new instance stops previous hotkey even after module reload", function()
    local e, first = app()
    local second = Project.new():start(); e:flush()
    eq(first.running, false); eq(e.hotkeys, 1); second:stop(); eq(e.hotkeys, 0)
end)
test("rapid toggle cancels pending capture and ignores old callbacks", function()
    local e, instance = app()
    instance:toggle(); instance:toggle(); e:flush(); eq(e.chooser.visible, false)
    instance:toggle(); e:flush(); eq(e.chooser.visible, true)
    instance:toggle(); eq(e.chooser.visible, false); eq(#e:moves(), 0); instance:stop()
end)
test("late refresh updates cache without reopening cancelled chooser", function()
    local e, instance = app()
    instance:toggle(); e:step(); e:step(); eq(e.chooser.visible, true)
    e.chooser:cancel(); e:flush(); eq(e.chooser.visible, false); eq(#e:moves(), 0); instance:stop()
end)
test("background refresh preserves query, selection and captured source", function()
    local e, instance = app()
    instance:toggle(); e:step(); e:step()
    e.chooser:query("12"):selectedRow(1)
    local source = instance.ui.source
    e.records.workspaces.workspaces[1].displayName = "Renamed 🧪"
    e:flush()
    eq(e.chooser:query(), "12"); eq(e.chooser:selectedRowContents().workspaceId, "uuid-dest")
    eq(instance.ui.source, source); instance:stop()
end)
test("Enter moves captured column and suppresses further shortcuts until completion", function()
    local e, instance = app()
    instance:toggle(); e:flush()
    e.chooser:select(2); eq(instance.ui.moving, true)
    instance:toggle(); eq(e.chooser.visible, false)
    e:flush(); eq(#e:moves(), 1); eq(instance.ui.moving, false)
    assert(instance:diagnostics().metrics.moveMs); instance:stop()
end)
test("cold loading row cannot move a column", function()
    local e, instance = app()
    instance.ui.cache = nil
    instance:toggle()
    -- Drain all bootstrap/capture work, observing the disabled loading state.
    local sawLoading = false
    while #e.pending > 0 do
        e:step()
        if e.chooser.visible and e.chooser.items[1].valid == false then
            sawLoading = true; e.chooser:select(1); eq(#e:moves(), 0)
        end
    end
    eq(sawLoading, true); eq(#e.chooser.items, 2); instance:stop()
end)

test("switch panel opens without a focused window and never captures or moves a column", function()
    local e, instance = app()
    e.nativeId = nil
    e.calls = {}
    instance:toggleSwitch(); e:flush()
    eq(e.chooser.visible, true)
    eq(e.chooser.placeholderKey, "switchPlaceholder")
    e.chooser:query("12"):select(1); e:flush()
    eq(#e:moves(), 1)
    eq(e:moves()[1][2], "switch-workspace")
    eq(e:moves()[1][3], "12")
    for _, args in ipairs(e.calls) do
        assert(args[1] ~= "window")
        assert(args[2] ~= "focused-window")
    end
    assert(instance.ui.metrics.switchMs)
    instance:stop()
end)
test("switch resolves the selected identity against fresh workspace numbers", function()
    local e, api = cli(); local result
    e.records.workspaces.workspaces[1].number = 17
    e.records.workspaces.workspaces[1].layout = "dwindle"
    api:switch("uuid-dest", function(ok) result = ok end); e:flush()
    eq(result, true); eq(e:moves()[1][3], "17")
    e.calls = {}
    api:switch("deleted", function(ok, err) result = ok; assert(err) end); e:flush()
    eq(result, nil); eq(#e:moves(), 0)
end)
test("panel shortcuts change modes and repeated switch shortcut closes the panel", function()
    local e, instance = app()
    instance:toggle(); e:flush()
    instance:toggleSwitch(); e:flush()
    eq(e.chooser.visible, true); eq(instance.ui.mode, "switch")
    instance:toggleSwitch(); e:flush()
    eq(e.chooser.visible, false); eq(#e:moves(), 0)
    instance:stop()
end)

local function picker(count, mode, overrides)
    local e = Mock.new()
    local selected
    local configuration = F.copy(require("config"))
    for key, value in pairs(overrides or {}) do configuration[key] = value end
    local ui = require("canvas_picker").new(e.hs, configuration,
        { text = function(_, key) return key end }, function(choice) selected = choice end)
    local items = {}
    for i = 1, count do
        items[i] = { workspaceId = "ws" .. i, text = "Workspace " .. i, displayId = "display", displayName = "Display", windows = {} }
    end
    ui:begin(mode or "switch"):choices(items):show()
    local function key(code, flags, value, kind, repeated)
        return ui.tap.callback({ getType = function() return kind or 10 end,
            getKeyCode = function() return code end, getFlags = function() return flags or {} end,
            getUnicodeString = function() return value or "" end,
            getProperty = function() return repeated and 1 or 0 end })
    end
    return e, ui, key, function() return selected end, items
end
local function hasText(ui, value)
    for _, element in ipairs(ui.canvas.elements) do if element.text == value then return true end end
    return false
end
test("switch letters follow display grouping and physical key positions", function()
    local _, ui, key, selected, items = picker(3)
    items[1].displayId, items[2].displayId, items[3].displayId = "one", "two", "one"
    ui:begin("switch"):choices(items)
    eq(ui.shortcuts.ws1, "a"); eq(ui.shortcuts.ws3, "s"); eq(ui.shortcuts.ws2, "d")
    eq(hasText(ui, "A"), true); eq(hasText(ui, "⌘1"), false)
    key(1, {}, "ы")
    eq(selected().workspaceId, "ws3"); eq(ui.visible, false)
end)
test("switch ignores modifiers, key-up and Command-number but passes opening hotkeys", function()
    local _, ui, key, selected = picker(3)
    for _, flag in ipairs({ "cmd", "ctrl", "alt", "shift", "fn" }) do key(0, { [flag] = true }, "a") end
    key(0, {}, "a", 11); key(18, { cmd = true }, "1")
    eq(selected(), nil); eq(ui:query(), "")
    eq(key(13, { ctrl = true, alt = true, shift = true }), false)
    key(0, {}, "a"); eq(selected().workspaceId, "ws1")
end)
test("26 workspaces use single letters and 27 use two letters", function()
    local _, ui, key, selected = picker(26)
    eq(ui.shortcuts.ws26, "m"); key(46); eq(selected().workspaceId, "ws26")
    local _, two, press, choice = picker(27)
    eq(two.shortcuts.ws1, "aa"); eq(two.shortcuts.ws26, "am"); eq(two.shortcuts.ws27, "sa")
    press(1); eq(choice(), nil); eq(two.pendingPrefix, "s")
    eq(hasText(two, "switchPrefix s…"), true)
    press(0); eq(choice().workspaceId, "ws27")
end)
test("invalid prefixes and Escape clear pending input without closing", function()
    local _, ui, key, selected = picker(27)
    key(1); key(1); eq(selected(), nil); eq(ui.pendingPrefix, "")
    key(0); key(53); eq(ui.visible, true); eq(ui.pendingPrefix, "")
    key(53); eq(ui.visible, false)
end)
test("search accepts text and Enter while Escape restores letter mode", function()
    local _, ui, key, selected = picker(3)
    key(44); eq(ui.searching, true); eq(ui:query(), "")
    key(0, {}, "Workspace 3"); eq(ui:query(), "Workspace 3")
    eq(ui.shortcuts.ws3, "d"); eq(hasText(ui, "D"), true)
    key(18, { cmd = true }, "1"); eq(selected(), nil)
    key(53); eq(ui.searching, false); eq(ui:query(), ""); eq(ui.visible, true)
    key(44); key(0, {}, "Workspace 2"); key(36)
    eq(selected().workspaceId, "ws2")
end)
test("refresh reserves removed letters and assigns new identities without remapping", function()
    local _, ui, key, _, items = picker(3)
    key(44); key(0, {}, "Workspace 3")
    ui:choices({ items[3], items[1], { workspaceId = "new", text = "New", displayId = "display", windows = {} } })
    eq(ui.shortcuts.ws3, "d"); eq(ui.shortcuts.ws1, "a")
    eq(ui.shortcuts.ws2, "s"); eq(ui.shortcuts.new, "f")
    eq(ui:query(), "Workspace 3"); eq(ui.searching, true)
    ui:begin("switch"):choices({ items[3], items[1] })
    eq(ui.shortcuts.ws3, "a"); eq(ui.pendingPrefix, ""); eq(ui.searching, false)
end)
test("loading rows do not allocate shortcuts and later refresh increases shortcut length when needed", function()
    local _, ui, key, selected, items = picker(27)
    ui:begin("switch"):choices({ { text = "Loading", valid = false } })
    eq(ui.shortcutLength, nil); eq(ui.shortcutCount, 0)
    ui:choices({ items[1] }); eq(ui.shortcuts.ws1, "a")
    ui:choices(items); eq(ui.shortcutLength, 2); eq(ui.shortcuts.ws27, "sa")
    key(125); eq(ui.visible, true); eq(selected(), nil)
    ui:selectedRow(27); key(36); eq(selected().workspaceId, "ws27")
end)
test("shortcuts expand to three letters above 676 targets", function()
    local _, ui, key, selected = picker(677)
    eq(ui.shortcutCount, 677); eq(ui.shortcuts.ws676, "amm"); eq(ui.shortcuts.ws677, "saa")
    ui:selectedRow(100); eq(ui.shortcuts.ws1, "aaa")
    key(0); key(46); key(46); eq(selected().workspaceId, "ws676")
    local _, extra, press, choice = picker(677)
    press(44); press(0, {}, "Workspace 677"); press(36)
    eq(choice().workspaceId, "ws677")
end)
test("move panel retains typing search and Command-number selection", function()
    local _, ui, key, selected = picker(3, "move")
    eq(hasText(ui, "⌘1"), true)
    key(0, {}, "Workspace"); eq(ui:query(), "Workspace")
    key(19, { cmd = true }, "2"); eq(selected().workspaceId, "ws2")
end)

test("switch keyboard selection dispatches a workspace switch and reopening resets input", function()
    local e, instance = app()
    instance:toggleSwitch(); e:flush()
    local ui = instance.ui.chooser
    local function press(code)
        return ui.tap.callback({ getType = function() return 10 end,
            getKeyCode = function() return code end, getFlags = function() return {} end,
            getUnicodeString = function() return "" end })
    end
    press(2); e:flush()
    eq(e:moves()[1][2], "switch-workspace"); eq(e:moves()[1][3], "12")
    instance:toggleSwitch(); e:flush(); press(44)
    eq(ui.searching, true)
    instance:toggle(); e:flush()
    eq(ui.mode, "move"); eq(ui.searching, false); eq(ui.shortcutCount, 0)
    instance:toggleSwitch(); e:flush()
    eq(ui.mode, "switch"); eq(ui.searching, false); eq(ui.pendingPrefix, "")
    instance:stop()
end)

test("window normalization preserves duplicate-app windows, IDs, geometry and CLI order", function()
    local rows = N.workspaces(F.workspaces)
    local windows = F.copy(F.windows)
    windows.windows[1].frame = { width = 1600, height = 900 }
    N.mergeWindows(rows, windows)
    eq(#rows[1].windows, 2); eq(#rows[1].apps, 1)
    eq(rows[1].windows[1].windowId, 101); eq(rows[1].windows[2].windowId, 102)
    eq(rows[1].windows[1].frame.w, 1600)
    eq(rows[1].windows[1].bundleId, "com.example.Editor")
    eq(#rows[2].windows, 0)
end)
test("switch refresh queries windows even when workspace-bar already supplies icons", function()
    local e, api = cli(); local rows
    api:refresh(function(value) rows = value end, true); e:flush()
    eq(e.calls[2][2], "windows"); eq(#rows[1].windows, 2)
    e.calls = {}
    api:refresh(function(value) rows = value end); e:flush()
    eq(e.calls[2][2], "workspace-bar")
end)
test("snapshot queue captures one window per turn with proportional image dimensions", function()
    local e = Mock.new(); local changed = 0
    local previews
    local windows = { { id = "one", windowId = 1 }, { id = "two", windowId = 2 } }
    previews = require("window_previews").new(e.hs, function()
        changed = changed + 1; previews:update(windows)
    end)
    e.snapshots[1] = { w = 1600, h = 900 }; e.snapshots[2] = { w = 600, h = 1200 }
    previews:update(windows); eq(#e.captures, 0)
    e:previewFrame(); eq(#e.captures, 1); eq(changed, 0)
    assert(math.abs(previews:get(windows[1]).width - 110 * 1600 / 900) < 0.001)
    eq(previews:get(windows[1]).image:size().h, 110)
    e:flushPreviews(); eq(#e.captures, 2); eq(changed, 1); eq(previews:get(windows[2]).width, 55)
    previews:update(windows); e:flushPreviews(); eq(#e.captures, 2)
end)
test("failed snapshots use icons and dimensions or a square without retrying", function()
    local e = Mock.new(); local fallbacks = 0
    local windows = { { id = "gone", windowId = 1, frame = { w = 800, h = 400 }, bundleId = "app" },
        { id = "invalid", windowId = 2 }, { id = "missing" } }
    local previews
    previews = require("window_previews").new(e.hs, function() previews:update(windows) end,
        function() fallbacks = fallbacks + 1; return { icon = true } end)
    e.snapshots[1] = "throw"
    previews:update(windows); e:flushPreviews()
    eq(fallbacks, 3); eq(previews:get(windows[1]).width, 220)
    eq(previews:get(windows[2]).width, 110); eq(previews:get(windows[1]).fallback, true)
    previews:update(windows); e:flushPreviews(); eq(fallbacks, 3)
end)
test("snapshot queue reprioritizes visible windows and ignores cancelled callbacks", function()
    local e = Mock.new(); local changed = 0
    local previews = require("window_previews").new(e.hs, function() changed = changed + 1 end)
    local one, two = { id = "one", windowId = 1 }, { id = "two", windowId = 2 }
    previews:update({ one }); previews:update({ two })
    e:previewFrame(); eq(e.captures[1], 2)
    previews:update({ one }); local late = previews.timer.callback
    previews:clear(); late()
    eq(#e.captures, 1); eq(changed, 1); eq(next(previews.images), nil)
    previews:update({ two }); e:previewFrame(); eq(#e.captures, 2)
end)
test("missing visible previews take priority and publish in one redraw", function()
    local e, redraws = Mock.new(), 0
    local previews = require("window_previews").new(e.hs, function() redraws = redraws + 1 end)
    local one, two, three = { id = "one", windowId = 1 },
        { id = "two", windowId = 2 }, { id = "three", windowId = 3 }
    previews:sync({ one }, true); e:flushPreviews(); redraws = 0
    previews:sync({ one, two, three }, true)
    previews:update({ one, two, three })
    e:previewFrame(); eq(e.captures[2], 2); eq(redraws, 0)
    e:previewFrame(); eq(e.captures[3], 3); eq(redraws, 0)
    e:previewFrame(); eq(e.captures[4], 1); eq(redraws, 1)
    e:flushPreviews(); eq(redraws, 1)
end)

local function previewRows(ui, items, count)
    for i, item in ipairs(items) do
        item.windows = {}
        for j = 1, count do
            item.windows[j] = { id = i .. ":" .. j, windowId = i * 100 + j, frame = { w = 2000, h = 500 } }
        end
    end
    ui:choices(items)
end
local function scrollPreview(ui, hit, xDelta, yDelta, shift, x)
    local properties = { [1] = yDelta or 0, [2] = xDelta or 0 }
    return ui.tap.callback({ getType = function() return 22 end,
        getProperty = function(_, id) return properties[id] end,
        getFlags = function() return { shift = shift or false } end,
        location = function() return { x = x or (ui.frame.x + ui.previewColumn.x + 10),
            y = ui.frame.y + hit.top + 20 } end })
end
test("preview layout has 110px images and clips only the middle column", function()
    local e, ui, _, _, items = picker(8)
    previewRows(ui, items, 2)
    e.snapshots[101] = { w = 2000, h = 500 }
    e:flushPreviews()
    eq(ui.frame.w, 2 * 440 + 12 + 100 + 50); eq(ui.frame.h, 820)
    eq(ui.hitRows[1].bottom - ui.hitRows[1].top, 132)
    local clipCount, resets, images = 0, 0, 0
    for _, el in ipairs(ui.canvas.elements) do
        if el.action == "clip" then
            clipCount = clipCount + 1; eq(el.frame.w, ui.previewColumn.w); eq(el.frame.h, 110)
        elseif el.type == "resetClip" then resets = resets + 1
        elseif el.type == "image" and el.image.snapshotId then
            eq(el.frame.h, 110); eq(el.frame.w, 440); images = images + 1
        end
    end
    eq(clipCount, #ui.hitRows); eq(resets, clipCount); eq(images, 1)
    eq(#e.captures, #ui.hitRows * 2)
    local captures = #e.captures
    ui:selectedRow(8); e:flushPreviews()
    assert(#e.captures > captures)
    ui:query("Workspace 1"); e:flushPreviews(); assert(ui.shortcuts["window:1:1:101"])
    ui:cancel(); assert(next(ui.previews.images)); eq(#ui.canvas.elements, 0)
end)
test("horizontal preview scrolling is per workspace and clamps without changing selection", function()
    local e, ui, _, _, items = picker(3)
    previewRows(ui, items, 4)
    local first, second = ui.hitRows[1], ui.hitRows[2]
    scrollPreview(ui, first, -10, 0); eq(ui.previews.offsets.ws1, 200); eq(ui.row, 1)
    scrollPreview(ui, second, 0, -5, true); eq(ui.previews.offsets.ws2, 100)
    eq(ui.previews.offsets.ws1, 200)
    scrollPreview(ui, first, -100000, 0); eq(ui.previews.offsets.ws1, first.maxPreviewOffset)
    scrollPreview(ui, first, 100000, 0); eq(ui.previews.offsets.ws1, 0)
    scrollPreview(ui, first, -10, 0, false, ui.frame.x + 10); eq(ui.previews.offsets.ws1, 0)
    scrollPreview(ui, first, 0, -1); eq(ui.row, 2)
    ui:cancel(); e:flushPreviews(); eq(#e.captures, 0)
end)
test("clicking a preview selects its workspace and empty workspaces show a message", function()
    local _, ui, _, selected, items = picker(2)
    previewRows(ui, items, 0); eq(hasText(ui, "A"), true)
    local hit = ui.hitRows[2]
    ui.tap.callback({ getType = function() return 1 end,
        location = function() return { x = ui.frame.x + ui.previewColumn.x + 10, y = ui.frame.y + hit.top + 30 } end })
    eq(selected().workspaceId, "ws2")
end)
test("switch preview refresh includes new windows even when refreshOnOpen is false", function()
    local e, instance = app({ refreshOnOpen = false })
    instance:toggleSwitch(); e:flush(); e:flushPreviews()
    eq(#instance.ui.cache[1].windows, 2)
    eq(#e.captures, 2)
    instance:toggleSwitch(); e:flush(); assert(next(instance.ui.chooser.previews.images))
    instance:toggleSwitch(); e:flush(); e:flushPreviews(); eq(#e.captures, 2)
    instance:stop()
end)

test("refresh captures only new window identities and retains snapshots on panel changes", function()
    local e, ui, _, _, items = picker(2)
    previewRows(ui, items, 1)
    e:flushPreviews(); eq(#e.captures, 2)
    ui:query("Workspace 1"):query(""); ui:choices(items); e:flushPreviews()
    eq(#e.captures, 2)
    items[1].windows[2] = { id = "added", windowId = 500 }
    ui:choices(items); e:flushPreviews(); eq(#e.captures, 3); eq(e.captures[3], 500)
    items[1].windows = {}; ui:choices(items); e:flushPreviews(); eq(#e.captures, 3)
    ui:begin("move"):choices(items):show()
    assert(next(ui.previews.images)); eq(ui.frame.w, 1440 * require("config").width / 100)
end)
test("a switch opened during an icon refresh receives a follow-up window refresh", function()
    local e, instance = app()
    instance.ui:refresh()
    instance:toggleSwitch(); e:flush(); e:flushPreviews()
    eq(#instance.ui.cache[1].windows, 2)
    eq(#e.captures, 2)
    instance:stop()
end)

test("mixed preview rows compact empty workspaces and keep controls centered", function()
    local _, ui, _, _, items = picker(9)
    previewRows(ui, items, 0)
    items[2].windows = { { id = "window", windowId = 101 } }
    ui:choices(items)
    local first, second, third = ui.hitRows[1], ui.hitRows[2], ui.hitRows[3]
    eq(first.bottom - first.top + 2, 45)
    eq(second.bottom - second.top + 2, 134)
    eq(second.top - first.top, 45); eq(third.top - second.top, 134)
    eq(#ui.hitRows, 9)
    for _, el in ipairs(ui.canvas.elements) do
        if el.text == "Workspace 1" then
            eq(el.frame.w, items[1].labelWidth)
            eq(el.frame.x - (ui.previewColumn.x + ui.previewColumn.w), 10)
            eq(el.frame.y, first.top + (45 - 24) / 2)
        elseif el.text == "A" then eq(el.frame.y, first.top + (45 - 36) / 2 + 7) end
    end
    items[2].windows = {}; ui:choices(items)
    eq(ui.hitRows[2].bottom - ui.hitRows[2].top + 2, 45)
    ui:selectedRow(9); eq(ui.hitRows[#ui.hitRows].index, 9)
end)

local function backgroundTick(e, instance)
    local timer = assert(instance.ui.backgroundTimer)
    eq(timer.delay, instance.config.previewRefreshInterval)
    timer.active = false
    timer.callback()
end

test("background cache warms closed panels and repeats without overlapping work", function()
    local e, instance = app({ previewRefreshInterval = 30 })
    local previews = instance.ui.chooser.previews
    eq(instance.ui.chooser:isVisible(), false)
    eq(#instance.ui.cache[1].windows, 2)
    backgroundTick(e, instance) -- Startup capture queue is still pending.
    eq(#e.pending, 0)
    e:flushPreviews(); eq(#e.captures, 2)
    backgroundTick(e, instance)
    local pending = #e.pending
    backgroundTick(e, instance); eq(#e.pending, pending)
    e:flush(); e:flushPreviews(); eq(#e.captures, 4)
    instance:toggleSwitch(); e:flush(); e:flushPreviews(); eq(#e.captures, 4)
    instance.ui.chooser:query("12")
    local query = instance.ui.chooser:query()
    local selected = instance.ui.chooser:selectedRowContents().workspaceId
    backgroundTick(e, instance); e:flush(); e:flushPreviews()
    eq(instance.ui.chooser:query(), query)
    eq(instance.ui.chooser:selectedRowContents().workspaceId, selected)
    local late = instance.ui.backgroundTimer.callback
    instance:stop(); late(); e:flushPreviews()
    eq(next(previews.images), nil)
    for _, timer in ipairs(e.timers) do eq(timer.active, false) end
end)

test("background snapshots preserve images on failure and prune closed windows", function()
    local e = Mock.new()
    local previews = require("window_previews").new(e.hs, function() end)
    local one, two = { id = "one", windowId = 1 }, { id = "two", windowId = 2 }
    e.snapshots[1] = { w = 800, h = 400 }
    previews:sync({ one, two }, true)
    previews:update({ two }); e:previewFrame(); eq(e.captures[1], 2)
    e:flushPreviews()
    local image = previews:get(one).image
    e.snapshots[1] = "throw"
    previews:sync({ one }, true); e:flushPreviews()
    eq(previews:get(one).image, image)
    eq(previews.images["two:2"], nil)
    previews:sync({}, true); e:flushPreviews(); eq(next(previews.images), nil)
end)

test("failed background queries retain previews and retry on the next tick", function()
    local e, instance = app({ previewRefreshInterval = 30 })
    e:flushPreviews()
    local images = instance.ui.chooser.previews.images
    backgroundTick(e, instance)
    e:step(function() return "failure", 1, "offline" end); e:flush()
    eq(instance.ui.chooser.previews.images, images)
    eq(#e.alerts, 0); eq(instance.ui.backgroundCapture, false)
    backgroundTick(e, instance); e:flush(); e:flushPreviews()
    eq(#e.captures, 4)
    instance:stop()
end)

test("preview refresh interval rejects invalid values and zero disables scheduling", function()
    for _, interval in ipairs({ -1, "30", math.huge, 0/0 }) do
        rejects(function() Project.new({ previewRefreshInterval = interval }) end, "Invalid previewRefreshInterval")
    end
    local e, instance = app({ previewRefreshInterval = 0 })
    eq(instance.ui.backgroundTimer, nil); e:flushPreviews(); eq(#e.captures, 0)
    instance:stop()
end)

local function windowKey(window)
    return "window:" .. window.id .. ":" .. window.windowId
end
local function typeSequence(key, sequence)
    local codes = { a = 0, s = 1, d = 2, f = 3, g = 5, h = 4, j = 38, k = 40, l = 37,
        q = 12, w = 13, e = 14, r = 15, t = 17, y = 16, u = 32, i = 34, o = 31, p = 35,
        z = 6, x = 7, c = 8, v = 9, b = 11, n = 45, m = 46 }
    for letter in sequence:gmatch(".") do key(codes[letter]) end
end
test("every window gets a distinct shortcut and selection returns both window identities", function()
    local _, ui, key, selected, items = picker(2)
    previewRows(ui, items, 2)
    local first, second = items[1].windows[1], items[1].windows[2]
    assert(ui.shortcuts[windowKey(first)] ~= ui.shortcuts[windowKey(second)])
    typeSequence(key, ui.shortcuts[windowKey(second)])
    eq(selected().window.id, second.id); eq(selected().window.windowId, second.windowId)
end)
test("window activation validates native identity and never switches or moves workspaces", function()
    local e, api = cli(); local ok, err
    api:focusWindow({ id = "ow_second", windowId = 102 }, function(value, why) ok, err = value, why end)
    e:flush(); eq(ok, true); eq(err, nil); eq(e.calls[2][1], "window"); eq(e.calls[2][2], "focus")
    eq(e.calls[2][3], "ow_second"); eq(#e:moves(), 0)
    e.calls = {}
    api:focusWindow({ id = "ow_second", windowId = 999 }, function(value, why) ok, err = value, why end)
    e:flush(); eq(ok, nil); assert(err:find("identity changed")); eq(#e.calls, 1)
    api:focusWindow({ id = "closed", windowId = 102 }, function(value, why) ok, err = value, why end)
    e:flush(); eq(ok, nil); assert(err:find("closed")); eq(#e.calls, 2)
end)
test("switch panel letters focus a specific window through the CLI", function()
    local e, instance = app()
    instance:toggleSwitch(); e:flush()
    local ui = instance.ui.chooser
    local label = ui.shortcuts["window:ow_second:102"]
    for letter in label:gmatch(".") do ui:letter(letter) end
    e:flush()
    eq(#e:moves(), 0)
    local focused
    for _, args in ipairs(e.calls) do if args[1] == "window" then focused = args end end
    eq(focused[2], "focus"); eq(focused[3], "ow_second")
    instance:stop()
end)
test("partial input hides typed characters and unrelated badges until timeout", function()
    local _, ui, key = picker(27)
    key(0); eq(ui.pendingPrefix, "a")
    local matching, unrelated = {}, {}
    ui:badge(matching, "ws2", 100, 100); ui:badge(unrelated, "ws27", 100, 100)
    eq(matching[2].text, "S"); eq(#unrelated, 0)
    eq(ui.sequenceTimer.delay, 0.3)
    ui.sequenceTimer.callback()
    eq(ui.pendingPrefix, ""); eq(ui.sequenceTimer, nil)
    local restored = {}; ui:badge(restored, "ws2", 100, 100); eq(restored[2].text, "AS")
end)
test("three-letter shortcuts restart the configurable timer after each correct letter", function()
    local e, ui, key, selected = picker(677, "switch", { shortcutSequenceTimeoutMs = 500 })
    key(0); local first = ui.sequenceTimer
    eq(first.delay, 0.5)
    e.now = e.now + 400000000
    key(0); local second = ui.sequenceTimer
    eq(ui.pendingPrefix, "aa"); eq(first.active, false); eq(second.delay, 0.5)
    first.callback(); eq(ui.pendingPrefix, "aa")
    e.now = e.now + 400000000
    key(1); eq(selected().workspaceId, "ws2"); eq(second.active, false)
end)
test("a letter after the deadline starts a fresh sequence even before the timer callback", function()
    local e, ui, key, selected = picker(27)
    key(0); local late = ui.sequenceTimer
    e.now = e.now + 301000000
    key(1); eq(selected(), nil); eq(ui.pendingPrefix, "s")
    late.callback(); eq(ui.pendingPrefix, "s")
    key(0); eq(selected().workspaceId, "ws27")
end)
test("repeated key-down events cannot finish a shortcut", function()
    local _, ui, key, selected = picker(27)
    key(0); local timer = ui.sequenceTimer
    key(0, {}, "a", 10, true)
    eq(ui.pendingPrefix, "a"); eq(selected(), nil); eq(ui.sequenceTimer, timer)
    key(0); eq(selected().workspaceId, "ws1")
end)
test("navigation search and closing reset prefixes and cancel pending timers", function()
    for _, code in ipairs({ 123, 124, 125, 126, 44, 53 }) do
        local _, ui, key = picker(27)
        key(0); local timer = ui.sequenceTimer
        key(code); eq(ui.pendingPrefix, ""); eq(timer.active, false)
        timer.callback(); eq(ui.pendingPrefix, "")
    end
    local _, ui, key = picker(27)
    key(0); local timer = ui.sequenceTimer
    ui:cancel(); eq(timer.active, false); timer.callback(); eq(ui.visible, false)
    ui:begin("move"); eq(ui.pendingPrefix, "")
end)
test("window arrows clamp and reveal the selected preview while rows wrap", function()
    local _, ui, key, selected, items = picker(3)
    previewRows(ui, items, 5)
    items[2].windows = { items[2].windows[1] }; items[3].windows = {}; ui:choices(items)
    key(123); eq(ui.windowIndex, 1)
    for _ = 1, 6 do key(124) end
    eq(ui.windowIndex, 5); assert(ui.previews.offsets.ws1 > 0)
    key(125); eq(ui.row, 2); eq(ui.windowIndex, 1)
    key(125); eq(ui.row, 3); eq(ui.windowIndex, 1)
    key(125); eq(ui.row, 1); key(124); key(36)
    eq(selected().window.id, items[1].windows[2].id)
end)
test("preview clicks activate that window but workspace label clicks only highlight", function()
    local _, ui, _, selected, items = picker(2)
    previewRows(ui, items, 2)
    local function click(x, y)
        ui.tap.callback({ getType = function() return 1 end,
            location = function() return { x = ui.frame.x + x, y = ui.frame.y + y } end })
    end
    local hit = ui.hitRows[2]
    click(ui.frame.w - 30, hit.top + 25); eq(ui.row, 2); eq(selected(), nil)
    local preview = ui.hitRows[2].previews[2]
    click(preview.left + 10, hit.top + 25)
    eq(selected().window.id, items[2].windows[2].id)
end)
test("badges center on previews and empty placeholders with unchanged style", function()
    local _, ui, _, _, items = picker(2)
    items[1].windows = { { id = "one", windowId = 1, frame = { w = 500, h = 500 } } }
    ui:choices(items)
    local label = ui.shortcuts[windowKey(items[1].windows[1])]:upper()
    local hit = ui.hitRows[1]; local preview = hit.previews[1]
    local found = false
    for i, element in ipairs(ui.canvas.elements) do
        if element.text == label then
            found = true
            eq(element.frame.x + element.frame.w / 2, (preview.left + preview.right) / 2)
            eq(element.frame.y + element.frame.h / 2, hit.top + 12 + 110 / 2)
            local square = ui.canvas.elements[i - 1]
            eq(square.fillColor.alpha, 0.4); eq(square.roundedRectRadii.xRadius, 8)
        end
    end
    eq(found, true); eq(ui.previewColumn.x, 20)
end)
test("capacity growth rebuilds uniform shortcuts and resets pending input", function()
    local _, ui, key, _, items = picker(676)
    key(0); local timer = ui.sequenceTimer
    items[677] = { workspaceId = "added", text = "New", displayId = "display", windows = {} }
    ui:choices(items)
    eq(ui.shortcutLength, 3); eq(ui.shortcuts.ws1, "aaa"); eq(ui.shortcuts.added, "saa")
    eq(ui.pendingPrefix, ""); eq(timer.active, false)
end)
test("window shortcuts and selection survive reordering without swapping window identity", function()
    local _, ui, key, _, items = picker(1)
    previewRows(ui, items, 3)
    key(124); local second = items[1].windows[2]
    local label = ui.shortcuts[windowKey(second)]
    local refreshed = F.copy(items)
    refreshed[1].windows = { second, items[1].windows[1], items[1].windows[3] }
    ui:choices(refreshed)
    eq(ui.windowIndex, 1); eq(ui.shortcuts[windowKey(second)], label)
end)
test("shortcut sequence timeout accepts only positive integer milliseconds", function()
    for _, value in ipairs({ 0, -1, 1.5, math.huge, "300" }) do
        rejects(function() Project.new({ shortcutSequenceTimeoutMs = value }) end, "Invalid shortcutSequenceTimeoutMs")
    end
    eq(Project.new({ shortcutSequenceTimeoutMs = 450 }).config.shortcutSequenceTimeoutMs, 450)
end)

test("switch width fits preview rows and labels and caps at 80 percent", function()
    local e, ui, _, _, items = picker(2)
    items[1].windows = { { id = "wide", windowId = 1, frame = { w = 1000, h = 500 } } }
    items[2].windows = { { id = "portrait", windowId = 2, frame = { w = 500, h = 1000 } } }
    ui:choices(items)
    eq(ui.frame.w, 220 + 100 + 50)
    eq(ui.frame.x, (1440 - ui.frame.w) / 2)
    eq(ui.previewColumn.w, 220)
    items[1].windows[2] = { id = "huge", windowId = 3, frame = { w = 10000, h = 500 } }
    ui:choices(items)
    eq(ui.frame.w, 1440 * 0.8)
    assert(ui.hitRows[1].maxPreviewOffset > 0)
    ui:query("Workspace 2"); eq(ui.frame.w, 1440 * 0.8)
    ui:query("")
    items[1].windows = {}; ui:choices(items)
    eq(ui.frame.w, 55 + 100 + 50)
    e.snapshots[2] = { w = 1000, h = 500 }
    e:flushPreviews()
    eq(ui.frame.w, 220 + 100 + 50)
    eq(ui.frame.x, (1440 - ui.frame.w) / 2)
end)

local function gesture(configuration)
    local e, count = Mock.new(), 0
    local controller = require("double_press").new(e.hs,
        configuration or { modifiers = { "ctrl", "alt", "shift" }, intervalMs = 200 },
        function() count = count + 1 end):start()
    local function event(flags, kind, code)
        return controller.tap.callback({ getType = function() return kind or 12 end,
            getFlags = function() return flags or {} end, getKeyCode = function() return code or 54 end })
    end
    local function tap()
        event({ ctrl = true }); event({ ctrl = true, alt = true })
        event({ ctrl = true, alt = true, shift = true })
        event({ ctrl = true, alt = true }); event({ ctrl = true }); event({})
    end
    return e, controller, event, tap, function() return count end
end
test("two complete Hyper taps toggle once without consuming events", function()
    local _, controller, event, tap, count = gesture()
    tap(); eq(count(), 0)
    tap(); eq(count(), 1); eq(controller.lastTap, nil)
    eq(event({}), false)
    tap(); eq(count(), 1)
    controller:stop(); eq(controller.tap.enabled, false)
end)
test("ordinary typing before Hyper does not invalidate its first tap", function()
    local _, _, event, tap, count = gesture()
    event({}, 10); tap(); tap(); eq(count(), 1)
end)
test("slow taps long holds and timer expiry do not trigger", function()
    local e, controller, event, tap, count = gesture()
    tap(); e.now = e.now + 201000000; tap(); eq(count(), 0)
    controller.timer.callback(); tap(); eq(count(), 0)
    event({ ctrl = true, alt = true, shift = true })
    e.now = e.now + 201000000; event({}); eq(count(), 0)
end)
test("keys mouse input and extra modifiers cancel a pending double press", function()
    for _, kind in ipairs({ 10, 1, 3, 25, 22 }) do
        local _, _, event, tap, count = gesture()
        tap(); event({}, kind); tap(); eq(count(), 0)
        tap(); eq(count(), 1)
    end
    local _, _, event, tap, count = gesture()
    tap(); event({ ctrl = true, alt = true, shift = true, cmd = true }); event({})
    tap(); eq(count(), 0); tap(); eq(count(), 1)
end)
test("Hyper plus W remains a shortcut rather than a tap", function()
    local _, _, event, tap, count = gesture()
    local hyper = { ctrl = true, alt = true, shift = true }
    event(hyper); event(hyper, 10); event({})
    tap(); eq(count(), 0); tap(); eq(count(), 1)
end)
test("double-press timeout is configurable and stop ignores expired timers", function()
    local e, controller, _, tap, count = gesture({ modifiers = { "ctrl", "alt", "shift" }, intervalMs = 350 })
    tap(); eq(controller.timer.delay, 0.35)
    e.now = e.now + 220000000; tap(); eq(count(), 1)
    tap(); local timer = controller.timer
    controller:stop(); eq(timer.active, false); timer.callback(); eq(count(), 1)
end)
test("application binds only Hyper-W by default and double press toggles the switcher", function()
    local e, instance = app()
    eq(e.hotkeys, 1); eq(instance.switchHotkey, nil)
    local controller = instance.doublePress
    local function tap()
        controller.tap.callback({ getType = function() return 12 end,
            getFlags = function() return { cmd = true } end, getKeyCode = function() return 54 end })
        controller.tap.callback({ getType = function() return 12 end, getFlags = function() return {} end,
            getKeyCode = function() return 54 end })
    end
    tap(); tap(); e:flush(); eq(instance.ui.chooser.visible, true)
    tap(); tap(); e:flush(); eq(instance.ui.chooser.visible, false)
    instance:stop(); eq(controller.tap.enabled, false)
end)
test("panel input cancels a pending tap even if the picker consumes its event", function()
    local e, instance = app()
    instance:toggleSwitch(); e:flush()
    instance.doublePress.lastTap = e.hs.timer.absoluteTime() / 1e6
    instance.ui.chooser.tap.callback({ getType = function() return 10 end,
        getFlags = function() return {} end, getKeyCode = function() return 44 end,
        getProperty = function() return 0 end })
    eq(instance.doublePress.lastTap, nil)
    instance:stop()
end)
test("legacy switch hotkey is available when double press is disabled", function()
    local e, instance = app({ switchDoublePress = { enabled = false, modifiers = { "ctrl" }, intervalMs = 200 } })
    eq(e.hotkeys, 2); eq(instance.doublePress, nil)
    instance.switchHotkey.callback(); e:flush(); eq(instance.ui.chooser.visible, true)
    instance:stop()
end)
test("double-press configuration rejects invalid modifiers and timing", function()
    for _, configuration in ipairs({
        { enabled = true, modifiers = {}, intervalMs = 200 },
        { enabled = true, modifiers = { "bad" }, intervalMs = 200 },
        { enabled = true, modifiers = { "ctrl", "ctrl" }, intervalMs = 200 },
        { enabled = true, modifiers = { "ctrl" }, intervalMs = 0 },
        { enabled = true, modifiers = { "ctrl" }, intervalMs = 2.5 },
        { enabled = true, modifiers = { "ctrl" }, intervalMs = math.huge },
    }) do rejects(function() Project.new({ switchDoublePress = configuration }) end, "Invalid switchDoublePress") end
end)

test("physical Right Command double press ignores Left Command and mixed sides", function()
    local _, _, event, _, count = gesture({ modifiers = { "cmd" }, keyCode = 54, intervalMs = 200 })
    local function tap(code)
        eq(event({ cmd = true }, 12, code), false); eq(event({}, 12, code), false)
    end
    tap(55); tap(55); eq(count(), 0)
    tap(54); tap(55); tap(54); eq(count(), 0)
    tap(54); eq(count(), 1)
    event({ cmd = true }, 12, 55)
    event({ cmd = true }, 12, 54)
    event({ cmd = true }, 12, 54)
    event({}, 12, 55)
    tap(54); eq(count(), 1); tap(54); eq(count(), 2)
end)
test("Right Command shortcuts and extra modifiers cannot count as taps", function()
    local _, _, event, _, count = gesture({ modifiers = { "cmd" }, keyCode = 54, intervalMs = 200 })
    local function tap()
        event({ cmd = true }, 12, 54); event({}, 12, 54)
    end
    event({ cmd = true }, 12, 54); event({ cmd = true }, 10, 0); event({}, 12, 54)
    tap(); eq(count(), 0)
    event({ cmd = true, shift = true }, 12, 54); event({}, 12, 54)
    tap(); eq(count(), 0); tap(); eq(count(), 1)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
