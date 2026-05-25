-- sync.lua — Multiplayer state synchronization for PaintBrush.
-- Host-authoritative: all paint actions route through the host.
-- Uses ServerExecRPC (client→host) and ClientMessage (host→clients).

local UEHelpers = require("UEHelpers")
local painter   = require("painter")
local state     = require("state")
local config    = require("config")

local sync = {}
local hostStateReady = false
local _deferredRebuildScheduled = false  -- set by main.lua after state.load() completes

function sync.setHostReady()
    hostStateReady = true
end

local PREFIX = "PB_"
local MSG_PAINT = "PB_PAINT|"
local MSG_ERASE = "PB_ERASE|"
local MSG_REQ   = "PB_REQ"
local MSG_STATE = "PB_STATE|"
local MSG_RELAY_PAINT = "PB_RP|"  -- relayed paint action (small, incremental)
local MSG_RELAY_ERASE = "PB_RE|"  -- relayed erase action (small, incremental)

-- Callback set by main.lua: called when remote state arrives so visuals can update
local onStateReceived = nil

function sync.setOnStateReceived(cb)
    onStateReceived = cb
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function guidString(base)
    local ok, guid = pcall(function() return base.BaseNetworkGUID end)
    if not ok or not guid then return nil end
    return string.format("%08X%08X%08X%08X", guid.A, guid.B, guid.C, guid.D)
end

-- Encode cell list: "X1,Y1,Z1;X2,Y2,Z2;..."
local function encodeCells(cellCoordsList)
    local parts = {}
    for _, c in ipairs(cellCoordsList) do
        table.insert(parts, string.format("%d,%d,%d", c.X, c.Y, c.Z))
    end
    return table.concat(parts, ";")
end

-- Decode cell list: "X1,Y1,Z1;X2,Y2,Z2;..." → {{X,Y,Z}, ...}
local function decodeCells(str)
    local cells = {}
    for part in str:gmatch("[^;]+") do
        local x, y, z = part:match("^(-?%d+),(-?%d+),(-?%d+)$")
        if x then
            table.insert(cells, {X=tonumber(x), Y=tonumber(y), Z=tonumber(z)})
        end
    end
    return cells
end

-- Find a base actor by its GUID string
local function findBaseByGuid(guidStr)
    local bases = FindAllOf("UWESculpturalBaseActor")
    if not bases then return nil end
    for _, base in ipairs(bases) do
        if base:IsValid() and guidString(base) == guidStr then
            return base
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Sending (any player → host)
--------------------------------------------------------------------------------

function sync.sendPaint(base, cellCoordsList, materialPath)
    local guid = guidString(base)
    if not guid then return end
    local msg = MSG_PAINT .. guid .. "|" .. encodeCells(cellCoordsList) .. "|" .. materialPath
    pcall(function()
        local pc = UEHelpers:GetPlayerController()
        if pc and pc:IsValid() then
            pc:ServerExecRPC(msg)
        end
    end)
end

function sync.sendErase(base, cellCoordsList)
    local guid = guidString(base)
    if not guid then return end
    local msg = MSG_ERASE .. guid .. "|" .. encodeCells(cellCoordsList)
    pcall(function()
        local pc = UEHelpers:GetPlayerController()
        if pc and pc:IsValid() then
            pc:ServerExecRPC(msg)
        end
    end)
end

-- Undo: pop from local stack, send reverse operations to host
function sync.sendUndo()
    local entry = painter.popUndo()
    if not entry then return false end
    if not entry.base or not entry.base:IsValid() then return false end

    -- Group cells by action: erase (previousMaterial=nil) or paint-with-previous
    local eraseCells = {}
    local paintGroups = {}  -- { [materialPath] = {cells} }

    for _, prev in ipairs(entry.batch or {}) do
        if prev.previousMaterial then
            if not paintGroups[prev.previousMaterial] then
                paintGroups[prev.previousMaterial] = {}
            end
            table.insert(paintGroups[prev.previousMaterial], prev.cellCoords)
        else
            table.insert(eraseCells, prev.cellCoords)
        end
    end

    -- Send erase for cells that were unpainted before
    if #eraseCells > 0 then
        sync.sendErase(entry.base, eraseCells)
    end

    -- Send paint-with-previous for cells that had a different material
    for matPath, cells in pairs(paintGroups) do
        sync.sendPaint(entry.base, cells, matPath)
    end

    return true
end

function sync.requestState()
    pcall(function()
        local pc = UEHelpers:GetPlayerController()
        if pc and pc:IsValid() then
            pc:ServerExecRPC(MSG_REQ)
        end
    end)
end

--------------------------------------------------------------------------------
-- Broadcasting (host → all clients)
--------------------------------------------------------------------------------

local function broadcastState()
    -- Serialize current state using state.lua's format
    local jsonStr = state.serializeCurrentState()
    if not jsonStr then return end
    local msg = MSG_STATE .. jsonStr

    -- Get local PC name to skip self (host already applied locally)
    local localPCName = nil
    pcall(function() localPCName = UEHelpers:GetPlayerController():GetFullName() end)

    local targets = FindAllOf("SN2PlayerController") or FindAllOf("PlayerController")
    if not targets then return end
    local sent = 0
    for _, pc in ipairs(targets) do
        pcall(function()
            if pc:IsValid()
               and not pc:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject) then
                local pcName = pc:GetFullName()
                if pcName ~= localPCName then
                    pc:ClientMessage(msg, FName("Event"), 10.0)
                    sent = sent + 1
                end
            end
        end)
    end
    if sent > 0 then
        print(string.format("[PaintBrush] sync: broadcast to %d client(s), msg size=%d\n", sent, #msg))
    end
end

-- Relay a small action message to all non-self clients (instead of full state)
local function relayToOthers(msg)
    local localPCName = nil
    pcall(function() localPCName = UEHelpers:GetPlayerController():GetFullName() end)

    local targets = FindAllOf("SN2PlayerController") or FindAllOf("PlayerController")
    if not targets then return end
    for _, pc in ipairs(targets) do
        pcall(function()
            if pc:IsValid()
               and not pc:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject) then
                local pcName = pc:GetFullName()
                if pcName ~= localPCName then
                    pc:ClientMessage(msg, FName("Event"), 10.0)
                end
            end
        end)
    end
end

local MAX_MSG_SIZE = 16000  -- safe limit for ClientMessage string

local function sendStateTo(senderPC)
    -- Read state directly from the JSON file (avoids stale UObject refs)
    local slotPath = state.getSlotPath()
    local f = io.open(slotPath, "r")
    if not f then
        print(string.format("[PaintBrush] sync: no state file at %s\n", slotPath))
        return
    end
    local content = f:read("*a")
    f:close()

    if not content or content == "" then
        print("[PaintBrush] sync: state file is empty\n")
        return
    end

    -- Parse JSON to extract bases and cells
    local parsed = nil
    pcall(function() parsed = state.decodeJson(content) end)
    if not parsed or type(parsed) ~= "table" or type(parsed.bases) ~= "table" then
        print("[PaintBrush] sync: failed to parse state file\n")
        return
    end

    local version = parsed.version or 1
    local totalSent = 0

    for guid, baseEntry in pairs(parsed.bases) do
        if type(baseEntry.cells) ~= "table" then goto nextBase end

        -- Group cells by material
        local byMat = {}
        if version >= 2 then
            -- v2: cells is map {"X,Y,Z" -> matPath}
            for cellKey, matPath in pairs(baseEntry.cells) do
                if type(cellKey) == "string" and type(matPath) == "string" then
                    if not byMat[matPath] then byMat[matPath] = {} end
                    local x, y, z = cellKey:match("^(-?%d+),(-?%d+),(-?%d+)$")
                    if x then
                        table.insert(byMat[matPath], {X=tonumber(x), Y=tonumber(y), Z=tonumber(z)})
                    end
                end
            end
        else
            -- v1: cells is array [{x,y,z,mat}]
            for _, c in ipairs(baseEntry.cells) do
                if type(c.mat) == "string" then
                    if not byMat[c.mat] then byMat[c.mat] = {} end
                    table.insert(byMat[c.mat], {X=c.x, Y=c.y, Z=c.z})
                end
            end
        end

        -- Send each material's cells in chunks of 50
        for matPath, cells in pairs(byMat) do
            local chunk = {}
            for _, coords in ipairs(cells) do
                table.insert(chunk, coords)
                if #chunk >= 50 then
                    local msg = MSG_RELAY_PAINT .. guid .. "|" .. encodeCells(chunk) .. "|" .. matPath
                    pcall(function()
                        senderPC:ClientMessage(msg, FName("Event"), 10.0)
                    end)
                    totalSent = totalSent + #chunk
                    chunk = {}
                end
            end
            if #chunk > 0 then
                local msg = MSG_RELAY_PAINT .. guid .. "|" .. encodeCells(chunk) .. "|" .. matPath
                pcall(function()
                    senderPC:ClientMessage(msg, FName("Event"), 10.0)
                end)
                totalSent = totalSent + #chunk
            end
        end

        ::nextBase::
    end

    print(string.format("[PaintBrush] sync: sent %d cells to joining client\n", totalSent))
end

--------------------------------------------------------------------------------
-- Receiving hooks
--------------------------------------------------------------------------------

-- HOST: handle incoming paint/erase/request messages from any player
RegisterHook("/Script/Engine.PlayerController:ServerExecRPC", function(ctx, msgParam)
    local ok, raw = pcall(function() return msgParam:get():ToString() end)
    if not ok or not raw or raw:sub(1, 3) ~= PREFIX then return end

    -- Check if sender is local player (already applied locally, skip duplicate)
    local isLocal = false
    pcall(function()
        local senderPC = ctx:get()
        local localPC = UEHelpers:GetPlayerController()
        if senderPC and localPC then
            isLocal = (senderPC:GetFullName() == localPC:GetFullName())
        end
    end)

    if raw:sub(1, #MSG_PAINT) == MSG_PAINT then
        local payload = raw:sub(#MSG_PAINT + 1)
        local guid, cellsStr, matPath = payload:match("^([^|]+)|([^|]+)|(.+)$")
        if guid and cellsStr and matPath then
            if not isLocal then
                local base = findBaseByGuid(guid)
                if base then
                    painter.applyBatch(base, decodeCells(cellsStr), matPath, true)
                end
            end
            state.save()
            -- Relay the small action to other clients (not full state)
            relayToOthers(MSG_RELAY_PAINT .. guid .. "|" .. cellsStr .. "|" .. matPath)
        end

    elseif raw:sub(1, #MSG_ERASE) == MSG_ERASE then
        local payload = raw:sub(#MSG_ERASE + 1)
        local guid, cellsStr = payload:match("^([^|]+)|(.+)$")
        if guid and cellsStr then
            if not isLocal then
                local base = findBaseByGuid(guid)
                if base then
                    painter.eraseBatch(base, decodeCells(cellsStr), true)
                end
            end
            state.save()
            relayToOthers(MSG_RELAY_ERASE .. guid .. "|" .. cellsStr)
        end

    elseif raw == MSG_REQ then
        -- Only the HOST should respond to PB_REQ.
        -- Skip if sender is local player (we're a client processing our own request).
        if isLocal then return end

        local senderPC = ctx:get()
        if senderPC and senderPC:IsValid() then
            if not hostStateReady then
                print("[PaintBrush] sync: PB_REQ received but host state not loaded yet, deferring\n")
                ExecuteWithDelay(5000, function()
                    ExecuteInGameThread(function()
                        if senderPC:IsValid() then
                            print("[PaintBrush] sync: deferred PB_REQ, sending state now\n")
                            sendStateTo(senderPC)
                        end
                    end)
                end)
            else
                print("[PaintBrush] sync: PB_REQ received, sending state\n")
                sendStateTo(senderPC)
            end
        end
    end
end)

-- CLIENT: receive messages from host
RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(_, sParam)
    local ok, raw = pcall(function() return sParam:get():ToString() end)
    if not ok or not raw then return end

    -- Full state (for PB_REQ response / join sync)
    if raw:sub(1, #MSG_STATE) == MSG_STATE then
        local jsonStr = raw:sub(#MSG_STATE + 1)
        state.applyFromJson(jsonStr)
        if onStateReceived then onStateReceived() end
        print("[PaintBrush] sync: received full state from host\n")
        return
    end

    -- Relayed paint action (incremental, small message)
    if raw:sub(1, #MSG_RELAY_PAINT) == MSG_RELAY_PAINT then
        local payload = raw:sub(#MSG_RELAY_PAINT + 1)
        local guid, cellsStr, matPath = payload:match("^([^|]+)|([^|]+)|(.+)$")
        if guid and cellsStr and matPath then
            local base = findBaseByGuid(guid)
            if base then
                painter.applyBatch(base, decodeCells(cellsStr), matPath, true)
                -- Schedule a deferred rebuild to catch late-streaming materials
                if not _deferredRebuildScheduled then
                    _deferredRebuildScheduled = true
                    ExecuteWithDelay(8000, function()
                        ExecuteInGameThread(function()
                            _deferredRebuildScheduled = false
                            -- Rebuild all bases that have painted cells
                            for _, baseData in pairs(painter.getPaintedCells()) do
                                if baseData.base and baseData.base:IsValid() then
                                    pcall(painter.rebuild, baseData.base)
                                end
                            end
                            print("[PaintBrush] sync: deferred rebuild for late-streaming materials\n")
                        end)
                    end)
                end
            end
        end
        return
    end

    -- Relayed erase action
    if raw:sub(1, #MSG_RELAY_ERASE) == MSG_RELAY_ERASE then
        local payload = raw:sub(#MSG_RELAY_ERASE + 1)
        local guid, cellsStr = payload:match("^([^|]+)|(.+)$")
        if guid and cellsStr then
            local base = findBaseByGuid(guid)
            if base then
                painter.eraseBatch(base, decodeCells(cellsStr), true)
                print("[PaintBrush] sync: relayed erase\n")
            end
        end
        return
    end
end)

-- Broadcast current state (called after local undo to override stale broadcasts)
function sync.broadcastCurrentState()
    broadcastState()
end

print("[PaintBrush] sync: multiplayer hooks registered\n")

return sync
