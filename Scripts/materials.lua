local materials = {}

-- Internal cache: array of { name, path, ref, category }, sorted by category then name.
local cache = nil

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
-- Curated materials: {name, label, subcategory} sorted by subcategory then label
-- Entries without labels were dropped. Subcategories: Basic Building, Colors, Dynamic, Emissives, Glass, Glossy
local CURATED = {
    -- Basic Building
    {n="MI_AlgaePanels_01", l="Bamboo Floor Panels", s="Basic Building"},
    {n="MI_Alterra_BaseFloor_Grunge", l="Basic Floor High Res", s="Basic Building"},
    {n="MI_Alterra_Emissive_NOA_Eye", l="Dance / Club Floor", s="Basic Building"},
    {n="MI_Alterra_PosterKitty_01a", l="Keep Calm Floor", s="Basic Building"},
    {n="MI_Alterra_Trimsheet", l="Trimsheet Metallic Floor", s="Basic Building"},
    {n="MI_Alterra_Trimsheet_Fixed", l="Trimsheet Metallic Floor Enhanced", s="Basic Building"},
    {n="MI_AnemoneTower_01a_Dead", l="Grey Wood Pattern Ceiling", s="Basic Building"},
    {n="MI_AxumTailings_CoralTubes_01", l="Red Fleshy Floor / Blue Coral Wall", s="Basic Building"},
    {n="MI_AxumTailings_Structures_01", l="Corkboard Style Wall", s="Basic Building"},
    {n="MI_AxumTailings_Structures_04", l="Dirty Metallic Floor", s="Basic Building"},
    {n="MI_Axum_Damascus_01b", l="Grey Pattern Floor", s="Basic Building"},
    {n="MI_Axum_GlassPattern_01b", l="Axum Glass Pattern - Blue-Gold Floor", s="Basic Building"},
    {n="MI_Axum_OrnatePearl_Amber_Temp", l="Green Emerald Floor", s="Basic Building"},
    {n="MI_Axum_OrnatePearl_FulguriteBase_Temp", l="Teal Gradient Pearl Floor", s="Basic Building"},
    {n="MI_BO_WT_Petal_01", l="Pink Petal Pattern", s="Basic Building"},
    {n="MI_Base_Exterior_A", l="White/Orange Base Exterior", s="Basic Building"},
    {n="MI_Base_Floor", l="Base Floor", s="Basic Building"},
    {n="MI_Base_Floor_Grunge", l="Basic Floor Tinted", s="Basic Building"},
    {n="MI_Bed_Single_A", l="Red Gradient Wall & Ceiling", s="Basic Building"},
    {n="MI_BlockoutGrid_White", l="Black Grid on White", s="Basic Building"},
    {n="MI_BlockoutGrid_Yellow", l="Black/White Grid on Yellow", s="Basic Building"},
    {n="MI_Blockout_MetalRust_01a", l="Rust Floor", s="Basic Building"},
    {n="MI_CG_CoralDomeBroken_01a", l="WhiteWashed Pattern Floor", s="Basic Building"},
    {n="MI_CG_Megajelly_01d", l="Megajelly - Reflective Blue Floor", s="Basic Building"},
    {n="MI_CG_RockSmooth_02b_TopSand", l="Sand Floor", s="Basic Building"},
    {n="MI_Cable_01_LargeTiling", l="Black HexGrid", s="Basic Building"},
    {n="MI_CoralBranchingTree_01b", l="Bloodcell Floor", s="Basic Building"},
    {n="MI_CoralPlatingBlighted_01a", l="Pebble Floor", s="Basic Building"},
    {n="MI_Generic_Pebbles_04a", l="Teal Gradient with Pattern Floor", s="Basic Building"},
    {n="MI_GroundSandCave_01a", l="Modern Wood Wall / Sand Floor", s="Basic Building"},
    {n="MI_GroundSandScree_01a", l="Lighter Wood Wall / Sand Floor", s="Basic Building"},
    {n="MI_Resource_CelestineNode_01a", l="Reflective Teal Patterned Floor", s="Basic Building"},
    {n="MI_Resource_CelestineNode_01a_NoDFAO", l="Reflective Teal Patterned Floor Dimmed", s="Basic Building"},
    {n="MI_Resource_GoldNode_02a", l="Gold Ore Patterned Floor", s="Basic Building"},
    {n="MI_Resource_Quartz_02a", l="Quartz Floor", s="Basic Building"},
    {n="MI_ResourcePrototype_Troilite", l="Gold Metallic Clean Pattern", s="Basic Building"},
    {n="MI_Sofa_A_GrayDark", l="Dark Grey Textured Wall", s="Basic Building"},
    {n="MI_Sofa_A_Orange", l="Orange Textured Wall", s="Basic Building"},
    {n="MI_Tailing_AxumDrum_01a", l="AxumDrum Purple/Wood Floor", s="Basic Building"},
    {n="MI_Tailing_AxumDrum_02a", l="AxumDrum Purple/Wood Floor 1", s="Basic Building"},
    -- Colors
    {n="MI_Blockout_Blackout_01a", l="Full Blackout", s="Colors"},
    {n="MI_Blockout_DarkRed_Matte_01", l="Dark Red Matte", s="Colors"},
    {n="MI_Blockout_GreyDark_Matte_01a", l="Grey Matte 1", s="Colors"},
    {n="MI_Blockout_GreyLight_Matte_01a", l="Grey Matte 2", s="Colors"},
    {n="MI_Blockout_GreyLight_Matte_01b", l="Grey Matte 3", s="Colors"},
    {n="MI_Blockout_GreyLight_Matte_01c", l="White Matte", s="Colors"},
    {n="MI_Blockout_Orange_Matte_01b", l="Light Orange Matte", s="Colors"},
    {n="MI_Blockout_PlasticBlack_Shiny_01a", l="Shiny Black", s="Colors"},
    {n="MI_Blockout_PlasticYellow_Shiny_01a", l="Shiny Yellow", s="Colors"},
    {n="MI_Blockout_RockBrown_Matte_01a", l="Shiny Rock Brown", s="Colors"},
    {n="MI_Blockout_RockGrey_Matte_01a", l="Shiny Rock Grey", s="Colors"},
    {n="MI_Blockout_Yellow_Matte_01b", l="Shiny Gold", s="Colors"},
    {n="MI_CatTails_01_Body", l="Teal Gradient", s="Colors"},
    {n="MI_Char_LayerStandard_Creatures", l="Plastic White", s="Colors"},
    {n="MI_CoralCabbageLight_01a", l="Dark Pink with Floor Pattern", s="Colors"},
    {n="MI_CoralLobe_04a", l="Patterned Light Orange", s="Colors"},
    {n="MI_CoralLobe_04b", l="Patterned Light Orange 1", s="Colors"},
    {n="MI_CoralPittedTubeSponge_01a", l="Patterned Green", s="Colors"},
    {n="MI_Copper_01a", l="Clean Copper Metallic", s="Colors"},
    {n="MI_InvisSpawner_AnemoneFruit_01", l="Beige Plastic", s="Colors"},
    {n="MI_Resource_AtacamiteNode_01a", l="Reflective Teal", s="Colors"},
    {n="MI_ResourcePrototype_Titanium", l="Multicolor Metallic", s="Colors"},
    {n="MI_Tadpole_Emissive_off", l="Blackout", s="Colors"},
    {n="MI_TempBlightNode_Active", l="Pink Gradient", s="Colors"},
    {n="MI_Titanium_01a", l="Titanium Metallic", s="Colors"},
    {n="MI_Wakemaker_01b", l="Blue Sparkly Wall", s="Colors"},
    {n="MI_Waterslug_01_Body_GlassCheap", l="Blue Tinted + Rainbow Floor", s="Colors"},
    -- Dynamic
    {n="MI_CavesWaterSurface", l="CavesWaterSurface - Removes Fog", s="Dynamic"},
    {n="MI_CharismaticSlime_Corners", l="Green Rainbow Marble", s="Dynamic"},
    {n="MI_CharismaticSlime_Growth", l="Green Rainbow Marble 1", s="Dynamic"},
    {n="MI_CharismaticSlime_Inserts", l="Green Rainbow Marble 2", s="Dynamic"},
    {n="MI_DeepStart_WaterSurface", l="Trippy Watery Reflective", s="Dynamic"},
    {n="MI_SkyDesertFake_01a", l="Skybox Screen Glitch", s="Dynamic"},
    {n="MI_SkyDesertFake_01b", l="Skybox Screen Glitch Tinted", s="Dynamic"},
    {n="MI_TempBlightNode_Remediated", l="Green Gradient Dynamic", s="Dynamic"},
    -- Emissives
    {n="MI_BaseBuilding_PoweredEmissive", l="Powered Emissive - 1x1 Floor Lights", s="Emissives"},
    {n="MI_BaseBuilding_PoweredEmissive_Grunge", l="Red Powered Emissive", s="Emissives"},
    {n="MI_BaseBuilding_PoweredEmissive_Strip", l="White Powered Emissive", s="Emissives"},
    {n="MI_Base_Overhead_WhiteLights", l="Bright White Emissive", s="Emissives"},
    {n="MI_Biobed_Emissive", l="LightStrip Floor", s="Emissives"},
    {n="MI_Blockout_BaseLightingStrip_02", l="Lightblue Emissive", s="Emissives"},
    {n="MI_Blockout_Emissive_Blue_01a", l="Bright Blue Emissive", s="Emissives"},
    {n="MI_Blockout_Emissive_Green_01a", l="Green Emissive", s="Emissives"},
    {n="MI_Blockout_Emissive_Lamp", l="Soft White Emissive", s="Emissives"},
    {n="MI_Blockout_Emissive_White_01a", l="Bright White Emissive", s="Emissives"},
    {n="MI_Blockout_Emissive_Yellow_01a", l="Large Fill Yellow Light", s="Emissives"},
    {n="MI_ModificationStation_Emissive", l="LightStrip Floor (Wide)", s="Emissives"},
    {n="MI_PlanterSoil_01a", l="Stone Pattern - Brownish", s="Emissives"},
    -- Glass
    {n="MI_Alterra_GlassRidged_01", l="Ridged Glass", s="Glass"},
    {n="MI_BaseBuilding_Glass", l="Basic Glass", s="Glass"},
    {n="MI_BaseBuilding_Glass_Grunge", l="Tinted Glass", s="Glass"},
    {n="MI_BlightDamagePoint_Translucent_01a", l="Light Blue Tinted Glass", s="Glass"},
    {n="MI_Glass_Tadpole", l="Glass Tadpole (Tiled)", s="Glass"},
    {n="MI_SupportOverlay", l="Green Tinted Glass", s="Glass"},
    {n="MI_Waterslug_01_Body_Glass", l="Rainbow Tinted Glass", s="Glass"},
    -- Glossy
    {n="MI_Anemonecrab_01_Eye", l="Dark Blue Glossy", s="Glossy"},
    {n="MI_Coralcrab_01_Eye", l="Blue Gloss", s="Glossy"},
    {n="MI_Electricgeordie_01a_Eye", l="Black Gloss - Very Reflective", s="Glossy"},
    {n="MI_Halfmoon_01_Eye", l="Gold Tiled Glossy", s="Glossy"},
    {n="MI_Halfmoon_01b_Eye", l="Navy Blue Glossy", s="Glossy"},
    {n="MI_Houndgar_01_Eye", l="Navy Blue Glossy 1", s="Glossy"},
    {n="MI_Player_01_Eye", l="Red Glossy Washed Out", s="Glossy"},
    {n="MI_Player_01_Eye_LOD", l="Red Glossy Washed Out Light", s="Glossy"},
    {n="MI_Sandspear_Adult_01_Eyes", l="Black Metallic Glossy", s="Glossy"},
    {n="MI_Twineels_01a_Eye", l="Teal Trippy", s="Glossy"},
    {n="MI_Waxmoon_01_Eyes", l="Blue Glossy Variant", s="Glossy"},
}

-- Build lookup sets
local curatedSet = {}
local curatedInfo = {}  -- name → {label, subcategory}
for _, entry in ipairs(CURATED) do
    curatedSet[entry.n] = true
    curatedInfo[entry.n] = {label = entry.l, subcategory = entry.s}
end

function materials.isCurated(name)
    return curatedSet[name] == true
end

function materials.getCuratedLabel(name)
    local info = curatedInfo[name]
    return info and info.label or name
end

function materials.getCuratedSubcategory(name)
    local info = curatedInfo[name]
    return info and info.subcategory or "Other"
end

function materials.getCuratedSubcategories()
    return {"Basic Building", "Colors", "Dynamic", "Emissives", "Glass", "Glossy"}
end

return materials
