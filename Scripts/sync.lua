-- sync.lua — Multiplayer state synchronization for PaintBrush.
-- Host-authoritative: all paint actions route through the host.
-- Uses ServerExecRPC (client→host) and ClientMessage (host→clients).

local UEHelpers = require("UEHelpers")
local painter   = require("painter")
local state     = require("state")
local config    = require("config")

local sync = {}
local hostStateReady = false
local _onSaveNeeded = nil  -- set by main.lua to debouncedSave

function sync.setSaveCallback(cb)
    _onSaveNeeded = cb
end

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


--------------------------------------------------------------------------------
-- Sending (any player → host)
--------------------------------------------------------------------------------

-- Solo host detection: safe default is NOT solo (send RPCs).
-- relayToOthers() self-corrects by setting solo=true when it sends to nobody.
-- NotifyOnNewObject sets solo=false when a player joins.
local _isSoloHost = false
local _isHostKnown = false

local function refreshSoloHost()
    local save = FindFirstOf("UWESaveGame")
    if not save or not save:IsValid() then
        _isSoloHost = false  -- client, never solo
        _isHostKnown = true
        return
    end
    -- Host: don't scan PCs (unreliable during map transitions).
    -- Let relayToOthers detect solo by counting recipients.
    _isHostKnown = true
end

local function isSoloHost()
    if not _isHostKnown then refreshSoloHost() end
    return _isSoloHost
end

-- Detect player join: invalidates solo status
pcall(function()
    NotifyOnNewObject("/Script/Subnautica2.SN2PlayerController", function(newPC)
        _isSoloHost = false  -- another player joined, no longer solo
        print("[PaintBrush] sync: player joined, solo=false\n")
    end)
end)

-- Cached local PC name for isLocal checks (avoids 9ms GetFullName x2 per hook)
local _localPCName = nil

-- Cached base GUID lookup (avoids 9ms FindAllOf per remote paint)
local _guidToBase = nil

local function getBaseByGuid(guid)
    if not _guidToBase then
        _guidToBase = {}
        local bases = FindAllOf("UWESculpturalBaseActor")
        if bases then
            for _, base in ipairs(bases) do
                if base:IsValid() then
                    local g = nil
                    pcall(function()
                        local bg = base.BaseNetworkGUID
                        g = string.format("%08X%08X%08X%08X", bg.A, bg.B, bg.C, bg.D)
                    end)
                    if g then _guidToBase[g] = base end
                end
            end
        end
    end
    return _guidToBase[guid]
end

function sync.invalidateCache()
    _isHostKnown = false
    -- Don't reset _isSoloHost — safe default is false (send RPCs).
    -- relayToOthers will self-correct to true if nobody is connected.
    _localPCName = nil
    _guidToBase = nil
    painter.cancelScheduledRebuilds()
end

function sync.sendPaint(base, cellCoordsList, materialPath)
    local tSend0 = os.clock()
    if isSoloHost() then
        print(string.format("[PaintBrush] sendPaint: solo host, skipped (%.1fms)\n", (os.clock()-tSend0)*1000))
        return
    end
    local tCheck = os.clock()
    local guid = guidString(base)
    if not guid then return end
    local msg = MSG_PAINT .. guid .. "|" .. encodeCells(cellCoordsList) .. "|" .. materialPath
    local tBuild = os.clock()
    pcall(function()
        local pc = UEHelpers:GetPlayerController()
        if pc and pc:IsValid() then
            pc:ServerExecRPC(msg)
        end
    end)
    local tRPC = os.clock()
    print(string.format("[PaintBrush] sendPaint perf: playerChk=%.1fms build=%.1fms RPC=%.1fms TOTAL=%.1fms\n",
        (tCheck-tSend0)*1000, (tBuild-tCheck)*1000, (tRPC-tBuild)*1000, (tRPC-tSend0)*1000))
end

function sync.sendErase(base, cellCoordsList)
    if isSoloHost() then return end
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

-- Relay a small action message to all non-self clients (instead of full state)
-- Self-corrects _isSoloHost: if we send to nobody, we're solo.
local function relayToOthers(msg)
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
    -- Self-correct: if nobody received the relay, we're actually solo
    if sent == 0 and _isHostKnown then
        _isSoloHost = true
        print("[PaintBrush] sync: relay sent to 0 players, solo=true\n")
    end
end

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

    -- Check if sender is local player (cached local PC name)
    local isLocal = false
    pcall(function()
        if not _localPCName then
            local localPC = UEHelpers:GetPlayerController()
            if localPC then _localPCName = localPC:GetFullName() end
        end
        local senderPC = ctx:get()
        if senderPC and _localPCName then
            isLocal = (senderPC:GetFullName() == _localPCName)
        end
    end)

    if raw:sub(1, #MSG_PAINT) == MSG_PAINT then
        local payload = raw:sub(#MSG_PAINT + 1)
        local guid, cellsStr, matPath = payload:match("^([^|]+)|([^|]+)|(.+)$")
        if guid and cellsStr and matPath then
            if not isLocal then
                local base = getBaseByGuid(guid)
                if base then
                    -- Use incremental path (skipRebuild=false) — no Empty(), no crash
                    painter.applyBatch(base, decodeCells(cellsStr), matPath, true, false)
                end
                if _onSaveNeeded then _onSaveNeeded() end
            end
            relayToOthers(MSG_RELAY_PAINT .. guid .. "|" .. cellsStr .. "|" .. matPath)
        end

    elseif raw:sub(1, #MSG_ERASE) == MSG_ERASE then
        local payload = raw:sub(#MSG_ERASE + 1)
        local guid, cellsStr = payload:match("^([^|]+)|(.+)$")
        if guid and cellsStr then
            if not isLocal then
                local base = getBaseByGuid(guid)
                if base then
                    painter.eraseBatch(base, decodeCells(cellsStr), true, false)
                end
                if _onSaveNeeded then _onSaveNeeded() end
            end
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
            local base = getBaseByGuid(guid)
            if base then
                -- Use incremental path directly — no Empty(), no crash
                painter.applyBatch(base, decodeCells(cellsStr), matPath, true, false)
                painter.scheduleDeferredRebuild()
            end
        end
        return
    end

    -- Relayed erase action
    if raw:sub(1, #MSG_RELAY_ERASE) == MSG_RELAY_ERASE then
        local payload = raw:sub(#MSG_RELAY_ERASE + 1)
        local guid, cellsStr = payload:match("^([^|]+)|(.+)$")
        if guid and cellsStr then
            local base = getBaseByGuid(guid)
            if base then
                painter.eraseBatch(base, decodeCells(cellsStr), true, false)
            end
        end
        return
    end
end)


print("[PaintBrush] sync: multiplayer hooks registered\n")

return sync
