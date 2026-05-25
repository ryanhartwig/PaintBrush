local config    = require("config")
local detection = require("detection")
local painter   = require("painter")
local state     = require("state")
local materials = require("materials")
local textures  = require("textures")
local ui        = require("ui")
local sync      = require("sync")

local _stateLoaded = false

local function parseCellKey(key)
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return {X = tonumber(x), Y = tonumber(y), Z = tonumber(z)}
end

-- Detect if we're the host (have a save game) or a client (no save game)
local function isHost()
    local save = FindFirstOf("UWESaveGame")
    return save and save:IsValid()
end

-- Material cycling — rebuilt after map load when materials are available
local browseMats = {}
local selectedIdx = 1

local function rebuildBrowseList()
    materials.enumerate(true)  -- force re-scan
    local allMats = materials.getAll()
    browseMats = {}
    for _, m in ipairs(allMats) do
        if m.category ~= "zzz_Skip" then
            table.insert(browseMats, m)
        end
    end
    selectedIdx = 1
    print(string.format("[PaintBrush] %d browseable materials (filtered from %d)\n", #browseMats, #allMats))
end

-- Ensure state is loaded before any paint/erase operation.
-- Handles both initial game load AND mod restart (where RegisterLoadMapPostHook doesn't fire).
local function ensureStateLoaded()
    if _stateLoaded then return end
    rebuildBrowseList()
    if isHost() then
        state.load()
        sync.setHostReady()
        print("[PaintBrush] State lazy-loaded (host)\n")
    else
        print("[PaintBrush] State lazy-loaded (client, skipping local file)\n")
    end
    _stateLoaded = true
end

-- Auto-load paint state when a map loads (handles initial load + save reload)
RegisterLoadMapPostHook(function(engine, world)
    _stateLoaded = false
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            painter.setPaintedCells({})
            painter.clearHistory()
            rebuildBrowseList()
            if isHost() then
                state.load()
                sync.setHostReady()
                print("[PaintBrush] State loaded for current save (host)\n")
            else
                print("[PaintBrush] Waiting for state from host (client)\n")
            end
            _stateLoaded = true
            sync.requestState()  -- clients: get state from host; host: self-request (ignored)
        end)
    end)
end)

-- Last material selected via UI (takes priority over L/K cycling)
local lastSelectedPath = nil
local lastSelectedName = nil

local function getSelectedMaterial()
    if lastSelectedPath then return lastSelectedPath, lastSelectedName end
    if #browseMats == 0 then return nil, nil end
    local m = browseMats[selectedIdx]
    return m.path, m.name
end

local function getBrushRadius()
    return ui.getBrushRadius()
end

local function printSelected()
    local m = browseMats[selectedIdx]
    print(string.format("[PaintBrush] [%d/%d] [%s] %s | Brush: %s\n",
        selectedIdx, #browseMats, m.category, m.name, BRUSH_LABELS[brushIdx]))
end

-- L = next material, K = previous material
RegisterKeyBind(Key.L, function()
    ExecuteInGameThread(function()
        selectedIdx = selectedIdx + 1
        if selectedIdx > #browseMats then selectedIdx = 1 end
        printSelected()
    end)
end)

RegisterKeyBind(Key.K, function()
    ExecuteInGameThread(function()
        selectedIdx = selectedIdx - 1
        if selectedIdx < 1 then selectedIdx = #browseMats end
        printSelected()
    end)
end)

-- O = open material picker UI
local pendingTarget = nil  -- stores detection info while UI is open

RegisterKeyBind(Key.B, function()
    ExecuteInGameThread(function()
        if ui.isOpen() then
            ui.close()
            return
        end

        ensureStateLoaded()
        local info = detection.getTargetInfo()
        if not info then
            print("[PaintBrush] Not aiming at a base surface\n")
            return
        end

        pendingTarget = info
        textures.load()
        local curPath = lastSelectedPath
        ui.setSelectedMaterial(curPath)
        print(string.format("[PaintBrush] Opening UI with selected: %s\n", tostring(curPath)))

        -- onApply: paint without closing UI (preview different materials)
        local function onApply(matPath, matName)
            lastSelectedPath = matPath
            lastSelectedName = matName
            if pendingTarget and pendingTarget.base:IsValid() then
                local r = getBrushRadius()
                local cc = pendingTarget.cellCoords
                local cells = {}
                for dx = -r, r do
                    for dy = -r, r do
                        for dz = -r, r do
                            table.insert(cells, {X=cc.X+dx, Y=cc.Y+dy, Z=cc.Z+dz})
                        end
                    end
                end
                painter.applyBatch(pendingTarget.base, cells, matPath)
                sync.sendPaint(pendingTarget.base, cells, matPath)
                if config.AutoSave and isHost() then state.save() end
                print(string.format("[PaintBrush] Applied %s (UI stays open)\n", matName))
            end
        end

        -- onSelect: just pick material for future P presses, don't paint
        local function onSelect(matPath, matName)
            lastSelectedPath = matPath
            lastSelectedName = matName
            ui.setSelectedMaterial(matPath)
            print(string.format("[PaintBrush] Selected: %s\n", matName))
            pendingTarget = nil
        end

        ui.open(onApply, onSelect)
    end)
end)

-- P = paint or erase with selected material
RegisterKeyBind(Key[config.PaintKey], function()
    ExecuteInGameThread(function()
        ensureStateLoaded()
        local info = detection.getTargetInfo()
        if not info then
            print("[PaintBrush] Not aiming at a base surface\n")
            return
        end

        local r = getBrushRadius()
        local cc = info.cellCoords
        local cells = {}
        for dx = -r, r do
            for dy = -r, r do
                for dz = -r, r do
                    table.insert(cells, {X=cc.X+dx, Y=cc.Y+dy, Z=cc.Z+dz})
                end
            end
        end

        local size = (r * 2 + 1)

        if ui.isEraserMode() then
            painter.eraseBatch(info.base, cells)                -- local: instant + undo
            sync.sendErase(info.base, cells)                    -- network: sync to others
            print(string.format("[PaintBrush] Erased %dx%dx%d at (%d,%d,%d)\n",
                size, size, size, cc.X, cc.Y, cc.Z))
        else
            local matPath, matName = getSelectedMaterial()
            if not matPath then
                print("[PaintBrush] No material selected\n")
                return
            end
            painter.applyBatch(info.base, cells, matPath)       -- local: instant + undo
            sync.sendPaint(info.base, cells, matPath)            -- network: sync to others
            print(string.format("[PaintBrush] Painted %dx%dx%d at (%d,%d,%d) with %s\n",
                size, size, size, cc.X, cc.Y, cc.Z, matName))
        end
        if config.AutoSave and isHost() then
            state.save()
        end
    end)
end)

-- Z = undo (local apply + relay reverse operations to other players)
RegisterKeyBind(Key[config.UndoKey], function()
    ExecuteInGameThread(function()
        ensureStateLoaded()
        -- Peek at the undo entry to extract reverse operations BEFORE undoing
        local entry = painter.peekUndo()
        if not entry then
            print("[PaintBrush] Nothing to undo\n")
            return
        end

        -- Extract reverse operations from the undo entry
        local base = entry.base
        local eraseCells = {}
        local paintGroups = {}  -- { [matPath] = {coords} }
        for _, prev in ipairs(entry.batch or {}) do
            local coords = parseCellKey(prev.cellKey)
            if prev.previousMaterial then
                if not paintGroups[prev.previousMaterial] then
                    paintGroups[prev.previousMaterial] = {}
                end
                table.insert(paintGroups[prev.previousMaterial], coords)
            else
                table.insert(eraseCells, coords)
            end
        end

        -- Apply undo locally
        painter.undo()

        -- Send reverse operations to other players via relay
        if base and base:IsValid() then
            if #eraseCells > 0 then
                sync.sendErase(base, eraseCells)
            end
            for matPath, cells in pairs(paintGroups) do
                sync.sendPaint(base, cells, matPath)
            end
        end

        if config.AutoSave and isHost() then state.save() end
        print("[PaintBrush] Undo successful\n")
    end)
end)

print(string.format("[PaintBrush] v%s loaded. O=picker, P=paint, Z=undo, L/K=material, J/H=brush\n", config.VERSION))
print("[PaintBrush] Materials will load after world is ready\n")
