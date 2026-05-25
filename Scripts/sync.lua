-- sync.lua — Multiplayer state synchronization for PaintBrush.
-- Host-authoritative: all paint actions route through the host.
-- Uses ServerExecRPC (client→host) and ClientMessage (host→clients).

local UEHelpers = require("UEHelpers")
local painter   = require("painter")
local state     = require("state")
local config    = require("config")

local sync = {}

local PREFIX = "PB_"
local MSG_PAINT = "PB_PAINT|"
local MSG_ERASE = "PB_ERASE|"
local MSG_REQ   = "PB_REQ"
local MSG_STATE = "PB_STATE|"

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

    -- Get local PC to skip self (host already applied locally)
    local localPC = nil
    pcall(function() localPC = UEHelpers:GetPlayerController() end)

    local targets = FindAllOf("SN2PlayerController") or FindAllOf("PlayerController")
    if not targets then return end
    for _, pc in ipairs(targets) do
        pcall(function()
            if pc:IsValid()
               and not pc:HasAnyFlags(EObjectFlags.RF_ClassDefaultObject)
               and pc ~= localPC then
                pc:ClientMessage(msg, FName("Event"), 10.0)
            end
        end)
    end
end

local function sendStateTo(senderPC)
    local jsonStr = state.serializeCurrentState()
    if not jsonStr then return end
    pcall(function()
        senderPC:ClientMessage(MSG_STATE .. jsonStr, FName("Event"), 10.0)
    end)
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
                    painter.applyBatch(base, decodeCells(cellsStr), matPath)
                end
            end
            state.save()
            broadcastState()
        end

    elseif raw:sub(1, #MSG_ERASE) == MSG_ERASE then
        local payload = raw:sub(#MSG_ERASE + 1)
        local guid, cellsStr = payload:match("^([^|]+)|(.+)$")
        if guid and cellsStr then
            if not isLocal then
                local base = findBaseByGuid(guid)
                if base then
                    painter.eraseBatch(base, decodeCells(cellsStr))
                end
            end
            state.save()
            broadcastState()
        end

    elseif raw == MSG_REQ then
        -- Send full state to the requester
        local senderPC = ctx:get()
        if senderPC and senderPC:IsValid() then
            sendStateTo(senderPC)
        end
    end
end)

-- CLIENT: receive state broadcast from host
RegisterHook("/Script/Engine.PlayerController:ClientMessage", function(_, sParam)
    local ok, raw = pcall(function() return sParam:get():ToString() end)
    if not ok or not raw or raw:sub(1, #MSG_STATE) ~= MSG_STATE then return end

    local jsonStr = raw:sub(#MSG_STATE + 1)
    state.applyFromJson(jsonStr)

    if onStateReceived then
        onStateReceived()
    end

    print("[PaintBrush] sync: received state from host\n")
end)

-- Broadcast current state (called after local undo to override stale broadcasts)
function sync.broadcastCurrentState()
    broadcastState()
end

print("[PaintBrush] sync: multiplayer hooks registered\n")

return sync
