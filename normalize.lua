-- Pure Lua: CLI schemas never leak into the chooser or icon renderer.
local M = {}

local function object(value, label)
    assert(type(value) == "table", "Unexpected " .. label .. " structure")
    return value
end

function M.unwrap(value, kind)
    object(value, "JSON")
    for _ = 1, 5 do
        assert(value.ok ~= false, tostring(value.message or value.code or "OmniWM error"))
        if value.kind and value.kind ~= "query" and value.kind ~= "command" and kind then
            assert(value.kind == kind, "Unexpected result kind: " .. tostring(value.kind))
        end
        if type(value.result) == "table" then value = value.result
        elseif type(value.payload) == "table" then value = value.payload
        else return value end
    end
    error("Too many JSON envelope layers")
end

function M.workspaces(payload)
    local rows = object(payload.workspaces, "workspaces")
    local out, ids, numbers = {}, {}, {}
    for i, row in ipairs(rows) do
        object(row, "workspace")
        assert(type(row.id) == "string" and row.id ~= "", "Missing workspace UUID")
        local number = tonumber(row.number)
        assert(number and number > 0 and number % 1 == 0, "Invalid workspace number")
        assert(not ids[row.id] and not numbers[number], "Duplicate workspace identity")
        ids[row.id], numbers[number] = true, true
        out[#out + 1] = {
            id = row.id, number = number, name = tostring(row.displayName or row.rawName or number),
            rawName = row.rawName, layout = row.layout, order = i,
            displayId = row.display and row.display.id,
            displayName = row.display and row.display.name or "",
            current = row.isCurrent == true, count = row.counts and row.counts.total,
            apps = {},
        }
    end
    table.sort(out, function(a, b) return a.number < b.number end)
    return out
end

local function applications(rows)
    local apps, seen = {}, {}
    for _, row in ipairs(object(rows, "workspace applications")) do
        local bundle = row.bundleId or (row.app and row.app.bundleId)
        local name = row.appName or (row.app and row.app.name) or bundle or "Unknown app"
        if type(bundle) ~= "string" or bundle == "" then bundle = nil end
        local key = bundle or ("unknown:" .. tostring(name))
        if not seen[key] then
            seen[key] = true
            apps[#apps + 1] = { bundleId = bundle, name = tostring(name), key = key }
        end
    end
    table.sort(apps, function(a, b) return a.key < b.key end)
    return apps
end

-- Returns false when a projection is incomplete; caller can query windows instead.
function M.mergeBar(workspaces, payload)
    local byId = {}
    for _, monitor in ipairs(object(payload.monitors, "workspace-bar monitors")) do
        for _, row in ipairs(object(monitor.workspaces, "workspace-bar workspaces")) do
            if type(row.windows) == "table" then byId[row.id] = applications(row.windows) end
        end
    end
    local complete = true
    for _, ws in ipairs(workspaces) do
        ws.apps = byId[ws.id] or {}
        if not byId[ws.id] or (#ws.apps == 0 and (ws.count or 0) > 0) then complete = false end
    end
    return complete
end

function M.mergeWindows(workspaces, payload)
    local byId = {}
    for _, row in ipairs(object(payload.windows, "windows")) do
        local id = row.workspace and row.workspace.id
        if id then
            byId[id] = byId[id] or {}
            byId[id][#byId[id] + 1] = row
        end
    end
    for _, ws in ipairs(workspaces) do ws.apps = applications(byId[ws.id] or {}) end
end

function M.focused(payload)
    local row = object(payload.window, "focused window (no managed window focused)")
    assert(type(row.id) == "string" and row.workspace and row.workspace.id, "Missing source window identity")
    return { id = row.id, workspaceId = row.workspace.id }
end

function M.column(payload, source)
    local rows = object(payload.windows, "windows")
    local found
    for _, row in ipairs(rows) do if row.id == source.id then found = row end end
    assert(found, "Source window has closed")
    assert(found.workspace and found.workspace.id == source.workspaceId, "Source window changed workspace")
    assert(found.mode == "tiling" and found.isScratchpad ~= true
        and type(found.columnIndex) == "number" and found.columnIndex >= 1,
        "Source window is not in a Niri column (floating/scratchpad/unknown)")
    local members = {}
    for _, row in ipairs(rows) do
        if row.workspace and row.workspace.id == source.workspaceId and row.columnIndex == found.columnIndex then
            members[#members + 1] = row.id
        end
    end
    table.sort(members)
    return {
        id = source.id, workspaceId = source.workspaceId, columnIndex = found.columnIndex,
        windowId = found.windowId, members = table.concat(members, "\n"),
        isFocused = found.isFocused == true,
    }
end

function M.capabilities(payload)
    assert(payload.appVersion == "0.7.6" and payload.protocolVersion == 19,
        "Supported OmniWM version: 0.7.6 / protocol 19; check compatibility before using another version")
    local move, focus, queries = false, false, {}
    for _, cmd in ipairs(object(payload.commands, "command registry")) do
        if cmd.name == "move-column-to-workspace" then
            move = cmd.arguments and cmd.arguments[1] and cmd.arguments[1].kind == "workspace-number"
        end
    end
    for _, action in ipairs(object(payload.windowActions, "window actions")) do
        if action.name == "focus" and action.path == "window focus <opaque-id>" then focus = true end
    end
    for _, query in ipairs(object(payload.queries, "query registry")) do queries[query.name] = true end
    assert(move and focus and queries.windows and queries.workspaces and queries["workspace-bar"]
        and queries["focused-window"], "Required OmniWM commands/queries are unavailable")
    return true
end

return M
