-- Small LRU used independently for application and composite images.
local M = {}
function M.new(limit)
    local cache = { entries = {}, size = 0, clock = 0, limit = limit }
    function cache:get(key)
        local entry = self.entries[key]
        if entry then self.clock = self.clock + 1; entry.used = self.clock; return entry.value end
    end
    function cache:put(key, value)
        if not self.entries[key] then self.size = self.size + 1 end
        self.clock = self.clock + 1
        self.entries[key] = { value = value, used = self.clock }
        if self.size > self.limit then
            local oldest, used
            for k, entry in pairs(self.entries) do
                if not used or entry.used < used then oldest, used = k, entry.used end
            end
            self.entries[oldest] = nil
            self.size = self.size - 1
        end
        return value
    end
    function cache:clear() self.entries, self.size, self.clock = {}, 0, 0 end
    return cache
end
return M
