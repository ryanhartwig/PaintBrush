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
-- Curated material names (hand-picked from ~1000 materials)
local CURATED_NAMES = {
    "MI_BaseBuilding_Glass", "MI_BaseBuilding_Glass_Grunge", "MI_Base_Floor",
    "MI_PlanterSoil_01a", "MI_BaseBuilding_PoweredEmissive", "MI_BaseBuilding_PoweredEmissive_Grunge",
    "MI_BaseBuilding_PoweredEmissive_Strip", "MI_SupportOverlay",
    "MI_Blockout_Emissive_Blue_01a", "MI_Blockout_Emissive_Green_01a",
    "MI_Blockout_Emissive_Lamp", "MI_Blockout_Emissive_White_01a", "MI_Blockout_Emissive_Yellow_01a",
    "MI_Powercell_01_EmissiveStrip", "MI_RadialEmissive_OxygenTanks",
    "MI_Tadpole_Emissive", "MI_Tadpole_Emissive_off",
    "MI_AlgaePanels_01", "MI_AlgaeWeave_01a", "MI_Alterra_BaseFloor_Grunge",
    "MI_Alterra_Emissive_NOA_Eye", "MI_Alterra_GlassRidged_01", "MI_Alterra_PosterKitty_01a",
    "MI_Alterra_Trimsheet", "MI_Alterra_Trimsheet_Fixed", "MI_Alterra_Trimsheet_GradientActor",
    "MI_Alterra_Trimsheet_Grunge_Lifepod", "MI_AnemoneTower_01a_Dead",
    "MI_AxumTailings_CoralTubes_01", "MI_AxumTailings_Structures_01",
    "MI_AxumTailings_Structures_03", "MI_AxumTailings_Structures_04",
    "MI_Axum_Damascus_01b", "MI_Axum_GlassPattern_01b",
    "MI_BO_WT_Petal_01", "MI_Base_Floor_Grunge",
    "MI_BlightDamagePoint_Translucent_01a", "MI_BlightWebNoWindDissolve_01a",
    "MI_Blockout_WakeMaker_01b_Grunge", "MI_CG_CoralDomeBroken_01a",
    "MI_CG_Megajelly_01d", "MI_CG_RockSmooth_01a_TopSandBleached",
    "MI_CG_RockSmooth_02b_TopSand", "MI_CG_RockSmooth_02c_TransitionYi_TopSand",
    "MI_CG_SandPlaneBlend_01c", "MI_Cable_01_LargeTiling", "MI_CatTails_01_Body",
    "MI_CharismaticSlime_Corners", "MI_CharismaticSlime_Growth", "MI_CharismaticSlime_Inserts",
    "MI_CoralBranchingTree_01b", "MI_CoralCabbageLight_01a",
    "MI_CoralLobe_04a", "MI_CoralLobe_04b", "MI_CoralPittedTubeSponge_01a",
    "MI_CoralPlatingBlighted_01a", "MI_CoralPlatingBlighted_01b",
    "MI_Generic_Pebbles_04a", "MI_GroundSandCave_01a", "MI_GroundSandScree_01a",
    "MI_SkyDesertFake_01a", "MI_SkyDesertFake_01b",
    "MI_Tailing_AxumDrum_01a", "MI_Tailing_AxumDrum_02a",
    "MI_WT_RootIntersectionBlighted_01a", "MI_Base_Exterior_A",
    "MI_Glass_Tadpole", "MI_Waterslug_01_Body_Glass", "MI_Waterslug_01_Body_GlassCheap",
    "MI_Bed_Single_A", "MI_Biobed_Emissive", "MI_Fabricator_Emissive",
    "MI_ModificationStation_Emissive", "MI_Biobed_UI", "MI_Desk_A_Screen",
    "MI_Sofa_A_GrayDark", "MI_Sofa_A_Orange", "35mm_Prime",
    "MI_Anemonecrab_01_Eye", "MI_Axum_OrnatePearl_Amber_Temp",
    "MI_Axum_OrnatePearl_FulguriteBase_Temp", "MI_Base_Overhead_WhiteLights",
    "MI_BlockoutGrid_White", "MI_BlockoutGrid_Yellow",
    "MI_Blockout_BaseLightingStrip_02", "MI_Blockout_Blackout_01a",
    "MI_Blockout_DarkRed_Matte_01", "MI_Blockout_GreyDark_Matte_01a",
    "MI_Blockout_GreyLight_Matte_01a", "MI_Blockout_GreyLight_Matte_01b",
    "MI_Blockout_GreyLight_Matte_01c", "MI_Blockout_MetalRust_01a",
    "MI_Blockout_Orange_Matte_01b", "MI_Blockout_PlasticBlack_Matte_01a",
    "MI_Blockout_PlasticBlack_Shiny_01a", "MI_Blockout_PlasticYellow_Shiny_01a",
    "MI_Blockout_RockBrown_Matte_01a", "MI_Blockout_RockGrey_Matte_01a",
    "MI_Blockout_Yellow_Matte_01b", "MI_CavesWaterSurface",
    "MI_Char_LayerStandard_Creatures", "MI_Coralcrab_01_Eye",
    "MI_DeepStart_WaterSurface", "MI_Electricgeordie_01a_Eye", "MI_Fins_Standard",
    "MI_Fluttertail_01b_LOD0", "MI_Halfmoon_01_Eye", "MI_Halfmoon_01b_Eye",
    "MI_Houndgar_01_Eye", "MI_InvisSpawner_AnemoneFruit_01",
    "MI_Player_01_Eye", "MI_Player_02_Eye", "MI_Player_01_Eye_LOD", "MI_Player_01_Teeth",
    "MI_ResourcePrototype_Titanium", "MI_ResourcePrototype_Troilite",
    "MI_Resource_AtacamiteNode_01a", "MI_Resource_CelestineNode_01a",
    "MI_Resource_CelestineNode_01a_NoDFAO", "MI_Resource_GoldNode_02a",
    "MI_Resource_Quartz_02a", "MI_Sandspear_Adult_01_Eyes",
    "MI_TempBlightNode_Active", "MI_TempBlightNode_Remediated",
    "MI_Twineels_01a_Eye", "MI_Wakemaker_01b", "MI_Waxmoon_01_Eyes",
    "MI_Copper_01a", "MI_Titanium_01a",
}

-- Build lookup set for fast checking
local curatedSet = {}
for _, name in ipairs(CURATED_NAMES) do
    curatedSet[name] = true
end

function materials.isCurated(name)
    return curatedSet[name] == true
end

function materials.getDefaults()
    return DEFAULTS
end

return materials
