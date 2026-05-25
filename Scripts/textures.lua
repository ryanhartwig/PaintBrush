local UEHelpers = require("UEHelpers")
local config = require("config")

local textures = {}
local cache = {}
local anchor = nil  -- hidden widget that roots textures to prevent GC

-- Normalize to backslashes for Windows (ImportFileAsTexture2D needs native path)
local BG_PATH = (config.ModDir .. "assets/background.png"):gsub("/", "\\")

function textures.load()
    if cache.background then return end  -- only load once

    local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local pc = UEHelpers:GetPlayerController()
    if not krl or not pc then
        print("[PaintBrush] textures.load: missing KRL or PC\n")
        return
    end

    print(string.format("[PaintBrush] textures.load: loading %s\n", BG_PATH))
    local loadOk, tex = pcall(function()
        return krl:ImportFileAsTexture2D(pc, BG_PATH)
    end)
    if loadOk and tex then
        cache.background = tex
    else
        print(string.format("[PaintBrush] textures.load: failed: %s\n", tostring(tex)))
        return
    end

    -- Root textures in a hidden widget to prevent UE GC
    if anchor then
        pcall(function() anchor:RemoveFromViewport() end)
        anchor = nil
    end

    local wbLib    = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uwClass  = StaticFindObject("/Script/UMG.UserWidget")
    local canvasCls = StaticFindObject("/Script/UMG.CanvasPanel")
    local imgCls   = StaticFindObject("/Script/UMG.Image")

    if not wbLib or not uwClass then
        print("[PaintBrush] textures.load: missing UMG classes\n")
        return
    end

    local root = wbLib:Create(pc, uwClass, pc)
    if not root then
        print("[PaintBrush] textures.load: failed to create anchor widget\n")
        return
    end

    local canvas = StaticConstructObject(canvasCls, root, FName("AnchorCanvas"))
    root.WidgetTree.RootWidget = canvas

    for name, tex in pairs(cache) do
        if tex then
            local img = StaticConstructObject(imgCls, root, FName("Anchor_" .. name))
            pcall(function() img:SetBrushFromTexture(tex, false) end)
            canvas:AddChildToCanvas(img)
        end
    end

    pcall(function() root:SetRenderOpacity(0) end)
    root:AddToViewport(-1)
    anchor = root

    print("[PaintBrush] textures.load: textures loaded and GC-rooted\n")
end

function textures.get(name)
    return cache[name]
end

function textures.invalidate()
    if anchor then
        pcall(function() anchor:RemoveFromViewport() end)
    end
    cache = {}
    anchor = nil
end

return textures
