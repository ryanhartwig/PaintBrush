local config = {}

config.ModDir = debug.getinfo(1, "S").source:match("@(.*/)")  .. "../"
config.VERSION = "1.0.0"

-- Defaults
config.PaintKey = "P"
config.UndoKey = "Z"
config.TraceDistance = 5000
config.MaxUndoStack = 50
config.AutoSave = true
config.ShowMaterialPaths = false
config.SwatchSize = 48

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
return config
