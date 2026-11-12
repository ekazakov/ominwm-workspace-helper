-- Run this file from the Hammerspoon Console before enabling workspace previews.
-- Images stay in memory. The report contains no window titles or image content.
local cli = "/opt/homebrew/bin/omniwmctl"
local function query(kind)
    local output, ok = hs.execute(cli .. " query " .. kind .. " --format json")
    assert(ok, "Cannot query OmniWM " .. kind)
    local payload = hs.json.decode(output)
    assert(type(payload) == "table", "Invalid OmniWM response")
    for _ = 1, 5 do
        assert(payload.ok ~= false, "OmniWM query failed")
        if type(payload.result) == "table" then payload = payload.result
        elseif type(payload.payload) == "table" then payload = payload.payload
        else return payload end
    end
    error("Unexpected OmniWM response")
end
local current = {}
for _, ws in ipairs(query("workspaces").workspaces or {}) do
    current[ws.id] = ws.isCurrent == true
end
local report = { active = { attempted = 0, captured = 0 }, inactive = { attempted = 0, captured = 0 } }
for _, window in ipairs(query("windows").windows or {}) do
    local workspace = window.workspace and window.workspace.id
    local nativeId = tonumber(window.windowId)
    if workspace and current[workspace] ~= nil and nativeId then
        local group = report[current[workspace] and "active" or "inactive"]
        group.attempted = group.attempted + 1
        local ok, image = pcall(hs.window.snapshotForID, nativeId)
        if ok and image then
            local size = image:size()
            if size and size.w > 0 and size.h > 0 then group.captured = group.captured + 1 end
        end
    end
end
print("Window snapshot preflight: " .. hs.inspect(report))
return report
