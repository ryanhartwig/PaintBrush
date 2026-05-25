local painter = {}

-- paintedCells: { [baseKeyString] = { base = UObject, cells = { ["X,Y,Z"] = materialPath, ... } } }
local paintedCells = {}

-- undoStack: array of { baseKey, base, batch = { {cellKey, previousMaterial}, ... } }
local undoStack = {}

-- Incremental override tracking: maps material paths to their override array indices
-- Populated by rebuild(), updated by incrementalApply/Erase, cleared on setPaintedCells()
local _matToIndex = {}   -- { [baseKeyString] = { [matPath] = arrayIndex } }

-- Centralized rebuild scheduling (replaces scattered debounce in main/sync)
local _rebuildScheduled = false
local _rebuildDeferredScheduled = false

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
painter.parseCellKey = parseCellKey

--------------------------------------------------------------------------------
-- Incremental operations (direct TArray/TSet mutation)
--------------------------------------------------------------------------------

-- Incremental paint: directly mutate the override array instead of full rebuild.
-- Falls back to full rebuild on any error.
local function incrementalApply(base, cellCoordsList, matPath, oldMaterials)
    local key = baseKey(base)
    if not _matToIndex[key] then _matToIndex[key] = {} end

    local arr
    local ok = pcall(function() arr = base.MaterialOverrides.Overrides end)
    if not ok or not arr then
        painter.rebuild(base)
        return
    end

    -- Remove cells from their old material entries (handles repaint case)
    for _, c in ipairs(cellCoordsList) do
        local ck = cellKey(c)
        local oldMat = oldMaterials[ck]
        if oldMat and oldMat ~= matPath then
            local oldIdx = _matToIndex[key][oldMat]
            if oldIdx then
                pcall(function() arr[oldIdx].Cells:Remove({X=c.X, Y=c.Y, Z=c.Z}) end)
            end
        end
    end

    -- Add cells to the target material entry
    local idx = _matToIndex[key][matPath]
    if idx then
        local ok2 = pcall(function()
            local entry = arr[idx]
            for _, c in ipairs(cellCoordsList) do
                entry.Cells:Add({X=c.X, Y=c.Y, Z=c.Z})
            end
        end)
        if not ok2 then
            painter.rebuild(base)
            return
        end
    else
        -- New material: grow the array
        local matObj = StaticFindObject(matPath)
        if not matObj or not matObj:IsValid() then return end

        local newIdx = #arr + 1
        local ok2 = pcall(function()
            arr[newIdx] = {}
            local entry = arr[newIdx]
            entry.Hide = false
            entry.Material = matObj
            entry.Cells = {{X=cellCoordsList[1].X, Y=cellCoordsList[1].Y, Z=cellCoordsList[1].Z}}
            for ci = 2, #cellCoordsList do
                entry.Cells:Add({X=cellCoordsList[ci].X, Y=cellCoordsList[ci].Y, Z=cellCoordsList[ci].Z})
            end
        end)
        if not ok2 then
            painter.rebuild(base)
            return
        end
        _matToIndex[key][matPath] = newIdx
    end

    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
end

-- Incremental erase: remove cells from their material's override entry.
-- Falls back to full rebuild on any error.
local function incrementalErase(base, cellCoordsList, oldMaterials)
    local key = baseKey(base)
    if not _matToIndex[key] then
        painter.rebuild(base)
        return
    end

    local arr
    local ok = pcall(function() arr = base.MaterialOverrides.Overrides end)
    if not ok or not arr then
        painter.rebuild(base)
        return
    end

    local ok2 = pcall(function()
        for _, c in ipairs(cellCoordsList) do
            local ck = cellKey(c)
            local oldMat = oldMaterials[ck]
            if oldMat then
                local oldIdx = _matToIndex[key][oldMat]
                if oldIdx then
                    arr[oldIdx].Cells:Remove({X=c.X, Y=c.Y, Z=c.Z})
                end
            end
        end
    end)
    if not ok2 then
        painter.rebuild(base)
        return
    end

    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
end

--------------------------------------------------------------------------------
-- Full rebuild (from hashmap — used for state load, compaction, fallback)
--------------------------------------------------------------------------------

function painter.rebuild(base)
    local t0 = os.clock()
    local key = baseKey(base)
    _matToIndex[key] = {}  -- always reset on full rebuild

    local arr
    local okAccess = pcall(function() arr = base.MaterialOverrides.Overrides end)
    if not okAccess or not arr then return end
    local tAccess = os.clock()

    if #arr > 0 then
        pcall(function() arr:Empty() end)
    end
    local tEmpty = os.clock()

    local baseData = paintedCells[key]

    local cellCount = 0
    if baseData then
        for _ in pairs(baseData.cells) do cellCount = cellCount + 1 end
    end

    if not baseData or cellCount == 0 then
        pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
        print(string.format("[PaintBrush] rebuild: 0 cells, cleared (%.1fms)\n", (os.clock() - t0) * 1000))
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

    -- Create override entries (skip missing materials, no index gaps)
    local totalCellsWritten = 0
    local matsMissing = 0
    local writeIdx = 0
    for _, matPath in ipairs(order) do
        local matObj = StaticFindObject(matPath)
        if not matObj or not matObj:IsValid() then
            matsMissing = matsMissing + 1
        else
            writeIdx = writeIdx + 1
            local cells = groups[matPath]
            pcall(function()
                arr[writeIdx] = {}
                local entry = arr[writeIdx]
                entry.Hide = false
                entry.Material = matObj
                entry.Cells = {{X = cells[1].X, Y = cells[1].Y, Z = cells[1].Z}}
                for ci = 2, #cells do
                    entry.Cells:Add({X = cells[ci].X, Y = cells[ci].Y, Z = cells[ci].Z})
                end
            end)
            _matToIndex[key][matPath] = writeIdx
            totalCellsWritten = totalCellsWritten + #cells
        end
    end
    local tWrite = os.clock()

    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
    local tUpdate = os.clock()

    print(string.format(
        "[PaintBrush] rebuild: %d cells, %d mats (%d missing) | "
        .. "access=%.1fms empty=%.1fms group=%.1fms write=%.1fms update=%.1fms TOTAL=%.1fms\n",
        cellCount, #order, matsMissing,
        (tAccess - t0) * 1000,
        (tEmpty - tAccess) * 1000,
        (tGroup - tEmpty) * 1000,
        (tWrite - tGroup) * 1000,
        (tUpdate - tWrite) * 1000,
        (tUpdate - t0) * 1000))
end

--------------------------------------------------------------------------------
-- Public API: applyBatch / eraseBatch
--------------------------------------------------------------------------------

function painter.applyBatch(base, cellCoordsList, materialPath, skipUndo, skipRebuild)
    local tBatch0 = os.clock()
    local key = baseKey(base)

    if not paintedCells[key] then
        paintedCells[key] = {base = base, cells = {}}
    end
    local baseData = paintedCells[key]

    -- Capture old materials BEFORE hashmap update (needed for undo + incremental)
    local oldMaterials = {}
    for _, coords in ipairs(cellCoordsList) do
        local ck = cellKey(coords)
        oldMaterials[ck] = baseData.cells[ck]
    end

    -- Record undo only for LOCAL actions
    if not skipUndo then
        local prevStates = {}
        for _, coords in ipairs(cellCoordsList) do
            local ck = cellKey(coords)
            table.insert(prevStates, {
                cellKey          = ck,
                previousMaterial = oldMaterials[ck],
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

    -- Update hashmap (source of truth for persistence)
    for _, coords in ipairs(cellCoordsList) do
        baseData.cells[cellKey(coords)] = materialPath
    end

    if not skipRebuild then
        incrementalApply(base, cellCoordsList, materialPath, oldMaterials)
    end

    print(string.format("[PaintBrush] applyBatch: %d cells | TOTAL=%.1fms%s\n",
        #cellCoordsList,
        (os.clock() - tBatch0) * 1000,
        skipRebuild and " (deferred)" or " (incremental)"))
end

function painter.eraseBatch(base, cellCoordsList, skipUndo, skipRebuild)
    local key = baseKey(base)

    if not paintedCells[key] then return end
    local baseData = paintedCells[key]

    -- Capture old materials BEFORE clearing (needed for undo + incremental)
    local oldMaterials = {}
    local anyPainted = false
    for _, coords in ipairs(cellCoordsList) do
        local ck = cellKey(coords)
        local prevMat = baseData.cells[ck]
        oldMaterials[ck] = prevMat
        if prevMat then anyPainted = true end
    end

    if not anyPainted then return end

    if not skipUndo then
        local prevStates = {}
        for _, coords in ipairs(cellCoordsList) do
            local ck = cellKey(coords)
            table.insert(prevStates, {
                cellKey          = ck,
                previousMaterial = oldMaterials[ck],
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

    -- Clear from hashmap
    for _, coords in ipairs(cellCoordsList) do
        baseData.cells[cellKey(coords)] = nil
    end

    -- Clean up empty base
    local hasAny = false
    for _ in pairs(baseData.cells) do hasAny = true; break end
    if not hasAny then
        paintedCells[key] = nil
        _matToIndex[key] = nil
    end

    if not skipRebuild then
        incrementalErase(base, cellCoordsList, oldMaterials)
    end
end

--------------------------------------------------------------------------------
-- Undo
--------------------------------------------------------------------------------

function painter.popUndo()
    if #undoStack == 0 then return nil end
    return table.remove(undoStack, #undoStack)
end

function painter.peekUndo()
    if #undoStack == 0 then return nil end
    return undoStack[#undoStack]
end

function painter.undo(skipRebuild)
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

    -- Capture current materials BEFORE restoring (needed for incremental)
    local currentMaterials = {}
    for _, prev in ipairs(action.batch or {}) do
        currentMaterials[prev.cellKey] = baseData.cells[prev.cellKey]
    end

    -- Restore hashmap to previous state
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
        _matToIndex[key] = nil
    end

    -- Apply visuals incrementally (no Empty, no full rebuild)
    if not skipRebuild and base:IsValid() then
        local didIncremental = false
        if _matToIndex[key] then
            local arr
            local ok = pcall(function() arr = base.MaterialOverrides.Overrides end)
            if ok and arr then
                local ok2 = pcall(function()
                    for _, prev in ipairs(action.batch or {}) do
                        local coords = parseCellKey(prev.cellKey)
                        -- Remove from current material entry
                        local curMat = currentMaterials[prev.cellKey]
                        if curMat then
                            local curIdx = _matToIndex[key][curMat]
                            if curIdx then
                                arr[curIdx].Cells:Remove({X=coords.X, Y=coords.Y, Z=coords.Z})
                            end
                        end
                        -- Add to previous material entry (if restoring, not erasing)
                        if prev.previousMaterial then
                            local prevIdx = _matToIndex[key][prev.previousMaterial]
                            if prevIdx then
                                arr[prevIdx].Cells:Add({X=coords.X, Y=coords.Y, Z=coords.Z})
                            else
                                -- Previous material has no entry yet — need to grow array
                                local matObj = StaticFindObject(prev.previousMaterial)
                                if matObj and matObj:IsValid() then
                                    local newIdx = #arr + 1
                                    arr[newIdx] = {}
                                    local entry = arr[newIdx]
                                    entry.Hide = false
                                    entry.Material = matObj
                                    entry.Cells = {{X=coords.X, Y=coords.Y, Z=coords.Z}}
                                    _matToIndex[key][prev.previousMaterial] = newIdx
                                end
                            end
                        end
                    end
                end)
                if ok2 then
                    pcall(function() base:ForceFullBaseUpdate(false, false, true) end)
                    didIncremental = true
                end
            end
        end
        if not didIncremental then
            painter.rebuild(base)
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Rebuild scheduling
--------------------------------------------------------------------------------

-- Debounced rebuild: coalesces rapid calls into one rebuild 200ms later.
-- All remote paint/erase/undo paths should call this instead of inline debounce.
function painter.scheduleRebuild()
    if _rebuildScheduled then return end
    _rebuildScheduled = true
    ExecuteWithDelay(200, function()
        ExecuteInGameThread(function()
            _rebuildScheduled = false
            for _, baseData in pairs(paintedCells) do
                if baseData.base and baseData.base:IsValid() then
                    pcall(painter.rebuild, baseData.base)
                end
            end
        end)
    end)
end

-- Deferred rebuild: fires 8s later for late-streaming materials.
-- Called once on state load / join sync.
function painter.scheduleDeferredRebuild()
    if _rebuildDeferredScheduled then return end
    _rebuildDeferredScheduled = true
    ExecuteWithDelay(8000, function()
        ExecuteInGameThread(function()
            _rebuildDeferredScheduled = false
            for _, baseData in pairs(paintedCells) do
                if baseData.base and baseData.base:IsValid() then
                    pcall(painter.rebuild, baseData.base)
                end
            end
            print("[PaintBrush] deferred rebuild for late-streaming materials\n")
        end)
    end)
end

-- Cancel all pending rebuilds (called on map load before state reset)
function painter.cancelScheduledRebuilds()
    _rebuildScheduled = false
    _rebuildDeferredScheduled = false
end

--------------------------------------------------------------------------------
-- State accessors
--------------------------------------------------------------------------------

function painter.getPaintedCells()
    return paintedCells
end

function painter.setPaintedCells(data)
    paintedCells = data or {}
    _matToIndex = {}
    _rebuildScheduled = false
    _rebuildDeferredScheduled = false
end

function painter.clearHistory()
    undoStack = {}
end

return painter
