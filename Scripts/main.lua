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

local function reloadMaterials()
    materials.enumerate(true)
    print(string.format("[PaintBrush] %d materials loaded\n", #materials.getAll()))
end

-- Ensure state is loaded before any paint/erase operation.
-- Handles both initial game load AND mod restart (where RegisterLoadMapPostHook doesn't fire).
local function refreshModSettings()
    pcall(function()
        if not ModRef then return end
        local ok, val = pcall(function()
            return ModRef:GetSharedVariable("SN2ModSettings/PaintBrush/max_undo")
        end)
        if ok and val ~= nil and type(val) == "number" then
            config.MaxUndoStack = math.floor(val + 0.5)
        end
    end)
end

local function ensureStateLoaded()
    if _stateLoaded then return end
    reloadMaterials()
    refreshModSettings()
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
    pcall(ui.invalidateCache)  -- new world = new widget tree needed (pcall: may fire during teardown)
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            painter.setPaintedCells({})
            painter.clearHistory()
            reloadMaterials()
            if isHost() then
                state.load()
                sync.setHostReady()
                print("[PaintBrush] State loaded for current save (host)\n")
            else
                print("[PaintBrush] Waiting for state from host (client)\n")
            end
            _stateLoaded = true
            -- Request state from host. Retry at 8s and 16s only if no state received yet.
            local function requestIfEmpty()
                local cells = painter.getPaintedCells()
                local hasAny = false
                for _ in pairs(cells) do hasAny = true; break end
                if not hasAny then
                    sync.requestState()
                end
            end
            requestIfEmpty()
            ExecuteWithDelay(8000, function()
                ExecuteInGameThread(requestIfEmpty)
            end)
            ExecuteWithDelay(16000, function()
                ExecuteInGameThread(requestIfEmpty)
            end)  -- clients: get state from host; host: self-request (ignored)
        end)
    end)
end)

-- Last material selected via UI
local lastSelectedPath = nil
local lastSelectedName = nil

local function getSelectedMaterial()
    return lastSelectedPath, lastSelectedName
end

local function getBrushRadius()
    return ui.getBrushRadius()
end

-- B = open material picker UI
local pendingTarget = nil  -- stores detection info while UI is open

RegisterKeyBind(Key[config.PickerKey], function()
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

-- ============================================================
-- SN2ModSettings integration (optional — no dependency)
-- ============================================================
pcall(function()
    local enabledFile = io.open(config.ModDir .. "../SN2ModSettings/enabled.txt", "r")
    if not enabledFile then return end
    enabledFile:close()

    local regDir = config.ModDir .. "../SN2ModSettings/registrations/"
    os.execute('mkdir "' .. regDir:gsub("/", "\\") .. '" 2>nul')

    local manifest = [[return {
    name     = "PaintBrush",
    display  = "PaintBrush",
    version  = "]] .. config.VERSION .. [[",
    github   = "ryanhartwig/PaintBrush",
    settings = {
        { key="max_undo", title="Max Undo Steps",
          description="Number of paint actions kept in undo history.",
          type="slider", default=50, min=10, max=200, step=10, format="integer" },
    },
}]]

    local f = io.open(regDir .. "PaintBrush.lua", "w")
    if f then
        f:write(manifest)
        f:close()
        print("[PaintBrush] SN2ModSettings manifest written\n")
    end
end)

print(string.format("[PaintBrush] v%s loaded. B=picker, E=paint, Z=undo\n", config.VERSION))
