local painter = {}

-- paintedCells: { [baseKeyString] = { base = UObject, cells = { ["X,Y,Z"] = materialPath, ... } } }
local paintedCells = {}

-- undoStack: array of { baseKey, base, batch = { {cellKey, previousMaterial}, ... } }
local undoStack = {}

local function baseKey(base)
    local ok, name = pcall(function() return base:GetFullName() end)
    return ok and name or tostring(base)
end

local function cellKey(coords)
    return string.format("%d,%d,%d", coords.X, coords.Y, coords.Z)
end

local function parseCellKey(key)
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return {X = tonumber(x), Y = tonumber(y), Z = tonumber(z)}
end

-- Rebuild MaterialOverrides on a base from current paintedCells state
function painter.rebuild(base)
    local t0 = os.clock()

    local arr = base.MaterialOverrides.Overrides
    local tAccess = os.clock()

    if #arr > 0 then
        pcall(function() arr:Empty() end)
    end
    local tEmpty = os.clock()

    local key = baseKey(base)
    local baseData = paintedCells[key]

    local cellCount = 0
    if baseData then
        for _ in pairs(baseData.cells) do cellCount = cellCount + 1 end
    end

    if not baseData or cellCount == 0 then
        print(string.format("[PaintBrush] perf: 0 cells, abort (%.1fms)\n", (os.clock() - t0) * 1000))
        return
    end

    -- Group cells by materialPath
    local groups = {}
    local order = {}
    for ck, matPath in pairs(baseData.cells) do
        if type(ck) == "string" and type(matPath) == "string" then
            if not groups[matPath] then
                groups[matPath] = {}
                table.insert(order, matPath)
            end
            table.insert(groups[matPath], parseCellKey(ck))
        end
    end
    local tGroup = os.clock()

    -- Create override entries
    local totalCellsWritten = 0
    local matsMissing = 0
    for idx, matPath in ipairs(order) do
        local matObj = StaticFindObject(matPath)
        if not matObj or not matObj:IsValid() then
            matsMissing = matsMissing + 1
        else
            local cells = groups[matPath]
            pcall(function() arr[idx] = {} end)
            local entry = arr[idx]
            pcall(function() entry.Hide = false end)
            pcall(function() entry.Material = matObj end)

            local first = cells[1]
            pcall(function() entry.Cells = {{X = first.X, Y = first.Y, Z = first.Z}} end)
            for ci = 2, #cells do
                local coord = cells[ci]
                pcall(function() entry.Cells:Add({X = coord.X, Y = coord.Y, Z = coord.Z}) end)
            end
            totalCellsWritten = totalCellsWritten + #cells
        end
    end
    local tWrite = os.clock()

    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
    local tUpdate = os.clock()

    print(string.format(
        "[PaintBrush] perf: %d cells, %d mats (%d missing) | "
        .. "access=%.1fms empty=%.1fms group=%.1fms write=%.1fms update=%.1fms TOTAL=%.1fms\n",
        cellCount, #order, matsMissing,
        (tAccess - t0) * 1000,
        (tEmpty - tAccess) * 1000,
        (tGroup - tEmpty) * 1000,
        (tWrite - tGroup) * 1000,
        (tUpdate - tWrite) * 1000,
        (tUpdate - t0) * 1000))
end

function painter.apply(base, cellCoords, materialPath)
    painter.applyBatch(base, {cellCoords}, materialPath)
end

-- skipUndo: true when applying remote actions (don't pollute local undo stack)
function painter.applyBatch(base, cellCoordsList, materialPath, skipUndo)
    local tBatch0 = os.clock()
    local key = baseKey(base)

    if not paintedCells[key] then
        paintedCells[key] = {base = base, cells = {}}
    end
    local baseData = paintedCells[key]

    -- Record undo only for LOCAL actions
    if not skipUndo then
        local prevStates = {}
        for _, coords in ipairs(cellCoordsList) do
            local ck = cellKey(coords)
            table.insert(prevStates, {
                cellKey          = ck,
                previousMaterial = baseData.cells[ck],
            })
        end
        table.insert(undoStack, {
            baseKey = key,
            base    = base,
            batch   = prevStates,
        })
        if #undoStack > (require("config").MaxUndoStack or 50) then
            table.remove(undoStack, 1)
        end
    end

    -- Upsert all cells (O(1) per cell now!)
    local tUpsert = os.clock()
    for _, coords in ipairs(cellCoordsList) do
        baseData.cells[cellKey(coords)] = materialPath
    end
    local tUpsertDone = os.clock()

    painter.rebuild(base)
    print(string.format("[PaintBrush] applyBatch perf: %d cells | undo=%.1fms upsert=%.1fms TOTAL=%.1fms (rebuild above)\n",
        #cellCoordsList,
        (tUpsert - tBatch0) * 1000,
        (tUpsertDone - tUpsert) * 1000,
        (os.clock() - tBatch0) * 1000))
end

function painter.eraseBatch(base, cellCoordsList, skipUndo)
    local key = baseKey(base)

    if not paintedCells[key] then return end
    local baseData = paintedCells[key]

    local prevStates = {}
    local anyPainted = false
    for _, coords in ipairs(cellCoordsList) do
        local ck = cellKey(coords)
        local prevMat = baseData.cells[ck]
        table.insert(prevStates, {
            cellKey          = ck,
            previousMaterial = prevMat,
        })
        if prevMat then anyPainted = true end
    end

    if not anyPainted then return end

    if not skipUndo then
        table.insert(undoStack, {
            baseKey = key,
            base    = base,
            batch   = prevStates,
        })
        if #undoStack > (require("config").MaxUndoStack or 50) then
            table.remove(undoStack, 1)
        end
    end

    for _, coords in ipairs(cellCoordsList) do
        baseData.cells[cellKey(coords)] = nil
    end

    -- Clean up empty base
    local hasAny = false
    for _ in pairs(baseData.cells) do hasAny = true; break end
    if not hasAny then
        paintedCells[key] = nil
    end

    painter.rebuild(base)
end

function painter.popUndo()
    if #undoStack == 0 then return nil end
    return table.remove(undoStack, #undoStack)
end

function painter.peekUndo()
    if #undoStack == 0 then return nil end
    return undoStack[#undoStack]
end

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

    for _, prev in ipairs(action.batch or {}) do
        if prev.previousMaterial then
            baseData.cells[prev.cellKey] = prev.previousMaterial
        else
            baseData.cells[prev.cellKey] = nil
        end
    end

    -- Clean up empty
    local hasAny = false
    for _ in pairs(baseData.cells) do hasAny = true; break end
    if not hasAny then
        paintedCells[key] = nil
    end

    if base:IsValid() then
        painter.rebuild(base)
    end
    return true
end

function painter.getPaintedCells()
    return paintedCells
end

function painter.setPaintedCells(data)
    paintedCells = data or {}
end

function painter.clearHistory()
    undoStack = {}
end

return painter
