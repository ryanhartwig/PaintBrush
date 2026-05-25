local config = {}

config.ModDir = debug.getinfo(1, "S").source:match("@(.*/)")  .. "../"
config.VERSION = "1.0.1"

-- Defaults
config.PickerKey = "B"
config.PaintKey = "E"
config.UndoKey = "Z"
config.TraceDistance = 5000
config.MaxUndoStack = 50
config.AutoSave = true

local function loadConfig()
    local file = io.open(config.ModDir .. "config.txt", "r")
    if not file then return end
    for line in file:lines() do
        local key, value = line:match("^(%w+)=(.+)$")
        if key and value then
            value = value:match("^%s*(.-)%s*$") -- trim
            if value == "true" then value = true
            elseif value == "false" then value = false
            elseif tonumber(value) then value = tonumber(value)
            end
            config[key] = value
        end
    end
    file:close()
end

loadConfig()

-- Build hash: content-based fingerprint for verifying code sync across machines
local function computeBuildHash()
    local hash = 0
    local scriptDir = config.ModDir .. "Scripts/"
    local files = {"main.lua", "config.lua", "painter.lua", "sync.lua",
                   "state.lua", "detection.lua", "materials.lua", "ui.lua", "textures.lua"}
    for _, fname in ipairs(files) do
        local f = io.open(scriptDir .. fname, "r")
        if f then
            local content = f:read("*a")
            f:close()
            for i = 1, #content do
                hash = (hash * 31 + content:byte(i)) % 1000000007
            end
        end
    end
    return string.format("%07x", hash)
end

config.BUILD_HASH = computeBuildHash()

return config
