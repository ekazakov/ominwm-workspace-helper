local prefix = (...):match("^(.*%.)") or ""
local Cache = require(prefix .. "cache")
local M = {}

function M.new(hs, config)
    local self = {
        apps = Cache.new(config.iconCacheLimit), composites = Cache.new(config.compositeCacheLimit),
        canvas = nil, builds = 0,
    }

    local function canvas()
        if not self.canvas then self.canvas = assert(hs.canvas.new({ x = 0, y = 0, w = 64, h = 64 })) end
        return self.canvas
    end

    local function placeholder()
        if not self.fallback then
            local size = config.iconSize
            local c = canvas():size({ w = size, h = size })
            c:replaceElements({ type = "rectangle", action = "fill",
                roundedRectRadii = { xRadius = 4, yRadius = 4 },
                fillColor = { white = 0.5, alpha = 0.8 }, frame = { x = 2, y = 2, w = size - 4, h = size - 4 } })
            self.fallback = c:imageFromCanvas()
        end
        return self.fallback
    end

    function self:app(bundle)
        if not bundle then return placeholder() end
        local cached = self.apps:get(bundle)
        if cached ~= nil then return cached or placeholder() end
        local ok, image = pcall(hs.image.imageFromAppBundle, bundle)
        self.apps:put(bundle, ok and image or false) -- Cache misses as well.
        return (ok and image) or placeholder()
    end

    function self:composite(apps)
        local parts = { tostring(config.maxIcons), tostring(config.iconSize), config.theme }
        for _, app in ipairs(apps) do parts[#parts + 1] = #app.key .. ":" .. app.key end
        local key = table.concat(parts, "|")
        local cached = self.composites:get(key)
        if cached then return cached end

        local count, size = math.min(#apps, config.maxIcons), config.iconSize
        local images = {}
        -- Load fallback before drawing: it uses the same hidden scratch canvas.
        for i = 1, count do images[i] = self:app(apps[i].bundleId) end
        if count == 0 then images[1], count = placeholder(), 1 end
        local overflow = math.max(0, #apps - config.maxIcons)
        local cells = count + (overflow > 0 and 1 or 0)
        local cols = math.min(3, cells)
        local rows = math.ceil(cells / cols)
        local elements = {}
        for i, image in ipairs(images) do
            elements[#elements + 1] = { type = "image", image = image, imageScaling = "scaleProportionally",
                frame = { x = ((i - 1) % cols) * size, y = math.floor((i - 1) / cols) * size, w = size, h = size } }
        end
        if overflow > 0 then
            elements[#elements + 1] = { type = "text", text = "+" .. overflow,
                textSize = math.max(9, size * 0.5), textAlignment = "center",
                textColor = { white = config.theme == "dark" and 0.95 or 0.15 },
                frame = { x = ((cells - 1) % cols) * size, y = math.floor((cells - 1) / cols) * size + size * 0.2,
                    w = size, h = size * 0.8 } }
        end
        local c = canvas():size({ w = cols * size, h = rows * size })
        c:replaceElements((table.unpack or unpack)(elements))
        local image = assert(c:imageFromCanvas(), "Cannot render application icons")
        self.builds = self.builds + 1
        return self.composites:put(key, image)
    end

    function self:stop()
        if self.canvas then self.canvas:delete(); self.canvas = nil end
        self.apps:clear()
        self.composites:clear()
        self.fallback = nil
    end
    return self
end
return M
