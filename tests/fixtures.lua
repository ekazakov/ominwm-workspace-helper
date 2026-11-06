-- Synthetic records preserving the observed OmniWM 0.7.6/protocol 19 schema.
local M = {}
function M.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, item in pairs(value) do out[key] = M.copy(item) end
    return out
end
function M.envelope(kind, payload)
    return { ok = true, kind = "query", version = 19, result = { kind = kind, payload = payload } }
end
M.capabilities = {
    appVersion = "0.7.6", protocolVersion = 19,
    commands = { { name = "move-column-to-workspace", arguments = { { kind = "workspace-number" } } } },
    windowActions = { { name = "focus", path = "window focus <opaque-id>" } },
    queries = { { name = "windows" }, { name = "workspaces" }, { name = "workspace-bar" }, { name = "focused-window" } },
}
M.workspaces = { workspaces = {
    { id = "uuid-dest", number = 12, rawName = "12", displayName = "Разработка 🚀", layout = "niri",
        display = { id = "display:2", name = "External" }, counts = { total = 0 }, isCurrent = false },
    { id = "uuid-source", number = 1, rawName = "1", displayName = "Разработка 🚀", layout = "niri",
        display = { id = "display:1", name = "Built-in" }, counts = { total = 2 }, isCurrent = true },
} }
M.bar = { monitors = { { id = "display:1", workspaces = {
    { id = "uuid-source", windows = {
        { id = "ow_source", bundleId = "com.example.Editor", appName = "Editor" },
        { id = "ow_second", bundleId = "com.example.Editor", appName = "Editor" },
    } },
} }, { id = "display:2", workspaces = { { id = "uuid-dest", windows = {} } } } } }
M.focused = { window = { id = "ow_source", workspace = { id = "uuid-source", number = 1 } } }
M.windows = { windows = {
    { id = "ow_source", windowId = 101, workspace = { id = "uuid-source", number = 1 },
        mode = "tiling", columnIndex = 1, isFocused = true, app = { bundleId = "com.example.Editor", name = "Editor" } },
    { id = "ow_second", windowId = 102, workspace = { id = "uuid-source", number = 1 },
        mode = "tiling", columnIndex = 1, isFocused = false, app = { bundleId = "com.example.Editor", name = "Editor" } },
} }
return M
