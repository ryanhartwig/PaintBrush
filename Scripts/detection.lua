local UEHelpers = require("UEHelpers")
local GetKismetSystemLibrary = UEHelpers.GetKismetSystemLibrary
local GetKismetMathLibrary = UEHelpers.GetKismetMathLibrary

local config = require("config")

local detection = {}

---Returns true if the class name looks like a SculpturalBaseProxy.
local function isSculpturalBaseProxy(className)
    if not className then return false end
    return className == "UWESculpturalBaseProxy"
        or className == "BP_SculpturalBaseProxy_C"
        or className:find("SculpturalBaseProxy") ~= nil
end

---Try to resolve the proxy actor from whatever the line trace hit.
---Returns the proxy actor, or nil.
local function resolveProxy(hitObj)
    if not hitObj or not hitObj:IsValid() then return nil end

    local className = hitObj:GetClass():GetFName():ToString()

    -- In UE 5.6 the hit handle gives us an ISM component, not the actor.
    -- Walk up to the owner first if needed.
    local actor = hitObj
    if className:find("Component") then
        local ok, owner = pcall(function() return hitObj:GetOwner() end)
        if not ok or not owner or not owner:IsValid() then return nil end
        actor = owner
        className = actor:GetClass():GetFName():ToString()
    end

    -- Direct match.
    if isSculpturalBaseProxy(className) then return actor end

    -- Check super struct in case of a Blueprint subclass we haven't seen yet.
    local ok, superName = pcall(function()
        return actor:GetClass():GetSuperStruct():GetFName():ToString()
    end)
    if ok and isSculpturalBaseProxy(superName) then return actor end

    return nil
end

---Compute cell coordinates from an impact point in world space, relative to
---the base actor, transformed into the base's local space via axis dot-products.
---Cell size is 100 UU (empirically confirmed).
local function computeCellCoords(hitResult, base)
    local ip = hitResult.ImpactPoint

    local baseLoc, fwdVec, rightVec, upVec
    local ok = pcall(function()
        baseLoc  = base:K2_GetActorLocation()
        fwdVec   = base:GetActorForwardVector()
        rightVec = base:GetActorRightVector()
        upVec    = base:GetActorUpVector()
    end)
    if not ok then return nil end

    local relX = ip.X - baseLoc.X
    local relY = ip.Y - baseLoc.Y
    local relZ = ip.Z - baseLoc.Z

    -- Project relative offset onto each local axis (dot product).
    local localX = relX * fwdVec.X   + relY * fwdVec.Y   + relZ * fwdVec.Z
    local localY = relX * rightVec.X + relY * rightVec.Y + relZ * rightVec.Z
    local localZ = relX * upVec.X    + relY * upVec.Y    + relZ * upVec.Z

    local cellSize = 100
    return {
        X = math.floor(localX / cellSize + 0.5),
        Y = math.floor(localY / cellSize + 0.5),
        Z = math.floor(localZ / cellSize + 0.5),
    }
end

---Perform a line trace from the player camera and return hit info, or nil.
---@return table|nil  { proxy, base, cellCoords }
function detection.getTargetInfo()
    local pc = UEHelpers:GetPlayerController()
    if not pc or not pc:IsValid() then return nil end

    local cam = pc.PlayerCameraManager
    if not cam or not cam:IsValid() then return nil end

    -- Build start/end of the trace.
    local start, endVec
    local ok = pcall(function()
        local kml = GetKismetMathLibrary()
        start  = cam:GetCameraLocation()
        local fwd = kml:GetForwardVector(cam:GetCameraRotation())
        endVec = kml:Add_VectorVector(
            start,
            kml:Multiply_VectorInt(fwd, config.TraceDistance))
    end)
    if not ok then return nil end

    -- Line trace (TraceTypeQuery1 = Visibility = 0).
    local hitResult = {}
    local wasHit = false
    ok = pcall(function()
        wasHit = GetKismetSystemLibrary():LineTraceSingle(
            pc.Pawn,        -- WorldContextObject
            start,
            endVec,
            0,              -- ETraceTypeQuery::TraceTypeQuery1 (Visibility)
            false,          -- bTraceComplex
            {},             -- ActorsToIgnore
            0,              -- DrawDebugType (none)
            hitResult,
            true,           -- bIgnoreSelf
            {R=0,G=0,B=0,A=0},
            {R=0,G=0,B=0,A=0},
            0.0)
    end)
    if not ok or not wasHit then return nil end

    -- Resolve the proxy actor from whatever we hit.
    local hitObj
    ok = pcall(function()
        hitObj = hitResult.HitObjectHandle.ReferenceObject:Get()
    end)
    if not ok then return nil end

    local proxy = resolveProxy(hitObj)
    if not proxy then return nil end

    -- Get the base actor from the proxy.
    local base
    ok = pcall(function()
        base = proxy:GetBase()
    end)
    if not ok or not base or not base:IsValid() then return nil end

    -- Compute cell coordinates.
    local cellCoords = computeCellCoords(hitResult, base)
    if not cellCoords then return nil end

    return {
        proxy      = proxy,
        base       = base,
        cellCoords = cellCoords,
    }
end

return detection
