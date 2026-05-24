local painter = require("painter")
local config  = require("config")

local state = {}

-- ============================================================
-- Minimal JSON encoder/decoder
-- Handles: objects, arrays, strings, integers, booleans, null
-- ============================================================

local json = {}

-- Encoder

local function encodeValue(val)
    local t = type(val)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "number" then
        return tostring(math.floor(val))
    elseif t == "string" then
        -- Escape backslashes and double-quotes
        local escaped = val:gsub("\\", "\\\\"):gsub('"', '\\"')
        return '"' .. escaped .. '"'
    elseif t == "table" then
        -- Detect array vs object: array if all keys are sequential integers from 1
        local isArray = true
        local n = #val
        for k in pairs(val) do
            if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
                isArray = false
                break
            end
        end
        if isArray then
            local parts = {}
            for i = 1, n do
                parts[i] = encodeValue(val[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            for k, v in pairs(val) do
                table.insert(parts, '"' .. tostring(k) .. '":' .. encodeValue(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function json.encode(val)
    return encodeValue(val)
end

-- Decoder

local function skipWhitespace(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c == " " or c == "\t" or c == "\n" or c == "\r" then
            i = i + 1
        else
            break
        end
    end
    return i
end

local function decodeValue(s, i)
    i = skipWhitespace(s, i)
    if i > #s then return nil, i end
    local c = s:sub(i, i)

    -- String
    if c == '"' then
        local result = {}
        i = i + 1
        while i <= #s do
            local ch = s:sub(i, i)
            if ch == '"' then
                return table.concat(result), i + 1
            elseif ch == "\\" then
                i = i + 1
                local esc = s:sub(i, i)
                if esc == '"' then table.insert(result, '"')
                elseif esc == "\\" then table.insert(result, "\\")
                elseif esc == "/" then table.insert(result, "/")
                elseif esc == "n" then table.insert(result, "\n")
                elseif esc == "r" then table.insert(result, "\r")
                elseif esc == "t" then table.insert(result, "\t")
                else table.insert(result, esc) end
                i = i + 1
            else
                table.insert(result, ch)
                i = i + 1
            end
        end
        return nil, i  -- unterminated string

    -- Object
    elseif c == "{" then
        local obj = {}
        i = i + 1
        i = skipWhitespace(s, i)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while i <= #s do
            i = skipWhitespace(s, i)
            local key, ni = decodeValue(s, i)
            if key == nil then return nil, ni end
            i = skipWhitespace(s, ni)
            -- expect ':'
            if s:sub(i, i) ~= ":" then return nil, i end
            i = i + 1
            local val, vi = decodeValue(s, i)
            i = skipWhitespace(s, vi)
            obj[key] = val
            local sep = s:sub(i, i)
            if sep == "}" then return obj, i + 1 end
            if sep ~= "," then return nil, i end
            i = i + 1
        end
        return nil, i  -- unterminated object

    -- Array
    elseif c == "[" then
        local arr = {}
        i = i + 1
        i = skipWhitespace(s, i)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while i <= #s do
            local val, vi = decodeValue(s, i)
            i = skipWhitespace(s, vi)
            table.insert(arr, val)
            local sep = s:sub(i, i)
            if sep == "]" then return arr, i + 1 end
            if sep ~= "," then return nil, i end
            i = i + 1
        end
        return nil, i  -- unterminated array

    -- null
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4

    -- true
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4

    -- false
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5

    -- Number (integer)
    else
        local numStr = s:match("^-?%d+", i)
        if numStr then
            return tonumber(numStr), i + #numStr
        end
    end

    return nil, i
end

function json.decode(s)
    local val, _ = decodeValue(s, 1)
    return val
end

-- ============================================================
-- Helpers
-- ============================================================

local function getModDir()
    -- config.ModDir is set via debug.getinfo to the Scripts/ folder + "../",
    -- giving us the mod root (PaintBrush/).  Strip any trailing slash for consistency.
    return (config.ModDir or ""):gsub("[/\\]+$", "")
end

local function getSlotName()
    local save = FindFirstOf("UWESaveGame")
    if save and save:IsValid() then
        return save:GetSlotName():ToString()
    end
    return "default"
end

-- Returns the full path for the current slot's state JSON file
function state.getSlotPath()
    local slotName = getSlotName()
    return getModDir() .. "/state/" .. slotName .. ".json"
end

local function guidString(base)
    local ok, guid = pcall(function() return base.BaseNetworkGUID end)
    if not ok or not guid then return nil end
    return string.format("%08X%08X%08X%08X", guid.A, guid.B, guid.C, guid.D)
end

-- ============================================================
-- save()
-- ============================================================

function state.save()
    local slotPath = state.getSlotPath()

    -- Ensure state directory exists
    local stateDir = getModDir() .. "/state"
    os.execute('mkdir "' .. stateDir:gsub("/", "\\") .. '" 2>nul')

    local paintedCells = painter.getPaintedCells()

    -- Build JSON-serialisable structure
    local basesData = {}
    for _, baseData in pairs(paintedCells) do
        local base = baseData.base
        if not base or not base:IsValid() then goto continue end

        local guidStr = guidString(base)
        if not guidStr then goto continue end

        local cellsArr = {}
        for _, c in ipairs(baseData.cells) do
            table.insert(cellsArr, {
                x   = c.cellCoords.X,
                y   = c.cellCoords.Y,
                z   = c.cellCoords.Z,
                mat = c.materialPath,
            })
        end

        if #cellsArr > 0 then
            basesData[guidStr] = { cells = cellsArr }
        end

        ::continue::
    end

    local payload = { version = 1, bases = basesData }
    local jsonStr = json.encode(payload)

    -- Atomic write: write to .tmp, remove old, rename
    local tmpPath = slotPath .. ".tmp"
    local f, err = io.open(tmpPath, "w")
    if not f then
        print(string.format("[PaintBrush] state.save: cannot open temp file: %s\n", tostring(err)))
        return
    end
    f:write(jsonStr)
    f:close()

    os.remove(slotPath)  -- Windows requires removing destination before rename
    os.rename(tmpPath, slotPath)
    local baseCount = 0
    for _ in pairs(basesData) do baseCount = baseCount + 1 end
    print(string.format("[PaintBrush] state.save: saved %d base(s) to %s\n", baseCount, slotPath))
end

-- ============================================================
-- load()
-- ============================================================

function state.load()
    local slotPath = state.getSlotPath()
    local f = io.open(slotPath, "r")
    if not f then
        -- No state file yet — nothing to load
        return
    end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then return end

    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        print(string.format("[PaintBrush] state.load: failed to parse %s\n", slotPath))
        return
    end

    local basesData = parsed.bases
    if type(basesData) ~= "table" then return end

    -- Build a lookup of GUID -> parsed cell list
    -- (guidStr -> { {x,y,z,mat}, ... })

    -- Find all live base actors
    local allBases = FindAllOf("UWESculpturalBaseActor")
    if not allBases then
        print("[PaintBrush] state.load: no bases found in world\n")
        return
    end

    -- Build new paintedCells in painter's internal format
    local newPaintedCells = {}
    local rebuiltBases = {}

    for _, base in ipairs(allBases) do
        if not base:IsValid() then goto nextBase end

        local guidStr = guidString(base)
        if not guidStr then goto nextBase end

        local savedBase = basesData[guidStr]
        if not savedBase or type(savedBase.cells) ~= "table" then goto nextBase end

        -- Must match painter.lua's baseKey(): uses GetFullName() for stability
        local keyOk, key = pcall(function() return base:GetFullName() end)
        if not keyOk then key = tostring(base) end
        local cells = {}
        for _, c in ipairs(savedBase.cells) do
            if type(c.x) == "number" and type(c.y) == "number" and type(c.z) == "number" and type(c.mat) == "string" then
                table.insert(cells, {
                    cellCoords   = { X = c.x, Y = c.y, Z = c.z },
                    materialPath = c.mat,
                })
            end
        end

        if #cells > 0 then
            newPaintedCells[key] = { base = base, cells = cells }
            table.insert(rebuiltBases, base)
        end

        ::nextBase::
    end

    painter.setPaintedCells(newPaintedCells)
    painter.clearHistory()

    for _, base in ipairs(rebuiltBases) do
        pcall(painter.rebuild, base)
    end

    print(string.format("[PaintBrush] state.load: restored %d base(s) from %s\n",
        #rebuiltBases, slotPath))
end

return state
