local materials = {}

-- Internal cache: array of { name, path, ref, category }, sorted by category then name.
local cache = nil

-- Curated default favorites (confirmed paths from probing).
local DEFAULTS = {
    "/Game/Art/Bases/Materials/MI_Base_Floor.MI_Base_Floor",
    "/Game/Art/Bases/Materials/MI_BaseBuilding_Glass.MI_BaseBuilding_Glass",
    "/Game/Materials/BaseBuilding/Bases/MI_BaseBuilding_PoweredEmissive.MI_BaseBuilding_PoweredEmissive",
    "/Game/Materials/BaseBuilding/Bases/MI_BaseBuilding_PoweredEmissive_Strip.MI_BaseBuilding_PoweredEmissive_Strip",
    "/Game/Materials/BaseBuilding/Bases/MI_BaseBuilding_PoweredEmissive_OverheadLights.MI_BaseBuilding_PoweredEmissive_OverheadLights",
    "/Game/Art/Environment/Set/Alterra/Materials/MI_Alterra_Trimsheet.MI_Alterra_Trimsheet",
    "/Game/Art/Environment/Set/Alterra/Materials/MI_Alterra_Trimsheet_Fixed_Grunge.MI_Alterra_Trimsheet_Fixed_Grunge",
    "/Game/Materials/BaseBuilding/MI_HatchMembrane.MI_HatchMembrane",
    "/Game/Art/Bases/Materials/MI_PlanterSoil_01a.MI_PlanterSoil_01a",
}

-- Derive a display category from asset path and short name.
function materials.categorize(path, name)
    if path:find("/Art/Bases/Materials/")                   then return "Base Building"  end
    if path:find("/Materials/BaseBuilding/")                then return "Base Powered"   end
    if path:find("/Art/Bases/BasePieces/Exterior/")         then return "Exterior"       end
    if path:find("/Art/Bases/BasePieces/InteriorBuildables/") then return "Interior"     end
    if path:find("/Art/Environment/")                       then return "Environment"    end
    if path:find("/Art/Surfaces/")                          then return "Surfaces"       end
    if name:find("Glass")                                   then return "Glass"          end
    if name:find("Emissive")                                then return "Emissive"       end
    if path:find("ConstructionProgress")                    then return "zzz_Skip"       end
    if path:find("/Engine/") or path:find("/Paper2D/")      then return "zzz_Skip"       end
    return "Other"
end

-- Scan all MaterialInstanceConstant objects and populate the cache.
-- Safe to call multiple times; subsequent calls are no-ops.
-- Returns the populated cache array.
function materials.enumerate(force)
    if cache and not force then return cache end

    cache = {}

    local mats = FindAllOf("MaterialInstanceConstant")
    if not mats then
        print("[PaintBrush] materials.enumerate: no MaterialInstanceConstant objects found\n")
        return cache
    end

    for i = 1, #mats do
        local mat = mats[i]

        local ok, entry = pcall(function()
            if not mat or not mat:IsValid() then return nil end

            local name = mat:GetFName():ToString()

            local full = mat:GetFullName()
            local path = full:match("MaterialInstanceConstant (.+)")
            if not path then return nil end

            local category = materials.categorize(path, name)

            return {
                name     = name,
                path     = path,
                ref      = mat,
                category = category,
            }
        end)

        if ok and entry then
            table.insert(cache, entry)
        end
    end

    -- Sort: category first (alphabetical), then name.
    table.sort(cache, function(a, b)
        if a.category ~= b.category then
            return a.category < b.category
        end
        return a.name < b.name
    end)

    print(string.format("[PaintBrush] materials.enumerate: cached %d materials\n", #cache))
    return cache
end

-- Return the full sorted cache (lazy-loads on first call).
function materials.getAll()
    return materials.enumerate()
end

-- Look up a cached entry by its full asset path string.
-- Returns the entry table, or nil if not found.
function materials.getByPath(path)
    local all = materials.getAll()
    for i = 1, #all do
        if all[i].path == path then
            return all[i]
        end
    end
    return nil
end

-- Return the curated defaults list (array of path strings).
function materials.getDefaults()
    return DEFAULTS
end

return materials
