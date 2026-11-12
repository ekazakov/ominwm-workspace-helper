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
test("large streamed JSON is assembled with the completion tail", function()
    local e, api = cli()
    local result, err
    api:query("capabilities", function(value, why) result, err = value, why end)
    local task = e.tasks[1]
    -- Keep the real pipe-buffer boundary in this regression, even with token JSON.
    local output = string.rep(" ", 70000) .. e:token(F.envelope("capabilities", F.capabilities))
    local decode = e.hs.json.decode
    e.hs.json.decode = function(value) return decode(value:match("^%s*(.*)$")) end
    for offset = 1, 65536, 4096 do
        eq(task.streamCallback(task, output:sub(offset, offset + 4095), ""), true)
    end
    eq(result, nil)
    task.callback(0, output:sub(65537), ""); e:drain()
    eq(err, nil); eq(N.capabilities(result), true)
    eq(e.timers[1].active, false); eq(next(api.tasks), nil)
end)
test("streamed stderr and raw stdout preserve all chunks without duplicate callbacks", function()
    local e, api = cli()
    local result, err, count = nil, nil, 0
    api:query("windows", function(value, why) result, err = value, why; count = count + 1 end)
    local task = e.tasks[1]
    task.streamCallback(task, "", "permission ")
    task.callback(2, "", "denied"); e:drain()
    assert(err:find("permission denied")); eq(count, 1); eq(result, nil)
    task.streamCallback(nil, "ignored", "ignored")
    eq(count, 1)
    api:run({ "version" }, function(value) result = value end, true)
    task = e.tasks[2]
    task.streamCallback(task, "Omni", "")
    task.callback(0, "WM", ""); e:drain()
    eq(result, "OmniWM")
end)
test("output delivered after termination is collected before parsing", function()
    local e, api = cli(); local result, err, count
    count = 0
    api:query("focused-window", function(value, why)
        result, err = value, why; count = count + 1
    end)
    local task = e.tasks[1]
    local output = e:token(F.envelope("focused-window", F.focused))
    task.callback(0, "", "")
    eq(count, 0)
    task.streamCallback(nil, output, "")
    e:drain()
    eq(err, nil); eq(result, F.focused); eq(count, 1)
    task.streamCallback(nil, output, "")
    e:drain(); eq(count, 1)
end)
test("stop cancels deferred parsing after process termination", function()
    local e, api = cli(); local count = 0
    api:query("windows", function() count = count + 1 end)
    e.tasks[1].callback(0, "", "")
    api:stop(); e:drain(); eq(count, 0)
    for _, timer in ipairs(e.timers) do eq(timer.active, false) end
end)
test("timeout reports once; late callbacks and stop cannot continue a transaction", function()
    local e, api = cli(); local count = 0
    api:query("windows", function() count = count + 1 end)
    local task = e.tasks[1]
    e.timers[1].callback(); eq(count, 1); eq(task.terminated, true)
    e:step(); eq(count, 1)
    api:query("windows", function() count = count + 1 end)
    api:stop(); e:flush(); eq(count, 1); eq(next(api.tasks), nil)
end)
test("task launch failure releases timeout and pending references", function()
    local e, api = cli(); e.failStart = true; local err
    api:query("windows", function(_, why) err = why end)
    assert(err); eq(next(api.tasks), nil); eq(e.timers[1].active, false)
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
    eq(e.hotkeys, 2); instance:start(); eq(e.hotkeys, 2)
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
    eq(first.running, false); eq(e.hotkeys, 2); second:stop(); eq(e.hotkeys, 0)
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
    instance.switchHotkey.callback(); e:flush()
    eq(e.chooser.visible, true); eq(instance.ui.mode, "switch")
    instance.switchHotkey.callback(); e:flush()
    eq(e.chooser.visible, false); eq(#e:moves(), 0)
    instance:stop()
end)

local function picker(count, mode)
    local e = Mock.new()
    local selected
    local ui = require("canvas_picker").new(e.hs, F.copy(require("config")),
        { text = function(_, key) return key end }, function(choice) selected = choice end)
    local items = {}
    for i = 1, count do
        items[i] = { workspaceId = "ws" .. i, text = "Workspace " .. i, displayId = "display", displayName = "Display" }
    end
    ui:begin(mode or "switch"):choices(items):show()
    local function key(code, flags, value, kind)
        return ui.tap.callback({ getType = function() return kind or 10 end,
            getKeyCode = function() return code end, getFlags = function() return flags or {} end,
            getUnicodeString = function() return value or "" end })
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
    eq(key(13, { ctrl = true, alt = true, shift = true, cmd = true }), false)
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
    ui:choices({ items[3], items[1], { workspaceId = "new", text = "New", displayId = "display" } })
    eq(ui.shortcuts.ws3, "d"); eq(ui.shortcuts.ws1, "a")
    eq(ui.shortcuts.ws2, "s"); eq(ui.shortcuts.new, "f")
    eq(ui:query(), "Workspace 3"); eq(ui.searching, true)
    ui:begin("switch"):choices({ items[3], items[1] })
    eq(ui.shortcuts.ws3, "a"); eq(ui.pendingPrefix, ""); eq(ui.searching, false)
end)
test("loading rows do not allocate shortcuts and later refresh preserves shortcut length", function()
    local _, ui, key, selected, items = picker(27)
    ui:begin("switch"):choices({ { text = "Loading", valid = false } })
    eq(ui.shortcutLength, nil); eq(ui.shortcutCount, 0)
    ui:choices({ items[1] }); eq(ui.shortcuts.ws1, "a")
    ui:choices(items); eq(ui.shortcutLength, 1); eq(ui.shortcuts.ws27, nil)
    key(125); eq(ui.visible, true); eq(selected(), nil)
    ui:selectedRow(27); key(36); eq(selected().workspaceId, "ws27")
end)
test("shortcuts select offscreen workspaces and two-letter capacity leaves extras accessible", function()
    local _, ui, key, selected = picker(677)
    eq(ui.shortcutCount, 676); eq(ui.shortcuts.ws676, "mm"); eq(ui.shortcuts.ws677, nil)
    ui:selectedRow(100); eq(ui.shortcuts.ws1, "aa")
    key(46); key(46); eq(selected().workspaceId, "ws676")
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
    press(1); e:flush()
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
    eq(ui.frame.w, 1440 * 0.9); eq(ui.frame.h, 820)
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
    ui:query("Workspace 1"); e:flushPreviews(); eq(ui.shortcuts.ws1, "a")
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
    previewRows(ui, items, 0); eq(hasText(ui, "emptyWorkspace"), true)
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

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
