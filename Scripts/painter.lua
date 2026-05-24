local painter = {}

-- paintedCells: { [baseKeyString] = { base = UObject, cells = { {cellCoords={X,Y,Z}, materialPath="..."}, ... } } }
local paintedCells = {}

-- undoStack: array of { baseKey=string, base=UObject, cellCoords={X,Y,Z}, previousMaterial=string|nil }
local undoStack = {}

-- Returns a stable string key for a base UObject.
-- tostring(userdata) gives the Lua wrapper pointer which changes per access.
-- GetFullName() gives a deterministic path like "BP_RoomInitialPiece_C /Game/Maps/..."
local function baseKey(base)
    local ok, name = pcall(function() return base:GetFullName() end)
    return ok and name or tostring(base)
end

-- Returns the materialPath currently painted on the given cell of a base, or nil if unpainted
local function findCellMaterial(baseData, cellCoords)
    if not baseData then return nil end
    for i = 1, #baseData.cells do
        local c = baseData.cells[i]
        if c.cellCoords.X == cellCoords.X and c.cellCoords.Y == cellCoords.Y and c.cellCoords.Z == cellCoords.Z then
            return c.materialPath
        end
    end
    return nil
end

-- Remove a cell entry from baseData.cells (if present)
local function removeCell(baseData, cellCoords)
    for i = #baseData.cells, 1, -1 do
        local c = baseData.cells[i]
        if c.cellCoords.X == cellCoords.X and c.cellCoords.Y == cellCoords.Y and c.cellCoords.Z == cellCoords.Z then
            table.remove(baseData.cells, i)
            return
        end
    end
end

-- Rebuild MaterialOverrides on a base from current paintedCells state
function painter.rebuild(base)
    local arr = base.MaterialOverrides.Overrides

    -- Clear existing overrides
    if #arr > 0 then
        pcall(function() arr:Empty() end)
    end

    local key = baseKey(base)
    local baseData = paintedCells[key]

    -- Debug: log what we're rebuilding
    local totalCells = 0
    for k, v in pairs(paintedCells) do
        totalCells = totalCells + #v.cells
    end
    print(string.format("[PaintBrush] rebuild: key=%s, cells for this base=%d, total tracked=%d\n",
        key:sub(1, 60), baseData and #baseData.cells or 0, totalCells))

    if not baseData or #baseData.cells == 0 then
        -- Nothing painted — just flush
        pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
        return
    end

    -- Group cells by materialPath
    local groups = {}   -- { materialPath = { cells list } }
    local order = {}    -- preserve insertion order for determinism
    for i = 1, #baseData.cells do
        local c = baseData.cells[i]
        if not groups[c.materialPath] then
            groups[c.materialPath] = {}
            table.insert(order, c.materialPath)
        end
        table.insert(groups[c.materialPath], c.cellCoords)
    end

    -- Create one override entry per unique material
    for idx, matPath in ipairs(order) do
        local matObj = StaticFindObject(matPath)
        if not matObj or not matObj:IsValid() then
            print(string.format("[PaintBrush] painter.rebuild: material not found: %s\n", matPath))
        else
            local cells = groups[matPath]
            pcall(function() arr[idx] = {} end)
            local entry = arr[idx]
            pcall(function() entry.Hide = false end)
            pcall(function() entry.Material = matObj end)

            -- Set first cell via table-of-tables, remaining via :Add()
            local first = cells[1]
            pcall(function() entry.Cells = {{X = first.X, Y = first.Y, Z = first.Z}} end)
            for ci = 2, #cells do
                local coord = cells[ci]
                pcall(function() entry.Cells:Add({X = coord.X, Y = coord.Y, Z = coord.Z}) end)
            end
        end
    end

    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
end

-- Apply a material to a single cell on a base
function painter.apply(base, cellCoords, materialPath)
    local key = baseKey(base)

    -- Record previous state for undo
    local prevMat = nil
    if paintedCells[key] then
        prevMat = findCellMaterial(paintedCells[key], cellCoords)
    end
    table.insert(undoStack, {
        baseKey          = key,
        base             = base,
        cellCoords       = {X = cellCoords.X, Y = cellCoords.Y, Z = cellCoords.Z},
        previousMaterial = prevMat,
    })

    -- Upsert painted cell
    if not paintedCells[key] then
        paintedCells[key] = {base = base, cells = {}}
    end
    local baseData = paintedCells[key]

    -- Remove old entry for this cell (if any), then insert new one
    removeCell(baseData, cellCoords)
    table.insert(baseData.cells, {
        cellCoords   = {X = cellCoords.X, Y = cellCoords.Y, Z = cellCoords.Z},
        materialPath = materialPath,
    })

    painter.rebuild(base)
end

-- Undo the last paint action; returns true if something was undone, false otherwise
function painter.undo()
    if #undoStack == 0 then
        return false
    end

    local action = table.remove(undoStack, #undoStack)
    local key    = action.baseKey
    local base   = action.base

    if not paintedCells[key] then
        paintedCells[key] = {base = base, cells = {}}
    end
    local baseData = paintedCells[key]

    -- Remove the cell that was painted by this action
    removeCell(baseData, action.cellCoords)

    -- If there was a previous material, restore it
    if action.previousMaterial then
        table.insert(baseData.cells, {
            cellCoords   = {X = action.cellCoords.X, Y = action.cellCoords.Y, Z = action.cellCoords.Z},
            materialPath = action.previousMaterial,
        })
    end

    -- Clean up empty base entries
    if #baseData.cells == 0 then
        paintedCells[key] = nil
    end

    -- Guard against stale base references (e.g. after save reload)
    if base:IsValid() then
        painter.rebuild(base)
    end
    return true
end

-- Return the full paintedCells table for serialization by state.lua
function painter.getPaintedCells()
    return paintedCells
end

-- Load paintedCells from deserialized data (state.lua calls this on load)
-- data must match the internal format
function painter.setPaintedCells(data)
    paintedCells = data or {}
end

-- Clear undo history (e.g. after loading a save)
function painter.clearHistory()
    undoStack = {}
end

return painter
