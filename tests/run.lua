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
    local instance = Project.new(overrides):start()
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
    eq(e.hotkeys, 1); instance:start(); eq(e.hotkeys, 1)
    instance:toggle(); e:flush(); eq(e.chooser.visible, true); eq(#e.chooser.items, 2)
    local builds = instance.icons.builds
    e.chooser:cancel(); eq(#e:moves(), 0)
    instance:toggle(); e:flush(); eq(instance.icons.builds, builds)
    assert(instance:diagnostics().metrics.warmOpenMs)
    instance:stop(); instance:stop(); eq(e.hotkeys, 0); eq(e.canvases, 0); eq(e.chooser.deleted, true)
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

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
