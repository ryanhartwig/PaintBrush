local config    = require("config")
local detection = require("detection")
local painter   = require("painter")
local state     = require("state")
local materials = require("materials")
local textures  = require("textures")
local ui        = require("ui")
local sync      = require("sync")

local _stateLoaded = false

local parseCellKey = painter.parseCellKey

-- Cached host detection (reset on map load)
local _isHostCached = nil

local function isHost()
    if _isHostCached ~= nil then return _isHostCached end
    local save = FindFirstOf("UWESaveGame")
    _isHostCached = (save ~= nil and save:IsValid())
    return _isHostCached
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
    if not _worldReady and _stateLoaded then return end  -- transitioning, don't re-init
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

-- Debounce state (must be before RegisterLoadMapPostHook)
local _saveTimer = nil
local _saveGeneration = 0
local _worldReady = false  -- false during map load transition, prevents undo on stale refs

-- Auto-load paint state when a map loads (handles initial load + save reload)
local _lastLoadedSlot = nil

RegisterLoadMapPostHook(function(engine, world)
    _worldReady = false  -- block undo/paint during transition
    -- Flush any pending save NOW before state gets wiped
    if _saveTimer and _isHostCached then
        pcall(state.save)
    end
    _isHostCached = nil
    _saveTimer = nil
    _saveGeneration = _saveGeneration + 1  -- invalidate any pending debounced save
    sync.invalidateCache()
    pcall(ui.invalidateCache)

    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            -- Check if this is actually a new world or just a client joining our session
            local currentSlot = nil
            pcall(function()
                local save = FindFirstOf("UWESaveGame")
                if save and save:IsValid() then
                    currentSlot = save:GetSlotName():ToString()
                end
            end)

            if _stateLoaded and currentSlot == _lastLoadedSlot and currentSlot ~= nil then
                -- Same world, just a client join/rejoin — don't reset host state
                print("[PaintBrush] Map load hook (same world, skipping reset)\n")
                return
            end

            _lastLoadedSlot = currentSlot
            _stateLoaded = false
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
            _worldReady = true
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

-- Debounced save: batches rapid paints, writes once after 2 seconds of inactivity
local function debouncedSave()
    if not config.AutoSave or not isHost() then return end
    if _saveTimer then return end
    _saveTimer = true
    local gen = _saveGeneration
    ExecuteWithDelay(2000, function()
        ExecuteInGameThread(function()
            _saveTimer = nil
            if gen ~= _saveGeneration then return end
            state.save()
        end)
    end)
end

-- Share debounced save with sync.lua (remote paints use same debounce)
sync.setSaveCallback(debouncedSave)

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
                debouncedSave()
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

        local tChain = os.clock()

        if ui.isEraserMode() then
            painter.eraseBatch(info.base, cells)
            local tPaint = os.clock()
            sync.sendErase(info.base, cells)
            local tSync = os.clock()
            debouncedSave()
            local tSave = os.clock()
            print(string.format("[PaintBrush] CHAIN perf: erase | paint=%.1fms sync=%.1fms save=%.1fms TOTAL=%.1fms\n",
                (tPaint - tChain)*1000, (tSync - tPaint)*1000, (tSave - tSync)*1000, (tSave - tChain)*1000))
        else
            local matPath, matName = getSelectedMaterial()
            if not matPath then
                print("[PaintBrush] No material selected\n")
                return
            end
            painter.applyBatch(info.base, cells, matPath)
            local tPaint = os.clock()
            sync.sendPaint(info.base, cells, matPath)
            local tSync = os.clock()
            debouncedSave()
            local tSave = os.clock()
            print(string.format("[PaintBrush] CHAIN perf: paint %s | paint=%.1fms sync=%.1fms save=%.1fms TOTAL=%.1fms\n",
                matName, (tPaint - tChain)*1000, (tSync - tPaint)*1000, (tSave - tSync)*1000, (tSave - tChain)*1000))
        end
    end)
end)

-- Debounced undo rebuild: accumulate rapid undos, rebuild once
local _undoRebuildTimer = nil
local _undoRebuildBase = nil

local function scheduleUndoRebuild(base)
    _undoRebuildBase = base
    if _undoRebuildTimer then return end  -- already scheduled
    _undoRebuildTimer = true
    ExecuteWithDelay(200, function()
        ExecuteInGameThread(function()
            _undoRebuildTimer = nil
            if _undoRebuildBase and _undoRebuildBase:IsValid() then
                painter.rebuild(_undoRebuildBase)
            end
            _undoRebuildBase = nil
        end)
    end)
end

-- Z = undo (local apply + relay reverse operations to other players)
RegisterKeyBind(Key[config.UndoKey], function()
    ExecuteInGameThread(function()
        ensureStateLoaded()
        local entry = painter.peekUndo()
        if not entry then
            print("[PaintBrush] Nothing to undo\n")
            return
        end

        -- Extract reverse operations BEFORE undoing
        local base = entry.base
        local eraseCells = {}
        local paintGroups = {}
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

        -- Apply undo locally (skipRebuild — debounce handles it)
        -- painter.undo calls rebuild internally, but we need skipRebuild
        -- So pop + apply manually:
        painter.popUndo()
        local key = nil
        pcall(function() key = base:GetFullName() end)
        if key then
            local baseData = painter.getPaintedCells()[key]
            if baseData then
                for _, prev in ipairs(entry.batch or {}) do
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
                    painter.getPaintedCells()[key] = nil
                end
            end
        end

        -- Debounced rebuild (200ms) — rapid undos get ONE rebuild
        if base and base:IsValid() then
            scheduleUndoRebuild(base)
        end

        -- Send reverse operations to other players
        if base and base:IsValid() then
            if #eraseCells > 0 then
                sync.sendErase(base, eraseCells)
            end
            for matPath, cells in pairs(paintGroups) do
                sync.sendPaint(base, cells, matPath)
            end
        end

        debouncedSave()
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
