local UEHelpers = require("UEHelpers")
local config    = require("config")
local materials = require("materials")
local textures  = require("textures")

local ui = {}

-- ============================================================
-- Widget class cache
-- ============================================================

local classes = {}
local function initClasses()
    if classes.wbLib then return true end
    classes.wbLib    = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    classes.uwClass  = StaticFindObject("/Script/UMG.UserWidget")
    classes.canvas   = StaticFindObject("/Script/UMG.CanvasPanel")
    classes.vbox     = StaticFindObject("/Script/UMG.VerticalBox")
    classes.hbox     = StaticFindObject("/Script/UMG.HorizontalBox")
    classes.text     = StaticFindObject("/Script/UMG.TextBlock")
    classes.scroll   = StaticFindObject("/Script/UMG.ScrollBox")
    classes.img      = StaticFindObject("/Script/UMG.Image")
    classes.sizeBox  = StaticFindObject("/Script/UMG.SizeBox")
    return classes.wbLib ~= nil
end

-- ============================================================
-- Widget naming (required — unnamed widgets crash)
-- ============================================================

local widgetCounter = 0
local function newName(prefix)
    widgetCounter = widgetCounter + 1
    return FName(prefix .. "_" .. widgetCounter)
end

-- ============================================================
-- Factory helpers
-- ============================================================

-- Game font capture (call once after world loads)
local gameFont = nil
local function captureGameFont()
    if gameFont then return end
    pcall(function()
        local allTb = FindAllOf("TextBlock")
        if allTb then
            for _, tb in ipairs(allTb) do
                if tb:IsValid() then
                    gameFont = tb.Font
                    return
                end
            end
        end
    end)
end

local function makeText(outer, str, opts)
    local tb = StaticConstructObject(classes.text, outer, newName("Txt"))
    if str then tb:SetText(FText(str)) end
    -- Apply styling: smaller font, dimmed
    opts = opts or {}
    local size = opts.size or 12
    local opacity = opts.opacity or 0.6
    if gameFont then
        pcall(function()
            local f = gameFont
            f.Size = size
            tb:SetFont(f)
        end)
    end
    pcall(function() tb:SetRenderOpacity(opacity) end)
    return tb
end

local function makeHBox(outer)
    return StaticConstructObject(classes.hbox, outer, newName("HBox"))
end

local function makeVBox(outer)
    return StaticConstructObject(classes.vbox, outer, newName("VBox"))
end

local function makeImage(outer)
    return StaticConstructObject(classes.img, outer, newName("Img"))
end

local function makeSizeBox(outer, width, height)
    local sb = StaticConstructObject(classes.sizeBox, outer, newName("Size"))
    if width then pcall(function() sb:SetWidthOverride(width) end) end
    if height then pcall(function() sb:SetHeightOverride(height) end) end
    return sb
end

-- ============================================================
-- Button system (global hook, register once)
-- ============================================================

local buttonActions = {}
local buttonHookRegistered = false

local function registerButtonHook()
    if buttonHookRegistered then return end
    pcall(function()
        RegisterHook("/Script/CommonUI.CommonButtonBase:HandleButtonClicked", function(self)
            local widget = self:get()
            if not widget or not widget:IsValid() then return end
            local addr = tostring(widget:GetAddress())
            local action = buttonActions[addr]
            if action then
                ExecuteInGameThread(function() action() end)
            end
        end)
    end)
    buttonHookRegistered = true
end

local function getButtonClass()
    return StaticFindObject("/Game/Blueprints/UI/GenericUIElements/GenericUI_WBP/WBP_ButtonGenericBlueSmall.WBP_ButtonGenericBlueSmall_C")
end

local function makeButton(root, text, onClick)
    local btnClass = getButtonClass()
    if not btnClass then return makeText(root, "[" .. text .. "]") end
    local pc = UEHelpers:GetPlayerController()
    local btn = classes.wbLib:Create(pc, btnClass, pc)
    if not btn then return makeText(root, "[" .. text .. "]") end
    pcall(function() btn:SetText(FText(text)) end)
    if onClick then
        buttonActions[tostring(btn:GetAddress())] = onClick
    end
    return btn
end

-- ============================================================
-- Responsive panel layout (height-driven, aspect-locked)
-- ============================================================

local DESIGN_W, DESIGN_H = 1536, 972
local DESIGN_RATIO = DESIGN_W / DESIGN_H
local PANEL_HEIGHT = 0.80

local PANEL = { L = 0.10, R = 0.90, T = 0.10, B = 0.90 }

local function pX(frac)
    return PANEL.L + frac * (PANEL.R - PANEL.L)
end

local function pY(frac)
    return PANEL.T + frac * (PANEL.B - PANEL.T)
end

local function computeBounds()
    local vpW, vpH = 0, 0
    pcall(function()
        local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        local pc = UEHelpers:GetPlayerController()
        local size = wll:GetViewportSize(pc)
        vpW, vpH = size.X, size.Y
    end)
    if vpW <= 0 or vpH <= 0 then return end
    local halfH = PANEL_HEIGHT / 2
    PANEL.T = 0.5 - halfH
    PANEL.B = 0.5 + halfH
    local panelH = PANEL_HEIGHT * vpH
    local panelW = panelH * DESIGN_RATIO
    local maxW = 0.92 * vpW
    if panelW > maxW then panelW = maxW end
    local halfW = (panelW / vpW) / 2
    local centerX = 0.523
    PANEL.L = centerX - halfW
    PANEL.R = centerX + halfW
end

-- ============================================================
-- State
-- ============================================================

local isOpen = false
local rootWidget = nil
local modalBlocker = nil
local onApplyCallback = nil
local onSelectCallback = nil
local selectedMaterialPath = nil  -- must be before buildUI so renderPage can see it

-- Category filter state (persists across open/close for "remember position")
local CATEGORIES = {
    "Favourites",
    "Curated",
    "Base Building",
    "Base Powered",
    "Glass",
    "Emissive",
    "Environment",
    "Surfaces",
    "Interior",
    "Other",
    "ALL",
}

local categoryButtons = {}
local materialRows = {}
local activeCategoryName = "Curated"  -- persists across open/close
local savedPage = 1                        -- persists across open/close

-- Brush size state (persists, readable via ui.getBrushRadius())
local BRUSH_SIZES = { {label = "Small (1x1)", radius = 0}, {label = "Large (3x3)", radius = 1} }
local activeBrushIdx = 1
local brushButtons = {}

-- Eraser mode (persists, readable via ui.isEraserMode())
local eraserActive = false
local eraserButton = nil

-- ============================================================
-- Favourites persistence
-- ============================================================

local favourites = {}  -- set: { [materialPath] = true }

local function getFavouritesPath()
    return config.ModDir .. "favourites.txt"
end

local function loadFavourites()
    local f = io.open(getFavouritesPath(), "r")
    if not f then return end
    favourites = {}
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            favourites[line] = true
        end
    end
    f:close()
end

local function saveFavourites()
    local f = io.open(getFavouritesPath(), "w")
    if not f then return end
    for path in pairs(favourites) do
        f:write(path .. "\n")
    end
    f:close()
end

local function toggleFavourite(matPath)
    if favourites[matPath] then
        favourites[matPath] = nil
    else
        favourites[matPath] = true
    end
    saveFavourites()
end

-- Load favourites at require time
loadFavourites()

-- ============================================================
-- Category filtering
-- ============================================================

local function isShowAll()
    return activeCategoryName == "ALL"
end

local function isFavouritesMode()
    return activeCategoryName == "Favourites"
end

local function isCuratedMode()
    return activeCategoryName == "Curated"
end

local function updateCategoryButtonOpacity()
    for catName, btn in pairs(categoryButtons) do
        pcall(function()
            btn:SetRenderOpacity(catName == activeCategoryName and 1.0 or 0.3)
        end)
    end
end

-- Forward declaration — populated in buildUI
local rebuildMaterialList = nil

local function onCategoryClick(catName)
    activeCategoryName = catName
    updateCategoryButtonOpacity()
    if rebuildMaterialList then rebuildMaterialList() end
end

-- ============================================================
-- Build UI
-- ============================================================

local function buildUI(onApply, onSelect)
    if not initClasses() then
        print("[PaintBrush] ui.buildUI: failed to init widget classes\n")
        return nil
    end

    registerButtonHook()
    computeBounds()
    captureGameFont()

    local pc = UEHelpers:GetPlayerController()
    if not pc then
        print("[PaintBrush] ui.buildUI: no player controller\n")
        return nil
    end

    -- Create root UserWidget
    local root = classes.wbLib:Create(pc, classes.uwClass, pc)
    if not root then
        print("[PaintBrush] ui.buildUI: failed to create root widget\n")
        return nil
    end

    local canvas = StaticConstructObject(classes.canvas, root, newName("RootCanvas"))
    root.WidgetTree.RootWidget = canvas

    -- Background image
    local bgTex = textures.get("background")
    if bgTex then
        local bg = StaticConstructObject(classes.img, root, newName("BG"))
        pcall(function() bg:SetBrushFromTexture(bgTex, false) end)
        local bgSlot = canvas:AddChildToCanvas(bg)
        bgSlot:SetAnchors({ Minimum = { X = PANEL.L, Y = PANEL.T }, Maximum = { X = PANEL.R, Y = PANEL.B } })
        bgSlot:SetAutoSize(false)
    end

    -- Ensure materials are loaded (lazy, no force re-scan — map load hook handles that)
    materials.enumerate()

    -- Reset filter state
    categoryButtons = {}
    materialRows = {}

    -- --------------------------------------------------------
    -- Left sidebar: category filter buttons (placed directly on canvas like DT)
    -- --------------------------------------------------------
    local startY = 0.08
    local stepY = 0.055

    for i, catName in ipairs(CATEGORIES) do
        local btn = makeButton(root, catName, function()
            onCategoryClick(catName)
        end)
        categoryButtons[catName] = btn
        local yPos = startY + (i - 1) * stepY
        local btnSlot = canvas:AddChildToCanvas(btn)
        btnSlot:SetAnchors({
            Minimum = { X = pX(0.05), Y = pY(yPos) },
            Maximum = { X = pX(0.05), Y = pY(yPos) },
        })
        btnSlot:SetAutoSize(true)
    end

    updateCategoryButtonOpacity()

    -- --------------------------------------------------------
    -- Brush size + eraser toggles (directly below category buttons)
    -- --------------------------------------------------------
    brushButtons = {}
    local toolY = startY + #CATEGORIES * stepY + 0.02  -- gap after last category

    local function updateBrushButtonOpacity()
        for idx, btn in pairs(brushButtons) do
            pcall(function()
                btn:SetRenderOpacity(idx == activeBrushIdx and 1.0 or 0.3)
            end)
        end
    end

    for i, bs in ipairs(BRUSH_SIZES) do
        local idx = i
        local btn = makeButton(root, bs.label, function()
            activeBrushIdx = idx
            updateBrushButtonOpacity()
        end)
        brushButtons[idx] = btn
        local yPos = toolY + (i - 1) * stepY
        local btnSlot = canvas:AddChildToCanvas(btn)
        btnSlot:SetAnchors({
            Minimum = { X = pX(0.05), Y = pY(yPos) },
            Maximum = { X = pX(0.05), Y = pY(yPos) },
        })
        btnSlot:SetAutoSize(true)
    end
    updateBrushButtonOpacity()

    -- Eraser toggle
    local function updateEraserOpacity()
        if eraserButton then
            pcall(function() eraserButton:SetRenderOpacity(eraserActive and 1.0 or 0.3) end)
        end
    end

    local eraserY = toolY + #BRUSH_SIZES * stepY
    eraserButton = makeButton(root, "ERASER", function()
        eraserActive = not eraserActive
        updateEraserOpacity()
    end)
    local eraserSlot = canvas:AddChildToCanvas(eraserButton)
    eraserSlot:SetAnchors({
        Minimum = { X = pX(0.05), Y = pY(eraserY) },
        Maximum = { X = pX(0.05), Y = pY(eraserY) },
    })
    eraserSlot:SetAutoSize(true)
    updateEraserOpacity()

    -- --------------------------------------------------------
    -- Right panel: scrollable material list (built per category)
    -- --------------------------------------------------------
    local scrollBox = StaticConstructObject(classes.scroll, root, newName("Scroll"))
    local scrollSlot = canvas:AddChildToCanvas(scrollBox)
    scrollSlot:SetAnchors({
        Minimum = { X = pX(0.17), Y = pY(0.05) },
        Maximum = { X = pX(0.96), Y = pY(0.93) },
    })
    scrollSlot:SetAutoSize(false)

    local allMats = materials.getAll()

    -- Pagination state
    local PAGE_SIZE = 20
    local currentPage = savedPage
    local filteredMats = {}  -- current filtered list (rebuilt on category change)

    -- Filter materials for the current category
    local function rebuildFilteredList()
        filteredMats = {}
        local showAll = isShowAll()
        local showFavs = isFavouritesMode()
        local showCurated = isCuratedMode()

        for _, mat in ipairs(allMats) do
            if mat.category == "zzz_Skip" then goto nextMat end
            if showFavs then
                if not favourites[mat.path] then goto nextMat end
            elseif showCurated then
                if not materials.isCurated(mat.name) then goto nextMat end
            elseif not showAll then
                if mat.category ~= activeCategoryName then goto nextMat end
            end
            table.insert(filteredMats, mat)
            ::nextMat::
        end

        -- Sort by curated subcategory then label when in Curated mode
        if showCurated then
            table.sort(filteredMats, function(a, b)
                local sa = materials.getCuratedSubcategory(a.name)
                local sb = materials.getCuratedSubcategory(b.name)
                if sa ~= sb then return sa < sb end
                return materials.getCuratedLabel(a.name) < materials.getCuratedLabel(b.name)
            end)
        end
    end

    -- Render current page of materials
    local function renderPage()
        materialRows = {}

        -- Clear scrollbox children
        pcall(function()
            local childCount = scrollBox:GetChildrenCount()
            for i = childCount - 1, 0, -1 do
                local child = scrollBox:GetChildAt(i)
                if child then scrollBox:RemoveChild(child) end
            end
        end)

        local listVBox = makeVBox(root)
        scrollBox:AddChild(listVBox)

        local totalPages = math.max(1, math.ceil(#filteredMats / PAGE_SIZE))
        if currentPage > totalPages then currentPage = totalPages end
        savedPage = currentPage

        -- Page info header
        local pageInfo = makeText(root, string.format(
            "%d materials — Page %d/%d", #filteredMats, currentPage, totalPages),
            {size=11, opacity=0.35})
        listVBox:AddChild(pageInfo)

        -- Page navigation: [1] [3] [4] [5] [6] [7] [12]
        -- Jump-back on left (clamped), 5 sequential centered, jump-forward on right (clamped)
        if totalPages > 1 then
            local navRow = makeHBox(root)

            local function addPageBtn(p)
                local pageNum = p
                local pageBtn = makeButton(root, tostring(p), function()
                    currentPage = pageNum
                    savedPage = currentPage
                    renderPage()
                end)
                pcall(function()
                    pageBtn:SetRenderOpacity(p == currentPage and 1.0 or 0.4)
                end)
                navRow:AddChildToHorizontalBox(pageBtn)
            end

            -- Jump back: current - 5, clamped to 1
            local jumpBack = math.max(1, currentPage - 5)

            -- Center window: 5 sequential pages centered on current
            local startP = math.max(1, currentPage - 2)
            local endP = math.min(totalPages, startP + 4)
            startP = math.max(1, endP - 4)

            -- Jump forward: current + 5, clamped to totalPages
            local jumpFwd = math.min(totalPages, currentPage + 5)

            -- Left jump (only if it's outside the center window)
            if jumpBack < startP then
                addPageBtn(jumpBack)
            end

            -- Center window
            for p = startP, endP do
                addPageBtn(p)
            end

            -- Right jump (only if it's outside the center window)
            if jumpFwd > endP then
                addPageBtn(jumpFwd)
            end

            listVBox:AddChild(navRow)
        end

        -- Material rows for current page, with subcategory headers in Curated mode
        local startIdx = (currentPage - 1) * PAGE_SIZE + 1
        local endIdx = math.min(startIdx + PAGE_SIZE - 1, #filteredMats)
        local lastSubcat = nil

        for i = startIdx, endIdx do
            local mat = filteredMats[i]

            -- Subcategory header (in Curated/Favourites/ALL modes)
            if isCuratedMode() or isFavouritesMode() or isShowAll() then
                local subcat = materials.getCuratedSubcategory(mat.name)
                if subcat ~= lastSubcat then
                    lastSubcat = subcat
                    local header = makeText(root, "— " .. subcat .. " —", {size=11, opacity=0.35})
                    listVBox:AddChild(header)
                end
            end

            local row = makeHBox(root)

            -- Use curated label if available, otherwise material name
            local MAX_NAME_LEN = 45
            local isSelected = (mat.path == selectedMaterialPath)
            local displayName = materials.getCuratedLabel(mat.name)
            if #displayName > MAX_NAME_LEN then
                displayName = "..." .. displayName:sub(-(MAX_NAME_LEN - 3))
            end
            if isSelected then
                displayName = displayName .. "  <<<"
            end
            local nameText = makeText(root, displayName,
                {size=12, opacity = isSelected and 1.0 or 0.6})
            row:AddChildToHorizontalBox(nameText)

            -- Fill spacer
            local spacer = StaticConstructObject(classes.sizeBox, root, newName("Spacer"))
            pcall(function() spacer:SetMinDesiredWidth(20) end)
            local spacerSlot = row:AddChildToHorizontalBox(spacer)
            pcall(function() spacerSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end)

            local matPath = mat.path
            local matName = mat.name

            -- FAV button
            local favLabel = favourites[matPath] and "UNFAV" or "FAV"
            local favBtn = makeButton(root, favLabel, function()
                toggleFavourite(matPath)
                if isFavouritesMode() then
                    rebuildFilteredList()
                    currentPage = 1
                end
                renderPage()
            end)
            row:AddChildToHorizontalBox(favBtn)

            -- APPLY button
            local applyBtn = makeButton(root, "APPLY", function()
                if onApply then onApply(matPath, matName) end
            end)
            row:AddChildToHorizontalBox(applyBtn)

            -- SELECT button
            local selectBtn = makeButton(root, "SELECT", function()
                if onSelect then onSelect(matPath, matName) end
                ui.close()
            end)
            row:AddChildToHorizontalBox(selectBtn)

            listVBox:AddChild(row)
            table.insert(materialRows, { row = row, category = mat.category })
        end
    end

    -- Rebuild: filter + reset to page 1 (category changed)
    rebuildMaterialList = function()
        rebuildFilteredList()
        currentPage = 1
        savedPage = 1
        renderPage()
    end

    -- Initial build: restore saved category + page
    rebuildFilteredList()
    updateCategoryButtonOpacity()
    renderPage()
    return root
end

-- ============================================================
-- Open / Close / IsOpen
-- ============================================================

function ui.open(onApply, onSelect)
    if isOpen then return end

    onApplyCallback = onApply
    onSelectCallback = onSelect

    loadFavourites()  -- refresh in case file was edited
    local root = buildUI(onApply, onSelect)
    if not root then
        print("[PaintBrush] ui.open: buildUI failed\n")
        return
    end

    rootWidget = root
    root:AddToViewport(200)

    -- Switch to UI-only input
    local pc = UEHelpers:GetPlayerController()
    if pc then
        pcall(function()
            classes.wbLib:SetInputMode_UIOnlyEx(pc, root, 0, true)
            pc.bShowMouseCursor = true
        end)
    end

    -- Push modal blocker for ESC close
    pcall(function()
        local modalCls = StaticFindObject("/Script/UWECommonUI.ModalActivatableWidget")
        local wm = FindFirstOf("WindowManager")
        if wm and modalCls then
            modalBlocker = wm:PushToLayer(3, modalCls)
        end
    end)

    isOpen = true
    print("[PaintBrush] ui.open: material picker opened\n")
end

function ui.close()
    if not isOpen then return end

    -- Pop modal blocker
    if modalBlocker then
        pcall(function()
            local wm = FindFirstOf("WindowManager")
            if wm then wm:Pop(modalBlocker) end
        end)
        modalBlocker = nil
    end

    -- Remove root widget
    if rootWidget then
        pcall(function() rootWidget:RemoveFromViewport() end)
        rootWidget = nil
    end

    -- Restore game input
    local pc = UEHelpers:GetPlayerController()
    if pc then
        pcall(function()
            classes.wbLib:SetInputMode_GameOnly(pc, true)
            pc.bShowMouseCursor = false
        end)
    end

    -- Clear button actions to avoid stale references
    buttonActions = {}
    categoryButtons = {}
    materialRows = {}
    onSelectCallback = nil

    isOpen = false
    print("[PaintBrush] ui.close: material picker closed\n")
end

function ui.isOpen()
    return isOpen
end

function ui.getBrushRadius()
    return BRUSH_SIZES[activeBrushIdx].radius
end

function ui.isEraserMode()
    return eraserActive
end

function ui.setSelectedMaterial(path)
    selectedMaterialPath = path
end

-- ============================================================
-- ESC keybind for closing
-- ============================================================

RegisterKeyBind(Key.ESCAPE, function()
    if isOpen then
        ExecuteInGameThread(function()
            ui.close()
        end)
    end
end)

return ui
