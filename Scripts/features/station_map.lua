-- Eqol Feature: Interactive Gridded Station Map
-- Accessible via configurable keybind (default N).
-- Features:
--   - Gridded 2D top-down view (1 cell = 1x1 machine / 100cm conveyor belt)
--   - Station floors matching total elevator stack height, with tall vertical paginated floor selector (^ / 5..1 / v)
--   - Tier-shaded type-colored machine rectangles with 2D build-menu asset icons
--   - Containers display contained items; Producers display output items & rates/min (clickable toggles)
--   - Hover tooltip showing conveyor belt carried items on mouse hover
--   - Hold-click box select, Shift+Click multi-select, Ctrl+C / Copy -> repeatable multi-ghost Paste (right-click cancels)
--   - Press B to pick a machine and place cursor ghost(s) directly on the map, with bottom-right Apply Changes button

local Core = require("core")
local StationData = require("station_data")

local Feature = {
    Name        = "StationMap",
    DisplayName = "Interactive Station Map",
    Description = "Hotkey (default N) for the 2D gridded station map with copy/paste, delete, and building.",
}

local PATHS = {
    WindowBaseClass   = "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C",
    WBPButtonClass    = "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C",
    WBPTextClass      = "/Game/Blueprints/Widgets/Basic/WBP_Text.WBP_Text_C",
    WBPItemClass      = "/Game/Blueprints/Widgets/Display/Inventory/WBP_Item.WBP_Item_C",
    InputKeyClass     = "/Game/Blueprints/Widgets/Display/WBP_InputKey.WBP_InputKey_C",
    BuildingMenuClass = "/Game/Blueprints/Widgets/Menus/WBP_Building.WBP_Building_C",
    CanvasPanelClass  = "/Script/UMG.CanvasPanel",
    ImageClass        = "/Script/UMG.Image",
    BorderClass       = "/Script/UMG.Border",
    SizeBoxClass      = "/Script/UMG.SizeBox",
    OverlayClass      = "/Script/UMG.Overlay",
    ScrollBoxClass    = "/Script/UMG.ScrollBox",
    SpacerClass       = "/Script/UMG.Spacer",
    VerticalBoxClass  = "/Script/UMG.VerticalBox",
    HorizontalBoxClass= "/Script/UMG.HorizontalBox",
    WidgetLayoutLibCDO= "/Script/UMG.Default__WidgetLayoutLibrary",
    SlateLibCDO       = "/Script/UMG.Default__SlateBlueprintLibrary",
}

local CELL_CM = 100.0
local BASE_CELL_PX = 48.0
local BASE_PX_PER_CM = BASE_CELL_PX / CELL_CM
local FLOOR_PAGE_SIZE = 7
local DEFAULT_CANVAS_W = 1060.0
local DEFAULT_CANVAS_H = 740.0

local COLORS = {
    WindowBg      = { R = 0.006, G = 0.006, B = 0.006, A = 1.00 }, -- ~#121212 in sRGB
    GridLine      = { R = 0.240, G = 0.300, B = 0.380, A = 0.28 },
    GridMajor     = { R = 0.340, G = 0.430, B = 0.540, A = 0.48 },
    ModuleFill    = { R = 0.026, G = 0.036, B = 0.050, A = 0.95 },
    ModuleBorder  = { R = 0.720, G = 0.800, B = 0.900, A = 0.96 },
    Assembler     = { R = 0.150, G = 0.560, B = 0.760, A = 0.92 },
    Container     = { R = 0.780, G = 0.560, B = 0.140, A = 0.92 },
    Conveyor      = { R = 0.290, G = 0.360, B = 0.440, A = 0.90 },
    OtherMachine  = { R = 0.240, G = 0.300, B = 0.380, A = 0.90 },
    DirChevron    = { R = 0.920, G = 0.850, B = 0.450, A = 0.85 },
    Selected      = { R = 0.980, G = 0.650, B = 0.100, A = 0.95 },
    SelectedFill  = { R = 0.980, G = 0.650, B = 0.100, A = 0.22 },
    BoxSelectLine = { R = 0.350, G = 0.920, B = 0.550, A = 0.95 },
    BoxSelectFill = { R = 0.350, G = 0.920, B = 0.550, A = 0.18 },
    GhostValid    = { R = 0.450, G = 0.900, B = 1.000, A = 0.58 },
    GhostInvalid  = { R = 1.000, G = 0.320, B = 0.320, A = 0.58 },
    GhostBorderOk = { R = 0.350, G = 0.920, B = 0.650, A = 0.90 },
    GhostBorderBad= { R = 1.000, G = 0.300, B = 0.300, A = 0.90 },
    WallFill      = { R = 0.013, G = 0.017, B = 0.023, A = 1.00 },
    WallBorder    = { R = 0.860, G = 0.910, B = 0.970, A = 0.92 },
    FloorRailBg   = { R = 0.045, G = 0.060, B = 0.082, A = 0.95 },
    FloorSelected = { R = 0.940, G = 0.620, B = 0.080, A = 1.00 },
    FloorNormal   = { R = 0.120, G = 0.155, B = 0.205, A = 0.90 },
    TooltipBg     = { R = 0.035, G = 0.048, B = 0.068, A = 0.96 },
    TooltipBorder = { R = 0.480, G = 0.640, B = 0.820, A = 0.95 },
    PlayerLocal   = { R = 0.960, G = 0.970, B = 1.000, A = 1.00 },
    PlayerOnline  = { R = 0.250, G = 0.880, B = 0.380, A = 1.00 },
    PlayerOffline = { R = 0.650, G = 0.280, B = 0.280, A = 0.92 },
    Transparent   = { R = 0.0,   G = 0.0,   B = 0.0,   A = 0.0  },
}

-- UI & Map State
local MapHudInjected = {}
local ActiveMapWin = nil
local MapWinVisible = false
local MapWinInViewport = false
local MapUI = nil
local CachedBorderCls = nil
local CachedWidgetClasses = {}
local function CreateRawFast(path, outer)
    local cls = CachedWidgetClasses[path]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(path)
        CachedWidgetClasses[path] = cls
    end
    if not Core.IsValidObj(cls) or not Core.IsValidObj(outer) then return nil end
    local ok, w = pcall(StaticConstructObject, cls, outer)
    if ok and Core.IsValidObj(w) then return w end
    return nil
end

local CanvasRenderGen = 0
local MachineRenderGen = 0
local RenderedMachineWidgets = {} -- mAddr -> { widgets = {}, portWidgets = {}, cancelled = false }
local PlayerMarkerWidgets = {}
local SyncFloorMachinesIncremental = nil
local RevalidatePendingChanges = nil
local RefreshSingleMachineVisual = nil
local RefreshPlayerMarkers = nil
local BuildGridDivisor = 50.0
local BuildHeightDivisor = 50.0
local GridCalibrated = false
local PrewarmScheduledForWorld = nil

local ALIGN_CENTER = { X = 0.5, Y = 0.5 }
local function AddBorderFast(outer, canvas, x, y, w, h, col, zOrder)
    if not Core.IsValidObj(CachedBorderCls) then
        CachedBorderCls = Core.FindOrLoadClass(PATHS.BorderClass)
    end
    if not Core.IsValidObj(CachedBorderCls) or not Core.IsValidObj(outer) then return nil, nil end
    local ok, b = pcall(StaticConstructObject, CachedBorderCls, outer)
    if not ok or not Core.IsValidObj(b) then return nil, nil end
    b:SetVisibility(3)
    b:SetBrushColor(col)
    local s = canvas:AddChildToCanvas(b)
    if Core.IsValidObj(s) then
        s:SetPosition({ X = x, Y = y })
        s:SetSize({ X = w, Y = h })
        s:SetAlignment(ALIGN_CENTER)
        if zOrder then s:SetZOrder(zOrder) end
    end
    return b, s
end

local function IsMapOpen()
    return MapWinVisible and Core.IsValidObj(ActiveMapWin)
end

local CurrentStation = nil
local CurrentWalkFrame = nil
local CurrentFrameXform = nil
local CurrentFloors = {}
local SelectedFloorIdx = 1
local FloorPageTopIdx = nil -- highest floor index currently shown in the 5-slot floor bar

local ViewTransform = {
    cx = 0.0,
    cy = 0.0,
    scale = 0.24,
    canvasW = DEFAULT_CANVAS_W,
    canvasH = DEFAULT_CANVAS_H,
    gridOriginX = 0.0,
    gridOriginY = 0.0,
    floorZ = 0.0,
    hasFitted = false,
}

-- Rendered Floor Cache (for fast hit-testing, box select, and hover without rebuilding widgets)
local RenderedMachines = {}  -- list of { machine, x, y, z, yaw, cellsX, cellsY, halfW, halfH, cat, buildable, recipe, actorClsPath, displayName }
local RenderedConveyors = {} -- subset of RenderedMachines where cat == "Conveyor"
local RenderedPorts = {}     -- unconnected item ports: { idx, x, y, halfW, halfH, isInput, isOutput, machineName }

-- Consolidated performance state & helpers (single local table to stay well under Lua's 200-local limit)
local Perf = {
    RT = require("station_map_rt"),
    ActiveRT = nil,
    FloorRTCache = {},          -- floorIdx -> cached RT floor state for instant <1ms floor switching
    FloorRTCacheStation = nil,  -- station address string owning FloorRTCache
    MachineGrid = {}, -- "gx,gy" -> { recEntry, ... } (400cm spatial hash for O(1) hover & overlap)
    PortGrid = {},    -- "gx,gy" -> { portEntry, ... } (400cm spatial hash for O(1) hover)
    HOVER_CELL_CM = 400.0,
    LastIconCanvasVisible = nil,
    MapKeys = nil,
}

function Perf.DestroyFloorRT(floorIdx)
    local entry = Perf.FloorRTCache[floorIdx]
    if entry then
        if entry.rtFloor then
            if Perf.ActiveRT == entry.rtFloor then Perf.ActiveRT = nil end
            pcall(function() entry.rtFloor.Destroy() end)
        end
        Perf.FloorRTCache[floorIdx] = nil
    end
end

function Perf.DestroyActiveRT()
    Perf.LastPendingSig = nil
    for idx, entry in pairs(Perf.FloorRTCache) do
        if entry and entry.rtFloor then
            pcall(function() entry.rtFloor.Destroy() end)
        end
        Perf.FloorRTCache[idx] = nil
    end
    Perf.FloorRTCacheStation = nil
    if Perf.ActiveRT then
        pcall(function() Perf.ActiveRT.Destroy() end)
        Perf.ActiveRT = nil
    end
end

function Perf.GridBucketKey(gx, gy)
    return gx .. "," .. gy
end

function Perf.InsertMachineRect(recEntry, cx, cy)
    local cell = Perf.HOVER_CELL_CM
    local minX = math.floor((cx - recEntry.halfW) / cell)
    local maxX = math.floor((cx + recEntry.halfW) / cell)
    local minY = math.floor((cy - recEntry.halfH) / cell)
    local maxY = math.floor((cy + recEntry.halfH) / cell)
    local keys = recEntry._gridKeys or {}
    local seen = {}
    for i = 1, #keys do seen[keys[i]] = true end
    for gx = minX, maxX do
        for gy = minY, maxY do
            local k = Perf.GridBucketKey(gx, gy)
            if not seen[k] then
                seen[k] = true
                local b = Perf.MachineGrid[k]
                if not b then b = {}; Perf.MachineGrid[k] = b end
                b[#b + 1] = recEntry
                keys[#keys + 1] = k
            end
        end
    end
    recEntry._gridKeys = keys
end

function Perf.InsertMachine(recEntry)
    Perf.InsertMachineRect(recEntry, recEntry.x, recEntry.y)
end

function Perf.QueryMachinesInRect(minWX, maxWX, minWY, maxWY, outList, seenAddr)
    local cell = Perf.HOVER_CELL_CM
    local minX = math.floor(minWX / cell)
    local maxX = math.floor(maxWX / cell)
    local minY = math.floor(minWY / cell)
    local maxY = math.floor(maxWY / cell)
    for gx = minX, maxX do
        for gy = minY, maxY do
            local b = Perf.MachineGrid[Perf.GridBucketKey(gx, gy)]
            if b then
                for i = 1, #b do
                    local rm = b[i]
                    if not seenAddr[rm.addr] then
                        seenAddr[rm.addr] = true
                        outList[#outList + 1] = rm
                    end
                end
            end
        end
    end
end

function Perf.RemoveMachine(recEntry)
    if not recEntry or not recEntry._gridKeys then return end
    for _, k in ipairs(recEntry._gridKeys) do
        local b = Perf.MachineGrid[k]
        if b then
            for i = #b, 1, -1 do
                if b[i] == recEntry then table.remove(b, i) end
            end
            if #b == 0 then Perf.MachineGrid[k] = nil end
        end
    end
    recEntry._gridKeys = nil
end

function Perf.InsertPort(pe)
    local cell = Perf.HOVER_CELL_CM
    local minX = math.floor((pe.x - pe.halfW) / cell)
    local maxX = math.floor((pe.x + pe.halfW) / cell)
    local minY = math.floor((pe.y - pe.halfH) / cell)
    local maxY = math.floor((pe.y + pe.halfH) / cell)
    local keys = {}
    for gx = minX, maxX do
        for gy = minY, maxY do
            local k = Perf.GridBucketKey(gx, gy)
            local b = Perf.PortGrid[k]
            if not b then b = {}; Perf.PortGrid[k] = b end
            b[#b + 1] = pe
            keys[#keys + 1] = k
        end
    end
    pe._gridKeys = keys
end

function Perf.RemovePort(pe)
    if not pe or not pe._gridKeys then return end
    for _, k in ipairs(pe._gridKeys) do
        local b = Perf.PortGrid[k]
        if b then
            for i = #b, 1, -1 do
                if b[i] == pe then table.remove(b, i) end
            end
            if #b == 0 then Perf.PortGrid[k] = nil end
        end
    end
    pe._gridKeys = nil
end

function Perf.FindHoveredPortAt(wx, wy)
    local cell = Perf.HOVER_CELL_CM
    local b = Perf.PortGrid[Perf.GridBucketKey(math.floor(wx / cell), math.floor(wy / cell))]
    if not b then return nil end
    for i = 1, #b do
        local rp = b[i]
        if math.abs(wx - rp.x) <= rp.halfW and math.abs(wy - rp.y) <= rp.halfH then
            return rp
        end
    end
    return nil
end

function Perf.FindHoveredMachineAt(wx, wy)
    local cell = Perf.HOVER_CELL_CM
    local b = Perf.MachineGrid[Perf.GridBucketKey(math.floor(wx / cell), math.floor(wy / cell))]
    if not b then return nil end
    local bestD2 = math.huge
    local best = nil
    for i = 1, #b do
        local rm = b[i]
        if math.abs(wx - rm.x) <= rm.halfW and math.abs(wy - rm.y) <= rm.halfH then
            local d2 = (wx - rm.x) ^ 2 + (wy - rm.y) ^ 2
            if d2 < bestD2 then
                bestD2 = d2
                best = rm
            end
        end
    end
    return best
end

function Perf.EnsureMapKeys()
    if Perf.MapKeys then return end
    Perf.MapKeys = {}
    local names = {
        LMB = "LeftMouseButton", RMB = "RightMouseButton", MMB = "MiddleMouseButton",
        LShift = "LeftShift", RShift = "RightShift", Space = "SpaceBar",
        W = "W", Up = "Up", S = "S", Down = "Down",
        A = "A", Left = "Left", D = "D", Right = "Right",
        Equals = "Equals", Add = "Add", Hyphen = "Hyphen", Subtract = "Subtract",
        WheelUp = "MouseScrollUp", WheelDown = "MouseScrollDown", WheelAxis = "MouseWheelAxis",
    }
    for k, n in pairs(names) do
        pcall(function() Perf.MapKeys[k] = { KeyName = FName(n) } end)
    end
end
local RenderedGridLines = {} -- { border, slot, isVertical, spanOther, isMajor4, isMajor8 }
local LastGridTier = nil
local LastGridZoomRatio = nil
local FloorIconButtons = {}  -- mAddr -> { btn, widget }
local FloorRailButtons = {}  -- list of WBP_Button_C instances in floor selector
local TrackedButtons = {}    -- list of static WBP_Button_C instances for hover check
local IconDiagLogged = false
local MissingIconsLogged = {}
local CursorDiagLogged = false
local LastHoveredConvAddr = nil
local LastHoveredMachineAddr = nil
local LastHoveredPortIdx = nil
local LastHadDynamicOverlay = false

-- Selection, Ghosts, Deletes & Clipboard State
local SelectedMachines = {}  -- mAddr -> entry
local SelectedGhosts = {}    -- ghostId -> gp
local NextGhostSeq = 0
local PendingDeletes = {}    -- mAddr -> entry (proposed deletions applied on Apply Changes)
local Clipboard = {}         -- { { buildable, dx, dy, yaw, cat, recipe, machineConfig, cellsX, cellsY, actorClsPath, name, pairGroupId, isUndergroundInput }, ... }
local ClipboardGen = 0
local GhostPreviewSig = nil
local InputCmdSigCache = {}
local DisassembleSigCache = nil
local MachineConfigDiagLogged = {}
local PendingGhosts = {}     -- { { buildable, x, y, z, yaw, cat, cellsX, cellsY, actorClsPath, recipe, machineConfig, name, pairGroupId, isUndergroundInput }, ... }
local InteractionMode = "Select" -- "Select" | "Place" | "Paste"
local PendingBuildable = nil
local PendingRotationDeg = 0
local WaitingForBuildMenuSelection = false
local WaitingBuildMenuSince = 0
local KeyHandlersBound = false
local LastWorldAddr = nil
local SavedCharInputEnabled = nil

-- Input Polling State
local InputPollActive = false
local MouseState = {
    wasLDown = false,
    wasRDown = false,
    lDownInMap = false,
    lDraggingBox = false,
    lStartX = 0, lStartY = 0,
    rDownInMap = false,
    rPanning = false,
    rStartX = 0, rStartY = 0,
    panStartCx = 0, panStartCy = 0,
    lastCursorMx = nil, lastCursorMy = nil,
}

-- Cached 2D Visual Styles per machine class (cached across opens in same world)
local MachineSpriteCache = {} -- clsKey -> { tex, bgCol, borderCol, typeKey, tier, directional }

-- Forward declarations
local RefreshStationMapCanvas
local RebuildFloorButtons
local RefreshDynamicOverlay
local UpdateActionBar
local UpdateStatusBanner
local CloseStationMap

--------------------------------------------------------------------------------
-- Geometry, Transform & Helpers
--------------------------------------------------------------------------------

local function GetCurrentWorldAddr()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return nil end
    local okW, w = pcall(function() return pc:GetWorld() end)
    if okW and Core.IsValidObj(w) then
        return w:GetAddress()
    end
    return nil
end

local function SafeFNameStr(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, s = pcall(function() return obj:GetFName():ToString() end)
    if ok and type(s) == "string" and s ~= "" then return s end
    return nil
end

local function SafeFullPath(obj)
    if not Core.IsValidObj(obj) then return nil end
    local ok, full = pcall(function() return obj:GetFullName() end)
    if ok and type(full) == "string" and full ~= "" then
        return full:match("^%S+ (.+)$") or full
    end
    return nil
end

local function SetCanvasSlot(slot, x, y, w, h, alignX, alignY, zOrder)
    if not Core.IsValidObj(slot) then return end
    pcall(function()
        slot:SetPosition({ X = x, Y = y })
        slot:SetSize({ X = w, Y = h })
        slot:SetAlignment({ X = alignX or 0.5, Y = alignY or 0.5 })
        if zOrder then slot:SetZOrder(zOrder) end
    end)
end

local function WorldToCanvas(wx, wy)
    local mx = ViewTransform.canvasW * 0.5 + (wx - ViewTransform.cx) * ViewTransform.scale
    local my = ViewTransform.canvasH * 0.5 + (wy - ViewTransform.cy) * ViewTransform.scale
    return mx, my
end

local function WorldToBaseCanvas(wx, wy)
    return wx * BASE_PX_PER_CM, wy * BASE_PX_PER_CM
end

local function UpdateGridAppearanceForZoom(zoomRatio)
    if #RenderedGridLines == 0 or not zoomRatio or zoomRatio <= 0.001 then return end
    local screenCellPx = CELL_CM * ViewTransform.scale
    local tier = (screenCellPx >= 10.0) and 1 or ((screenCellPx >= 3.8) and 2 or 3)
    local tierChanged = (tier ~= LastGridTier)
    local ratioChanged = (not LastGridZoomRatio) or (math.abs(zoomRatio - LastGridZoomRatio) / math.max(0.01, LastGridZoomRatio) > 0.08)
    if not tierChanged and not ratioChanged then return end

    LastGridTier = tier
    LastGridZoomRatio = zoomRatio

    local minorThick = math.max(1.05, 1.1) / zoomRatio
    local majorThick = math.max(1.55, 1.7) / zoomRatio

    for _, gl in ipairs(RenderedGridLines) do
        local show
        if tier == 1 then
            show = true
        elseif tier == 2 then
            show = gl.isMajor4
        else
            show = gl.isMajor8
        end
        if Core.IsValidObj(gl.border) then
            if tierChanged then
                pcall(function() gl.border:SetVisibility(show and 3 or 1) end)
            end
            if show and Core.IsValidObj(gl.slot) then
                local isEmph = (tier == 1 and gl.isMajor4) or (tier >= 2 and gl.isMajor8)
                local thick = isEmph and majorThick or minorThick
                pcall(function()
                    if gl.isVertical then
                        gl.slot:SetSize({ X = thick, Y = gl.spanOther })
                    else
                        gl.slot:SetSize({ X = gl.spanOther, Y = thick })
                    end
                end)
            end
        end
    end
end

local OnViewportChangedStatic = nil
local OnViewportChangedMachines = nil

local function ApplyViewTransform()
    if not MapUI then return end
    local zoomRatio = ViewTransform.scale / BASE_PX_PER_CM
    local tx = ViewTransform.canvasW * 0.5 - ViewTransform.cx * ViewTransform.scale
    local ty = ViewTransform.canvasH * 0.5 - ViewTransform.cy * ViewTransform.scale
    local pivot = { X = 0.0, Y = 0.0 }
    local sc = { X = zoomRatio, Y = zoomRatio }
    local tr = { X = tx, Y = ty }
    for _, p in ipairs({ MapUI.BgPanZoom, MapUI.IconPanZoom }) do
        if Core.IsValidObj(p) then
            pcall(function()
                p:SetRenderTransformPivot(pivot)
                p:SetRenderScale(sc)
                p:SetRenderTranslation(tr)
            end)
        end
    end
    UpdateGridAppearanceForZoom(zoomRatio)
    if Core.IsValidObj(MapUI.IconCanvas) then
        local showIcons = (CELL_CM * ViewTransform.scale) >= 12.0
        if Perf.LastIconCanvasVisible ~= showIcons then
            Perf.LastIconCanvasVisible = showIcons
            pcall(function() MapUI.IconCanvas:SetVisibility(showIcons and 4 or 1) end)
        end
    end
    if OnViewportChangedStatic then OnViewportChangedStatic() end
    if OnViewportChangedMachines then OnViewportChangedMachines() end
end

local function CanvasToWorld(mx, my)
    local wx = ViewTransform.cx + (mx - ViewTransform.canvasW * 0.5) / ViewTransform.scale
    local wy = ViewTransform.cy + (my - ViewTransform.canvasH * 0.5) / ViewTransform.scale
    return wx, wy
end

local function GetRotatedCellDims(cellsX, cellsY, yawDeg)
    local norm = (math.floor((yawDeg or 0) / 90.0 + 0.5) % 4 + 4) % 4
    if norm == 1 or norm == 3 then
        return cellsY, cellsX
    end
    return cellsX, cellsY
end

local function SnapAxisToCellGrid(val, origin, cellSpan)
    local offset = val - origin
    if (cellSpan % 2) == 1 then
        return origin + (math.floor(offset / CELL_CM) + 0.5) * CELL_CM
    else
        return origin + math.floor(offset / CELL_CM + 0.5) * CELL_CM
    end
end

local function SnapWorldToMachineGrid(wx, wy, cellsX, cellsY, yawDeg)
    local rx, ry = GetRotatedCellDims(cellsX or 1, cellsY or 1, yawDeg or 0)
    local sx = SnapAxisToCellGrid(wx, ViewTransform.gridOriginX, rx)
    local sy = SnapAxisToCellGrid(wy, ViewTransform.gridOriginY, ry)
    return sx, sy
end

local function IsPointOverAnyFloorModule(wx, wy, floor)
    if not floor or not floor.platforms then return false end
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if math.abs(wx - b.cx) <= (b.ex + 10.0) and math.abs(wy - b.cy) <= (b.ey + 10.0) then
            return true, pe
        end
    end
    return false, nil
end

local function IsFootprintBlockedByWall(sx, sy, cellsX, cellsY, yawDeg, floor)
    if not floor or not floor.walls or #floor.walls == 0 then return false end
    local rx, ry = GetRotatedCellDims(cellsX or 1, cellsY or 1, yawDeg or 0)
    local halfW = math.max(10.0, rx * CELL_CM * 0.5 - 6.0)
    local halfH = math.max(10.0, ry * CELL_CM * 0.5 - 6.0)
    local minX, maxX = sx - halfW, sx + halfW
    local minY, maxY = sy - halfH, sy + halfH
    for _, w in ipairs(floor.walls) do
        if maxX > w.minX and minX < w.maxX and maxY > w.minY and minY < w.maxY then
            return true
        end
    end
    return false
end

local function FindPlatformAtWorldXY(wx, wy, floor)
    if not floor or not floor.platforms then return nil, nil end
    local bestPlat, bestBounds = nil, nil
    local bestDist = math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        local dx = math.abs(wx - b.cx)
        local dy = math.abs(wy - b.cy)
        if dx <= b.ex and dy <= b.ey then
            return pe.platform, b
        end
        local d2 = dx * dx + dy * dy
        if d2 < bestDist then
            bestDist = d2
            bestPlat = pe.platform
            bestBounds = b
        end
    end
    return bestPlat, bestBounds
end

local function GetMachineClassKey(machine, buildableOpt)
    local actor = Core.IsValidObj(machine) and StationData.GetObjectActor(machine) or nil
    if Core.IsValidObj(actor) then
        local okC, cls = pcall(function() return actor:GetClass() end)
        if okC and Core.IsValidObj(cls) then
            local p = SafeFullPath(cls)
            if p then return p, actor, cls end
        end
    end
    if Core.IsValidObj(buildableOpt) then
        local okAC, aCls = pcall(function() return buildableOpt.ActorClass or buildableOpt.PreviewClass or buildableOpt.BlockClass end)
        if okAC and Core.IsValidObj(aCls) then
            local p = SafeFullPath(aCls)
            if p then return p, nil, aCls end
        end
        local bp = SafeFullPath(buildableOpt)
        if bp then return "bld:" .. bp, nil, nil end
    end
    if Core.IsValidObj(machine) then
        local okC, cls = pcall(function() return machine:GetClass() end)
        if okC and Core.IsValidObj(cls) then
            local p = SafeFullPath(cls)
            if p then return "sim:" .. p, nil, nil end
        end
    end
    return nil, nil, nil
end

local function GetColorForMachine(cat)
    if cat == "Assembler" then return COLORS.Assembler
    elseif cat == "Container" then return COLORS.Container
    elseif cat == "Conveyor" then return COLORS.Conveyor
    else return COLORS.OtherMachine end
end

local function IsMajorNonConveyorMachine(machine, cat)
    if cat == "Assembler" or cat == "Container" then
        return true
    end
    if Core.IsValidObj(machine) then
        local okHas = false
        pcall(function()
            if machine.Recipe ~= nil or machine.GetInventory ~= nil or machine.Inventory ~= nil then
                okHas = true
            end
        end)
        if okHas and cat ~= "Conveyor" then
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- 2D Machine Visuals, Type Colors & Tier Shading
--------------------------------------------------------------------------------

local TYPE_BASE_COLORS = {
    { pat = "assembler",   col = { R = 0.24, G = 0.62, B = 0.92 } }, -- Light Blue -> Dark Blue by tier
    { pat = "smelter",     col = { R = 0.90, G = 0.45, B = 0.16 } }, -- Orange
    { pat = "furnace",     col = { R = 0.90, G = 0.45, B = 0.16 } },
    { pat = "refinery",    col = { R = 0.88, G = 0.68, B = 0.16 } }, -- Gold-Amber
    { pat = "chemical",    col = { R = 0.84, G = 0.72, B = 0.18 } },
    { pat = "fabricator",  col = { R = 0.16, G = 0.76, B = 0.68 } }, -- Teal
    { pat = "constructor", col = { R = 0.16, G = 0.76, B = 0.68 } },
    { pat = "foundry",     col = { R = 0.86, G = 0.36, B = 0.22 } },
    { pat = "container",   col = { R = 0.46, G = 0.32, B = 0.80 } }, -- Violet-Purple
    { pat = "chest",       col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "storage",     col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "warehouse",   col = { R = 0.46, G = 0.32, B = 0.80 } },
    { pat = "splitter",    col = { R = 0.78, G = 0.30, B = 0.62 } }, -- Magenta
    { pat = "balancer",    col = { R = 0.78, G = 0.30, B = 0.62 } },
    { pat = "merger",      col = { R = 0.78, G = 0.30, B = 0.62 } },
    { pat = "underground", col = { R = 0.34, G = 0.40, B = 0.82 } }, -- Indigo
    { pat = "conveyor",    col = { R = 0.36, G = 0.46, B = 0.58 } }, -- Cool Steel-Slate
    { pat = "belt",        col = { R = 0.36, G = 0.46, B = 0.58 } },
    { pat = "elevator",    col = { R = 0.20, G = 0.72, B = 0.42 } }, -- Emerald Green
    { pat = "miner",       col = { R = 0.24, G = 0.50, B = 0.84 } }, -- Cobalt
    { pat = "drone",       col = { R = 0.24, G = 0.50, B = 0.84 } },
    { pat = "extractor",   col = { R = 0.24, G = 0.50, B = 0.84 } },
    { pat = "turret",      col = { R = 0.82, G = 0.24, B = 0.26 } }, -- Crimson
    { pat = "reactor",     col = { R = 0.54, G = 0.80, B = 0.20 } }, -- Lime Green
    { pat = "generator",   col = { R = 0.54, G = 0.80, B = 0.20 } },
    { pat = "solar",       col = { R = 0.74, G = 0.78, B = 0.18 } },
    { pat = "battery",     col = { R = 0.42, G = 0.76, B = 0.28 } },
    { pat = "dock",        col = { R = 0.62, G = 0.36, B = 0.52 } }, -- Plum
    { pat = "shipyard",    col = { R = 0.62, G = 0.36, B = 0.52 } },
}

local function HsvToRgb(h, s, v)
    local c = v * s
    local hh = (h % 360.0) / 60.0
    local x = c * (1.0 - math.abs((hh % 2.0) - 1.0))
    local m = v - c
    local r, g, b = 0, 0, 0
    if hh < 1.0 then r, g, b = c, x, 0
    elseif hh < 2.0 then r, g, b = x, c, 0
    elseif hh < 3.0 then r, g, b = 0, c, x
    elseif hh < 4.0 then r, g, b = 0, x, c
    elseif hh < 5.0 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return { R = r + m, G = g + m, B = b + m }
end

local function ComputeBaseColorForType(typeKey)
    for _, rule in ipairs(TYPE_BASE_COLORS) do
        if typeKey:find(rule.pat, 1, true) then
            return rule.col
        end
    end
    local hash = 0
    for i = 1, #typeKey do
        hash = (hash * 37 + string.byte(typeKey, i)) % 360
    end
    return HsvToRgb(hash, 0.62, 0.80)
end

local function GetShadedColorForTypeAndTier(typeKey, tier)
    local base = ComputeBaseColorForType(typeKey or "machine")
    local mult = 1.0
    if tier == 2 then mult = 0.68
    elseif tier == 3 then mult = 0.46
    elseif tier >= 4 then mult = math.max(0.28, 0.46 * (0.72 ^ (tier - 3))) end
    return {
        R = base.R * mult,
        G = base.G * mult,
        B = base.B * mult,
        A = 0.94,
    }, {
        R = math.max(0.05, base.R * mult * 0.52),
        G = math.max(0.05, base.G * mult * 0.52),
        B = math.max(0.05, base.B * mult * 0.52),
        A = 1.0,
    }
end

local function ResetSpriteCache()
    MachineSpriteCache = {}
    MissingIconsLogged = {}
    IconDiagLogged = false
end

local function IsFiniteNum(v)
    return type(v) == "number" and v == v and v > -1e9 and v < 1e9
end

local function RequestMachineSprite(clsKey, machine, cat, buildableOpt)
    if clsKey and MachineSpriteCache[clsKey] then
        return MachineSpriteCache[clsKey]
    end

    local typeKey, tier, dispName = StationData.GetMachineTypeAndTier(machine, buildableOpt)
    local bgCol, borderCol = GetShadedColorForTypeAndTier(typeKey, tier)
    local tex = nil
    if cat ~= "Conveyor" then
        tex = StationData.GetBuildableIconTexture(machine, buildableOpt)
    end
    local directional = (cat == "Conveyor")
        or typeKey:find("conveyor", 1, true) ~= nil
        or typeKey:find("belt", 1, true) ~= nil
        or typeKey:find("splitter", 1, true) ~= nil
        or typeKey:find("balancer", 1, true) ~= nil
        or typeKey:find("merger", 1, true) ~= nil
        or typeKey:find("underground", 1, true) ~= nil

    if not IconDiagLogged and (Core.IsValidObj(machine) or Core.IsValidObj(buildableOpt)) then
        IconDiagLogged = true
        local bld = Core.IsValidObj(buildableOpt) and buildableOpt or (Core.IsValidObj(machine) and pcall(function() return machine.Buildable end) and machine.Buildable or nil)
        Core.Log(string.format("[StationMap] 2DIconSample type=%s tier=%d name=%s bldValid=%s texValid=%s",
            tostring(typeKey), tier, tostring(dispName), tostring(Core.IsValidObj(bld)), tostring(Core.IsValidObj(tex))))
    end
    if cat ~= "Conveyor" and not Core.IsValidObj(tex) and clsKey and not MissingIconsLogged[clsKey] then
        MissingIconsLogged[clsKey] = true
        local hasBld = Core.IsValidObj(buildableOpt) or (Core.IsValidObj(machine) and pcall(function() return Core.IsValidObj(machine.Buildable) end) and Core.IsValidObj(machine.Buildable))
        Core.Log(string.format("[StationMap] Missing2DIcon cls=%s type=%s tier=%d name=%s bldValid=%s",
            tostring(clsKey), tostring(typeKey), tier, tostring(dispName), tostring(hasBld)))
    end

    local entry = {
        tex = tex,
        bgCol = bgCol,
        borderCol = borderCol,
        typeKey = typeKey,
        tier = tier,
        directional = directional,
        fullTileTex = false,
    }
    if clsKey then
        MachineSpriteCache[clsKey] = entry
    end
    return entry
end

--------------------------------------------------------------------------------
-- Build Command & Inventory Helpers
--------------------------------------------------------------------------------

local CachedBuildCmdLayout = nil
local CachedAddBuildCmdLayout = nil
local BuildCmdSigLogged = false
local ApplyInProgress = false

local function InspectAddBuildCommandLayout()
    if CachedAddBuildCmdLayout ~= nil then
        return CachedAddBuildCmdLayout or nil
    end
    local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddBuildCommand")
    if not Core.IsValidObj(ufunc) then
        CachedAddBuildCmdLayout = false
        return nil
    end
    local info = { fields = {}, fieldStructs = {} }
    local parts = {}
    pcall(function()
        ufunc:ForEachProperty(function(p)
            local pn = p:GetFName():ToString()
            local pc2 = ""
            pcall(function() pc2 = p:GetClass():GetFName():ToString() end)
            if pn ~= "ReturnValue" and pc2 == "StructProperty" and p.GetStruct then
                local okS, st = pcall(function() return p:GetStruct() end)
                if okS and Core.IsValidObj(st) and st.ForEachProperty then
                    st:ForEachProperty(function(fp)
                        local fn = fp:GetFName():ToString()
                        local fc = ""
                        pcall(function() fc = fp:GetClass():GetFName():ToString() end)
                        info.fields[fn] = fc
                        local sub = ""
                        if fc == "StructProperty" and fp.GetStruct then
                            local okFS, fst = pcall(function() return fp:GetStruct() end)
                            if okFS and Core.IsValidObj(fst) then
                                pcall(function() sub = fst:GetFName():ToString() end)
                                if sub ~= "" then info.fieldStructs[fn] = sub end
                            end
                        end
                        table.insert(parts, fn .. ":" .. fc .. (sub ~= "" and ("(" .. sub .. ")") or ""))
                    end)
                end
            end
        end)
    end)
    Core.Log("[StationMap] AddBuildCmdInner: [" .. table.concat(parts, ", ") .. "]")
    CachedAddBuildCmdLayout = info
    return info
end

local function InspectBuildMachineCommandLayout()
    if CachedBuildCmdLayout ~= nil then
        return CachedBuildCmdLayout or nil
    end
    local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddBuildMachineCommand")
    if not Core.IsValidObj(ufunc) then
        CachedBuildCmdLayout = false
        if not BuildCmdSigLogged then
            BuildCmdSigLogged = true
            Core.Log("[StationMap] BuildCmdSig: AddBuildMachineCommand not found")
        end
        return nil
    end

    local layout = { params = {}, firstStructFields = nil, firstStructName = nil }
    local sigParts = {}
    pcall(function()
        ufunc:ForEachProperty(function(prop)
            local pName = prop:GetFName():ToString()
            local pCls = ""
            pcall(function() pCls = prop:GetClass():GetFName():ToString() end)
            local isRet = (pName == "ReturnValue")
            if not isRet then
                local pInfo = { name = pName, cls = pCls, structName = nil, fields = nil }
                if pCls == "StructProperty" and prop.GetStruct then
                    local okS, st = pcall(function() return prop:GetStruct() end)
                    if okS and Core.IsValidObj(st) then
                        pcall(function() pInfo.structName = st:GetFName():ToString() end)
                        if st.ForEachProperty then
                            local fMap = {}
                            local fStructMap = {}
                            local fList = {}
                            st:ForEachProperty(function(fp)
                                local fName = fp:GetFName():ToString()
                                local fCls = ""
                                pcall(function() fCls = fp:GetClass():GetFName():ToString() end)
                                fMap[fName] = fCls
                                local fSub = ""
                                if fCls == "StructProperty" and fp.GetStruct then
                                    local okFS, fst = pcall(function() return fp:GetStruct() end)
                                    if okFS and Core.IsValidObj(fst) then
                                        pcall(function() fSub = fst:GetFName():ToString() end)
                                        if fSub ~= "" then fStructMap[fName] = fSub end
                                    end
                                end
                                table.insert(fList, fName .. ":" .. fCls .. (fSub ~= "" and ("(" .. fSub .. ")") or ""))
                            end)
                            pInfo.fields = fMap
                            pInfo.fieldStructs = fStructMap
                            if not layout.firstStructFields then
                                layout.firstStructName = pName
                                layout.firstStructFields = fMap
                                layout.firstStructFieldTypes = fStructMap
                            end
                            table.insert(sigParts, string.format("%s(%s:%s{%s})", pName, pCls, tostring(pInfo.structName), table.concat(fList, ",")))
                        else
                            table.insert(sigParts, string.format("%s(%s:%s)", pName, pCls, tostring(pInfo.structName)))
                        end
                    else
                        table.insert(sigParts, string.format("%s(%s)", pName, pCls))
                    end
                else
                    table.insert(sigParts, string.format("%s(%s)", pName, pCls))
                end
                table.insert(layout.params, pInfo)
            end
        end)
    end)

    if not BuildCmdSigLogged then
        BuildCmdSigLogged = true
        Core.Log("[StationMap] BuildCmdSig: params(" .. #layout.params .. ")=[" .. table.concat(sigParts, "; ") .. "]")
        -- Also list all build/command-related UFunctions on DMSPlayerController & Builder for diagnostics
        local fnNames = {}
        pcall(function()
            local pc = Core.GetLocalPlayerController()
            local function scanFuncs(tag, obj)
                if not Core.IsValidObj(obj) then return end
                local c = obj:GetClass()
                local d = 0
                while Core.IsValidObj(c) and d < 5 do
                    d = d + 1
                    if c.ForEachFunction then
                        c:ForEachFunction(function(fn)
                            local n = fn:GetFName():ToString()
                            local low = n:lower()
                            if low:find("build", 1, true) or low:find("command", 1, true) or low:find("machine", 1, true) then
                                table.insert(fnNames, tag .. ":" .. n)
                            end
                        end)
                    end
                    c = c.GetSuperStruct and c:GetSuperStruct() or nil
                end
            end
            scanFuncs("PC", pc)
            if Core.IsValidObj(pc) and Core.IsValidObj(pc.Builder) then
                scanFuncs("Builder", pc.Builder)
            end
        end)
        Core.Log("[StationMap] BuildFuncs: " .. table.concat(fnNames, ", "))

        -- Also inspect AddBuildCommand & AddBlueprintBuildCommand signatures
        for _, altName in ipairs({ "AddBuildCommand", "AddBlueprintBuildCommand" }) do
            local afn = StaticFindObject("/Script/MainSequence.DMSPlayerController:" .. altName)
            if Core.IsValidObj(afn) then
                local aParts = {}
                pcall(function()
                    afn:ForEachProperty(function(p)
                        local pn = p:GetFName():ToString()
                        local pc2 = ""
                        pcall(function() pc2 = p:GetClass():GetFName():ToString() end)
                        if pn ~= "ReturnValue" then
                            local extra = ""
                            if pc2 == "StructProperty" and p.GetStruct then
                                local okS, st = pcall(function() return p:GetStruct() end)
                                if okS and Core.IsValidObj(st) then
                                    local sf = {}
                                    if st.ForEachProperty then
                                        st:ForEachProperty(function(fp)
                                            table.insert(sf, fp:GetFName():ToString() .. ":" .. fp:GetClass():GetFName():ToString())
                                        end)
                                    end
                                    extra = ":" .. st:GetFName():ToString() .. "{" .. table.concat(sf, ",") .. "}"
                                end
                            end
                            table.insert(aParts, pn .. "(" .. pc2 .. extra .. ")")
                        end
                    end)
                end)
                Core.Log("[StationMap] AltSig " .. altName .. ": [" .. table.concat(aParts, "; ") .. "]")
            end
        end

        -- Inspect a real placed machine on the current floor to see exact GridLocation / Height / PlatformID / Rotation units
        local refParts = {}
        pcall(function()
            local fl = CurrentFloors[SelectedFloorIdx] or CurrentFloors[1]
            local sampleM = nil
            if fl and fl.machines then
                for _, me in ipairs(fl.machines) do
                    if Core.IsValidObj(me.machine) and StationData.GetMachineCategory(me.machine) ~= "Conveyor" then
                        sampleM = me
                        break
                    end
                end
            end
            if sampleM and Core.IsValidObj(sampleM.machine) then
                local m = sampleM.machine
                table.insert(refParts, string.format("cls=%s local=(%.0f,%.0f,%.0f) yaw=%.0f",
                    m:GetClass():GetFName():ToString(), sampleM.x or 0, sampleM.y or 0, sampleM.z or 0, sampleM.yaw or 0))
                local c = m:GetClass()
                local d = 0
                local seenP = {}
                while Core.IsValidObj(c) and d < 6 do
                    d = d + 1
                    if c.ForEachProperty then
                        c:ForEachProperty(function(p)
                            local pn = p:GetFName():ToString()
                            if not seenP[pn] then
                                seenP[pn] = true
                                local low = pn:lower()
                                if low:find("grid", 1, true) or low:find("height", 1, true) or low:find("plat", 1, true)
                                    or low:find("rot", 1, true) or low:find("loc", 1, true) or low:find("config", 1, true)
                                    or low == "id" or low:find("frame", 1, true)
                                then
                                    local okV, val = pcall(function() return m[pn] end)
                                    if okV and val ~= nil then
                                        if type(val) == "number" or type(val) == "boolean" or type(val) == "string" then
                                            table.insert(refParts, pn .. "=" .. tostring(val))
                                        elseif type(val) == "userdata" then
                                            local okXY, vx, vy, vz = pcall(function()
                                                if val.X ~= nil and val.Y ~= nil then
                                                    local a, b, z = Core.GetFPVector(val)
                                                    return a, b, z
                                                end
                                                return nil
                                            end)
                                            if okXY and vx ~= nil then
                                                table.insert(refParts, string.format("%s=(%.1f,%.1f,%.1f)", pn, vx, vy, vz or 0))
                                            elseif Core.IsValidObj(val) then
                                                local okId, vid = pcall(function() return val.ID end)
                                                table.insert(refParts, string.format("%s=%s(id=%s)", pn, val:GetClass():GetFName():ToString(), tostring(okId and vid or "?")))
                                            end
                                        end
                                    end
                                end
                            end
                        end)
                    end
                    c = c.GetSuperStruct and c:GetSuperStruct() or nil
                end
                -- Inspect m.GridTransform struct fields & calibrate BuildGridDivisor / BuildHeightDivisor
                pcall(function()
                    local gt = m.GridTransform
                    if gt then
                        local gtParts = {}
                        local gtSt = Core.UnwrapStruct(gt) or gt
                        local gtStructObj = nil
                        pcall(function()
                            local mc = m:GetClass()
                            local md = 0
                            while Core.IsValidObj(mc) and md < 6 and not gtStructObj do
                                md = md + 1
                                if mc.ForEachProperty then
                                    mc:ForEachProperty(function(mp)
                                        if not gtStructObj and mp:GetFName():ToString() == "GridTransform" and mp.GetStruct then
                                            local okS, st = pcall(function() return mp:GetStruct() end)
                                            if okS and Core.IsValidObj(st) then gtStructObj = st end
                                        end
                                    end)
                                end
                                mc = mc.GetSuperStruct and mc:GetSuperStruct() or nil
                            end
                        end)
                        local function inspectGtField(fn)
                            local okF, fv = pcall(function() return gtSt[fn] end)
                            if not okF or fv == nil then return end
                            if type(fv) == "number" or type(fv) == "boolean" then
                                table.insert(gtParts, fn .. "=" .. tostring(fv))
                                local fl = fn:lower()
                                if (fl == "height" or fl == "z") and math.abs(sampleM.z or 0) >= 100.0 and math.abs(fv) > 0.01 then
                                    BuildHeightDivisor = math.abs((sampleM.z or 0) / fv)
                                    GridCalibrated = true
                                end
                            elseif type(fv) == "userdata" then
                                local okXY, gx0, gy0 = pcall(function()
                                    if fv.X ~= nil and fv.Y ~= nil then
                                        local ax = Core.GetFPFloat(fv.X)
                                        local ay = Core.GetFPFloat(fv.Y)
                                        return ax, ay
                                    end
                                    return nil
                                end)
                                if okXY and gx0 ~= nil then
                                    table.insert(gtParts, string.format("%s=(%.1f,%.1f)", fn, gx0, gy0))
                                    if math.abs(sampleM.x or 0) >= 100.0 and math.abs(gx0) > 0.01 then
                                        BuildGridDivisor = math.abs((sampleM.x or 0) / gx0)
                                        GridCalibrated = true
                                    elseif math.abs(sampleM.y or 0) >= 100.0 and math.abs(gy0) > 0.01 then
                                        BuildGridDivisor = math.abs((sampleM.y or 0) / gy0)
                                        GridCalibrated = true
                                    end
                                end
                            end
                        end
                        if Core.IsValidObj(gtStructObj) and gtStructObj.ForEachProperty then
                            gtStructObj:ForEachProperty(function(fp)
                                inspectGtField(fp:GetFName():ToString())
                            end)
                        else
                            for _, fn in ipairs({ "Location", "GridLocation", "Position", "Height", "Z", "Rotation", "Yaw", "PlatformID" }) do
                                inspectGtField(fn)
                            end
                        end
                        Core.Log(string.format("[StationMap] RefGridTransform: [%s] -> gridDiv=%.1f heightDiv=%.1f",
                            table.concat(gtParts, ", "), BuildGridDivisor, BuildHeightDivisor))
                    end
                end)
            end
        end)
        Core.Log("[StationMap] RefMachineProps: " .. table.concat(refParts, ", "))
    end

    CachedBuildCmdLayout = layout
    return layout
end

local function CollectBuildableCosts(buildable, mult, outCosts)
    if not Core.IsValidObj(buildable) then return end
    local m = mult or 1
    local function addCostArray(arr)
        if not arr then return false end
        local added = false
        StationData.ForEachArray(arr, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = (tonumber(st.Amount) or tonumber(st.Count) or 0) * m
                if amt > 0 then
                    local iAddr = st.Item:GetAddress()
                    local cur = outCosts[iAddr]
                    if cur then
                        cur.amount = cur.amount + amt
                    else
                        outCosts[iAddr] = { item = st.Item, amount = amt }
                    end
                    added = true
                end
            end
        end)
        return added
    end

    local useItemCost = false
    local itemCostAsBldCost = false
    pcall(function() useItemCost = (buildable.bUseItemCost == true) end)
    pcall(function() itemCostAsBldCost = (buildable.bItemCostAsBuildingCost == true) end)

    local found = false
    if useItemCost then
        local okC, costArr = pcall(function() return buildable.ItemCost end)
        if okC and costArr then found = addCostArray(costArr) end
    end
    if not found and itemCostAsBldCost then
        local okR, inputs = pcall(function() return buildable.ItemDetails.Recipe.Inputs end)
        if okR and inputs then found = addCostArray(inputs) end
    end
    if not found then
        local okC, costArr = pcall(function() return buildable.ItemCost end)
        if okC and costArr then found = addCostArray(costArr) end
    end
    if not found then
        local okR, inputs = pcall(function() return buildable.ItemDetails.Recipe.Inputs end)
        if okR and inputs then addCostArray(inputs) end
    end
end

function Perf.IsCreativeMode(pc, playerObj)
    local function probeObj(obj, tag, depth)
        if not Core.IsValidObj(obj) then return false end
        -- Direct fast checks for common UE / Main Sequence creative-mode flags & getters
        local okFast, valFast = pcall(function()
            if obj.bCreativeMode == true or obj.CreativeMode == true or obj.bIsCreativeMode == true
                or obj.bIsCreative == true or obj.bCreative == true
                or obj.bFreeBuild == true or obj.bFreeBuilding == true
                or obj.bInfiniteResources == true or obj.bInfiniteItems == true or obj.bNoBuildCost == true
            then
                return true
            end
            for _, fnName in ipairs({ "IsCreativeMode", "GetIsCreativeMode", "IsInCreativeMode", "IsCreative", "GetCreativeMode", "IsFreeBuildEnabled" }) do
                local fn = obj[fnName]
                if type(fn) == "function" then
                    local okR, r = pcall(fn, obj)
                    if okR and r == true then return true end
                end
            end
            return false
        end)
        if okFast and valFast == true then
            if not Perf.CreativeDiagLogged then
                Perf.CreativeDiagLogged = true
                Core.Log("[StationMap] Creative mode detected via fast path on " .. tostring(tag))
            end
            return true
        end

        -- Dynamic reflection scan (cached per UClass) to discover any creative/freebuild/infinite bool or getter
        local okCls, cls = pcall(function() return obj:GetClass() end)
        if not okCls or not Core.IsValidObj(cls) then return false end
        local clsAddr = cls:GetAddress()
        Perf.CreativeScanCache = Perf.CreativeScanCache or {}
        local spec = Perf.CreativeScanCache[clsAddr]
        if not spec then
            spec = { props = {}, funcs = {}, nested = {} }
            pcall(function()
                if cls.ForEachProperty then
                    cls:ForEachProperty(function(prop)
                        local pName = prop:GetFName():ToString()
                        local low = pName:lower()
                        if low:find("creative", 1, true) or low:find("freebuild", 1, true)
                            or low:find("infinite", 1, true) or low:find("nocost", 1, true)
                            or low:find("sandbox", 1, true) or low:find("cheat", 1, true)
                        then
                            spec.props[#spec.props + 1] = pName
                        elseif (depth or 0) == 0 and (low:find("settings", 1, true) or low:find("config", 1, true) or low:find("difficulty", 1, true) or low:find("rules", 1, true)) then
                            spec.nested[#spec.nested + 1] = pName
                        end
                    end)
                end
                if cls.ForEachFunction then
                    cls:ForEachFunction(function(fn)
                        local fName = fn:GetFName():ToString()
                        local low = fName:lower()
                        if (low:find("creative", 1, true) or low:find("freebuild", 1, true) or low:find("infinite", 1, true))
                            and (low:find("^is") or low:find("^get") or low:find("^has"))
                        then
                            spec.funcs[#spec.funcs + 1] = fName
                        end
                    end)
                end
            end)
            Perf.CreativeScanCache[clsAddr] = spec
        end

        for _, pName in ipairs(spec.props) do
            local okV, v = pcall(function() return obj[pName] end)
            if okV and v == true then
                if not Perf.CreativeDiagLogged then
                    Perf.CreativeDiagLogged = true
                    Core.Log(string.format("[StationMap] Creative mode detected via %s.%s=true", tostring(tag), pName))
                end
                return true
            end
        end
        for _, fName in ipairs(spec.funcs) do
            local okV, v = pcall(function() return obj[fName](obj) end)
            if okV and v == true then
                if not Perf.CreativeDiagLogged then
                    Perf.CreativeDiagLogged = true
                    Core.Log(string.format("[StationMap] Creative mode detected via %s:%s()=true", tostring(tag), fName))
                end
                return true
            end
        end
        if (depth or 0) == 0 then
            for _, nName in ipairs(spec.nested) do
                local okN, sub = pcall(function() return obj[nName] end)
                if okN and sub ~= nil then
                    if type(sub) == "userdata" and Core.IsValidObj(sub) then
                        if probeObj(sub, tag .. "." .. nName, 1) then return true end
                    elseif type(sub) == "table" or type(sub) == "userdata" then
                        local okS, sv = pcall(function()
                            return sub.bCreativeMode == true or sub.CreativeMode == true
                                or sub.bIsCreative == true or sub.bFreeBuild == true
                                or sub.bInfiniteResources == true or sub.bInfiniteItems == true
                                or sub.bNoBuildCost == true
                        end)
                        if okS and sv == true then
                            if not Perf.CreativeDiagLogged then
                                Perf.CreativeDiagLogged = true
                                Core.Log(string.format("[StationMap] Creative mode detected via struct %s.%s", tostring(tag), nName))
                            end
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    if probeObj(playerObj, "PlayerObject", 0) then return true end
    if probeObj(pc, "PlayerController", 0) then return true end

    local worldSub = Core.IsValidObj(pc) and Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass) or nil
    if Core.IsValidObj(worldSub) then
        if probeObj(worldSub, "WorldSubsystem", 0) then return true end
        local okW, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
        if okW and Core.IsValidObj(dmsWorld) and probeObj(dmsWorld, "DMSWorld", 0) then return true end
    end
    if Core.IsValidObj(pc) then
        local okPS, ps = pcall(function() return pc.PlayerState end)
        if okPS and Core.IsValidObj(ps) and probeObj(ps, "PlayerState", 0) then return true end
        local okW, uWorld = pcall(function() return pc:GetWorld() end)
        if okW and Core.IsValidObj(uWorld) then
            local okGS, gs = pcall(function() return uWorld.GameState end)
            if okGS and Core.IsValidObj(gs) and probeObj(gs, "GameState", 0) then return true end
            local okGM, gm = pcall(function() return uWorld.AuthorityGameMode end)
            if okGM and Core.IsValidObj(gm) and probeObj(gm, "GameMode", 0) then return true end
        end
        local okGI, gi = pcall(function() return pc:GetGameInstance() end)
        if okGI and Core.IsValidObj(gi) and probeObj(gi, "GameInstance", 0) then return true end
    end
    return false
end

local function PlayerHasBuildableMaterials(pc, buildable, count)
    if not Core.IsValidObj(pc) or not Core.IsValidObj(buildable) then return false end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false end

    if Perf.IsCreativeMode(pc, playerObj) then return true end

    local inv = nil
    local okBInv, bInv = pcall(function() return playerObj:GetBuildingInventory() end)
    if okBInv and Core.IsValidObj(bInv) then
        inv = bInv
    elseif Core.IsValidObj(playerObj.Inventory) then
        inv = playerObj.Inventory
    end
    if not Core.IsValidObj(inv) then return true end

    local neededCosts = {}
    CollectBuildableCosts(buildable, count or 1, neededCosts)
    for _, entry in pairs(neededCosts) do
        local okAmt, have = pcall(function() return inv:GetItemAmount(entry.item) end)
        if okAmt and (tonumber(have) or 0) < entry.amount then
            return false
        end
    end
    return true
end

local function ComputePendingMaterialSummary(pc)
    local summary = {
        isCreative = false,
        hasMissing = false,
        entries = {},
    }
    if not Core.IsValidObj(pc) then return summary end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return summary end

    summary.isCreative = Perf.IsCreativeMode(pc, playerObj)

    local inv = nil
    local okBInv, bInv = pcall(function() return playerObj:GetBuildingInventory() end)
    if okBInv and Core.IsValidObj(bInv) then
        inv = bInv
    elseif Core.IsValidObj(playerObj.Inventory) then
        inv = playerObj.Inventory
    end

    local netByItem = {}
    local function addDelta(itemObj, delta)
        if not Core.IsValidObj(itemObj) or not delta or delta == 0 then return end
        local addr = itemObj:GetAddress()
        if netByItem[addr] then
            netByItem[addr].net = netByItem[addr].net + delta
        else
            netByItem[addr] = { item = itemObj, net = delta }
        end
    end

    -- 1. Build costs from pending ghosts
    for _, g in ipairs(PendingGhosts) do
        if g and Core.IsValidObj(g.buildable) then
            local bCosts = {}
            CollectBuildableCosts(g.buildable, 1, bCosts)
            for _, entry in pairs(bCosts) do
                addDelta(entry.item, entry.amount)
            end
        end
    end

    -- 2. Refunds from pending deletes and overwrite-replacement targets
    local seenDelAddr = {}
    local function creditDeleteMachine(dm)
        if not dm or not Core.IsValidObj(dm.machine) then return end
        local mAddr = dm.addr or dm.machine:GetAddress()
        if seenDelAddr[mAddr] then return end
        seenDelAddr[mAddr] = true
        local bld = Core.IsValidObj(dm.buildable) and dm.buildable
            or (StationData.FindBuildableForMachineClass and StationData.FindBuildableForMachineClass(dm.machine) or nil)
        if Core.IsValidObj(bld) then
            local rCosts = {}
            CollectBuildableCosts(bld, 1, rCosts)
            for _, entry in pairs(rCosts) do
                addDelta(entry.item, -entry.amount)
            end
        end
    end

    for _, dm in pairs(PendingDeletes) do
        creditDeleteMachine(dm)
    end
    for _, g in ipairs(PendingGhosts) do
        if g and g.isReplace and g.replaceTargets then
            for _, rt in ipairs(g.replaceTargets) do
                creditDeleteMachine(rt)
            end
        end
    end

    for _, rec in pairs(netByItem) do
        if rec.net ~= 0 then
            local itemName = "Item"
            pcall(function()
                if rec.item.DisplayName then
                    local s = rec.item.DisplayName:ToString()
                    if s and s ~= "" then itemName = s end
                elseif rec.item.GetFName then
                    itemName = rec.item:GetFName():ToString()
                end
            end)
            local have = 0
            if Core.IsValidObj(inv) and inv.GetItemAmount then
                local okAmt, h = pcall(function() return inv:GetItemAmount(rec.item) end)
                if okAmt then have = tonumber(h) or 0 end
            end
            local lacking = (not summary.isCreative) and (rec.net > 0) and (have < rec.net)
            if lacking then
                summary.hasMissing = true
            end
            table.insert(summary.entries, {
                item = rec.item,
                name = itemName,
                net = rec.net,
                have = have,
                lacking = lacking,
            })
        end
    end

    table.sort(summary.entries, function(a, b)
        if a.lacking ~= b.lacking then return a.lacking end
        if (a.net > 0) ~= (b.net > 0) then return a.net > 0 end
        return a.name < b.name
    end)

    return summary
end

local function CheckMaterialsForPendingList(pc, list, delList)
    if not Core.IsValidObj(pc) then return false, nil end
    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false, nil end
    if Perf.IsCreativeMode(pc, playerObj) then return true, nil end

    local inv = nil
    local okBInv, bInv = pcall(function() return playerObj:GetBuildingInventory() end)
    if okBInv and Core.IsValidObj(bInv) then
        inv = bInv
    elseif Core.IsValidObj(playerObj.Inventory) then
        inv = playerObj.Inventory
    end
    if not Core.IsValidObj(inv) then return true, nil end

    -- Sum all required materials across pending builds, then credit refunds from pending deletes/replacements
    local totalNeeded = {}
    local firstBldByItem = {}
    for _, g in ipairs(list) do
        if Core.IsValidObj(g.buildable) then
            local bCosts = {}
            CollectBuildableCosts(g.buildable, 1, bCosts)
            for iAddr, entry in pairs(bCosts) do
                if totalNeeded[iAddr] then
                    totalNeeded[iAddr].amount = totalNeeded[iAddr].amount + entry.amount
                else
                    totalNeeded[iAddr] = { item = entry.item, amount = entry.amount }
                    firstBldByItem[iAddr] = g.buildable
                end
            end
        end
    end

    if delList then
        local refunds = {}
        for _, dm in ipairs(delList) do
            if dm and Core.IsValidObj(dm.machine) then
                local bld = Core.IsValidObj(dm.buildable) and dm.buildable
                    or (StationData.FindBuildableForMachineClass and StationData.FindBuildableForMachineClass(dm.machine) or nil)
                if Core.IsValidObj(bld) then
                    CollectBuildableCosts(bld, 1, refunds)
                end
            end
        end
        for iAddr, ref in pairs(refunds) do
            if totalNeeded[iAddr] then
                totalNeeded[iAddr].amount = math.max(0, totalNeeded[iAddr].amount - ref.amount)
            end
        end
    end

    for iAddr, entry in pairs(totalNeeded) do
        if entry.amount > 0 then
            local okAmt, have = pcall(function() return inv:GetItemAmount(entry.item) end)
            if okAmt and (tonumber(have) or 0) < entry.amount then
                return false, firstBldByItem[iAddr]
            end
        end
    end
    return true, nil
end

local function DumpObjectAllProperties(tag, obj)
    if not Core.IsValidObj(obj) then return end
    local clsName = "?"
    pcall(function() clsName = obj:GetClass():GetFName():ToString() end)
    local parts = {}
    local seen = {}
    pcall(function()
        local c = obj:GetClass()
        local depth = 0
        while Core.IsValidObj(c) and depth < 5 do
            depth = depth + 1
            local cName = ""
            pcall(function() cName = c:GetFName():ToString() end)
            if cName == "Object" then break end
            if c.ForEachProperty then
                c:ForEachProperty(function(prop)
                    local pn = prop:GetFName():ToString()
                    local low = pn:lower()
                    if not seen[pn] and not low:find("inventory", 1, true) and not low:find("itemslot", 1, true)
                        and not low:find("itemtotal", 1, true) and not low:find("ubergraph", 1, true)
                    then
                        seen[pn] = true
                        local pCls = ""
                        pcall(function() pCls = prop:GetClass():GetFName():ToString() end)
                        local valStr = "?"
                        local okV, v = pcall(function() return obj[pn] end)
                        if not okV then
                            valStr = "<err>"
                        elseif v == nil then
                            valStr = "nil"
                        elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
                            valStr = tostring(v)
                        elseif pCls:find("Array", 1, true) or pCls:find("Set", 1, true) then
                            local elems = {}
                            local okL, len = pcall(function() return v.GetArrayNum and v:GetArrayNum() or #v end)
                            if okL and type(len) == "number" then
                                for i = 1, math.min(len, 8) do
                                    local okE, e = pcall(function() return v[i] end)
                                    local ue = okE and (Core.UnwrapArrayElem and Core.UnwrapArrayElem(e) or e) or nil
                                    if Core.IsValidObj(ue) then
                                        table.insert(elems, ue:GetFName():ToString())
                                    else
                                        table.insert(elems, tostring(ue))
                                    end
                                end
                                valStr = string.format("[%d:%s]", len, table.concat(elems, ","))
                            elseif v.ForEach then
                                pcall(function()
                                    v:ForEach(function(_, e)
                                        if #elems < 8 then
                                            local ue = Core.UnwrapArrayElem and Core.UnwrapArrayElem(e) or e
                                            table.insert(elems, Core.IsValidObj(ue) and ue:GetFName():ToString() or tostring(ue))
                                        end
                                    end)
                                end)
                                valStr = string.format("{%s}", table.concat(elems, ","))
                            else
                                valStr = pCls
                            end
                        elseif Core.IsValidObj(v) then
                            pcall(function() valStr = v:GetFName():ToString() end)
                        else
                            valStr = pCls
                        end
                        table.insert(parts, pn .. "(" .. pCls:gsub("Property$", "") .. ")=" .. valStr)
                    end
                end)
            end
            c = c.GetSuperStruct and c:GetSuperStruct() or nil
        end
    end)
    -- Log in chunks of ~900 chars so UE4SS never truncates
    local full = table.concat(parts, "; ")
    local idStr = "?"
    pcall(function() if obj.ID ~= nil then idStr = tostring(obj.ID) end end)
    local chunkIdx = 1
    local pos = 1
    while pos <= #full do
        local chunk = full:sub(pos, pos + 899)
        Core.Log(string.format("[StationMap] %s cls=%s id=%s [%d]: %s", tag, clsName, idStr, chunkIdx, chunk))
        pos = pos + 900
        chunkIdx = chunkIdx + 1
    end
end

local function CaptureMachineConfig(m)
    if not Core.IsValidObj(m) then return nil end
    local cfg = {}
    local hasAny = false

    local clsKey = ""
    pcall(function() clsKey = m:GetClass():GetFName():ToString() end)

    -- 1. Recipe (Assemblers, Refineries, Furnaces, etc.)
    pcall(function()
        local r = m.Recipe
        if Core.IsValidObj(r) then
            cfg.recipe = r
            hasAny = true
        end
    end)

    -- 2. Splitter / Belt Balancer priorities & generic numeric configs
    pcall(function()
        if m.PriorityInputIndex ~= nil and type(m.PriorityInputIndex) == "number" then
            cfg.priorityInput = m.PriorityInputIndex
            if cfg.priorityInput >= 0 then hasAny = true end
        end
    end)
    pcall(function()
        if m.PriorityOutputIndex ~= nil and type(m.PriorityOutputIndex) == "number" then
            cfg.priorityOutput = m.PriorityOutputIndex
            if cfg.priorityOutput >= 0 then hasAny = true end
        end
    end)
    pcall(function()
        if m.Config ~= nil and type(m.Config) == "number" then
            cfg.config = m.Config
            if cfg.config ~= 0 then hasAny = true end
        end
    end)
    pcall(function()
        if m.Config2 ~= nil and type(m.Config2) == "number" then
            cfg.config2 = m.Config2
            if cfg.config2 ~= 0 then hasAny = true end
        end
    end)

    -- 3. Working / Paused state
    pcall(function()
        if type(m.bWorking) == "boolean" then
            cfg.bWorking = m.bWorking
            if not m.bWorking then hasAny = true end
        end
    end)

    -- 3b. Disabled ports: read PortStates (TArray<bool> on UMachineObject - works for Splitters, Balancers, Assemblers, Refineries!)
    -- NOTE: Do NOT run Core.UnwrapArrayElem on bool elements (it treats false as falsy -> nil). Check val == false directly!
    pcall(function()
        local dis = {}
        local seen = {}
        local ps = m.PortStates
        if ps ~= nil then
            local pLen = ps.GetArrayNum and ps:GetArrayNum() or #ps
            if type(pLen) == "number" and pLen > 0 then
                for i = 1, math.min(pLen, 16) do
                    local okE, val = pcall(function() return ps[i] end)
                    if okE and val == false and not seen[i - 1] then
                        table.insert(dis, i - 1)
                        seen[i - 1] = true
                    end
                end
            end
        end
        if #dis > 0 then
            cfg.disabledPorts = dis
            hasAny = true
        end
    end)

    -- 4. Single item filter (if present)
    pcall(function()
        local fi = m.FilterItem
        if not Core.IsValidObj(fi) then fi = m.ItemFilter end
        if Core.IsValidObj(fi) then
            cfg.filterItem = fi
            hasAny = true
        end
    end)

    -- 4b. Splitter / Belt Balancer Filters array (never touches inventory)
    pcall(function()
        local flt = m.Filters
        if flt then
            local len = flt.GetArrayNum and flt:GetArrayNum() or #flt
            if type(len) == "number" and len > 0 then
                cfg.filters = {}
                for i = 1, math.min(len, 16) do
                    local okE, elem = pcall(function() return flt[i] end)
                    if okE and elem ~= nil then
                        local unwrapped = Core.UnwrapArrayElem and Core.UnwrapArrayElem(elem) or elem
                        local fItem = nil
                        local fCount = 1
                        if Core.IsValidObj(unwrapped) then
                            fItem = unwrapped
                        elseif unwrapped ~= nil then
                            pcall(function()
                                if Core.IsValidObj(unwrapped.Item) then fItem = unwrapped.Item
                                elseif Core.IsValidObj(unwrapped.FilterItem) then fItem = unwrapped.FilterItem end
                            end)
                            pcall(function()
                                if unwrapped.Count ~= nil then fCount = tonumber(unwrapped.Count) or 1
                                elseif unwrapped.Amount ~= nil then fCount = tonumber(unwrapped.Amount) or 1 end
                            end)
                        end
                        if Core.IsValidObj(fItem) then
                            table.insert(cfg.filters, { idx = i - 1, item = fItem, count = fCount })
                            hasAny = true
                        end
                    end
                end
            end
        end
    end)

    -- 5. LogisticFilters array (Splitters, Belt Balancers, etc. - never touches inventory;
    -- never store raw TArray element userdata across frames to avoid dangling pointer crashes!)
    pcall(function()
        local lf = m.LogisticFilters
        if lf then
            local len = lf.GetArrayNum and lf:GetArrayNum() or #lf
            if type(len) == "number" and len > 0 then
                cfg.logisticFilters = {}
                for i = 1, math.min(len, 16) do
                    local okE, elem = pcall(function() return lf[i] end)
                    if okE and elem ~= nil then
                        local entry = { idx = i - 1 }
                        pcall(function()
                            if Core.IsValidObj(elem.Item) then entry.item = elem.Item
                            elseif Core.IsValidObj(elem.FilterItem) then entry.item = elem.FilterItem end
                        end)
                        pcall(function()
                            if elem.PortIndex ~= nil then entry.portIndex = tonumber(elem.PortIndex)
                            elseif elem.Port ~= nil then entry.portIndex = tonumber(elem.Port) end
                        end)
                        pcall(function()
                            if elem.Action ~= nil then entry.action = tonumber(elem.Action)
                            elseif elem.FilterAction ~= nil then entry.action = tonumber(elem.FilterAction) end
                        end)
                        pcall(function()
                            if elem.Amount ~= nil then entry.amount = tonumber(elem.Amount)
                            elseif elem.Count ~= nil then entry.amount = tonumber(elem.Count)
                            elseif elem.Limit ~= nil then entry.amount = tonumber(elem.Limit) end
                        end)
                        if Core.IsValidObj(entry.item) or entry.portIndex ~= nil then
                            table.insert(cfg.logisticFilters, entry)
                            hasAny = true
                        end
                    end
                end
            end
        end
    end)

    return hasAny and cfg or nil
end

local function GetPlayerObjectID(pc)
    local pid = 0
    if not Core.IsValidObj(pc) then return 0 end
    pcall(function()
        if pc.PlayerObjectID ~= nil then
            pid = tonumber(pc.PlayerObjectID) or 0
        end
        if pid == 0 and Core.IsValidObj(pc.PlayerObject) and pc.PlayerObject.ID ~= nil then
            pid = tonumber(pc.PlayerObject.ID) or 0
        end
    end)
    return pid
end

local function InvokeCreateInputCommand(pc, className, funcName, valMap)
    if not Core.IsValidObj(pc) or not pc.AddInputCommand then return false end
    local key = className .. ":" .. funcName
    local sig = InputCmdSigCache[key]
    if sig == nil or (sig and not Core.IsValidObj(sig.cdo)) then
        local ufunc = StaticFindObject("/Script/MainSequence." .. className .. ":" .. funcName)
        local cdo = StaticFindObject("/Script/MainSequence.Default__" .. className)
        if not Core.IsValidObj(ufunc) or not Core.IsValidObj(cdo) then
            InputCmdSigCache[key] = false
            Core.Log("[StationMap] InputCmd not found: " .. key)
            return false
        end
        sig = { cdo = cdo, params = {} }
        local pNames = {}
        pcall(function()
            ufunc:ForEachProperty(function(prop)
                local pn = prop:GetFName():ToString()
                local pcName = ""
                pcall(function() pcName = prop:GetClass():GetFName():ToString() end)
                if pn ~= "ReturnValue" then
                    table.insert(sig.params, { name = pn, cls = pcName })
                    table.insert(pNames, pn .. ":" .. pcName)
                end
            end)
        end)
        InputCmdSigCache[key] = sig
        Core.Log(string.format("[StationMap] InputCmdSig %s(%s)", key, table.concat(pNames, ", ")))
    end
    if not sig or not Core.IsValidObj(sig.cdo) then return false end

    local args = {}
    for _, p in ipairs(sig.params) do
        local low = p.name:lower()
        local cls = p.cls or ""
        local v = nil
        if low:find("receiver", 1, true) or low:find("machineid", 1, true) or low:find("target", 1, true) then
            v = valMap.receiverId
        elseif low:find("player", 1, true) then
            v = valMap.playerObjId or 0
        elseif low:find("recipe", 1, true) then
            v = valMap.recipe
        elseif low:find("config2", 1, true) then
            v = valMap.config2
        elseif low:find("config", 1, true) then
            v = valMap.config
        elseif low:find("working", 1, true) then
            v = valMap.bWorking
        elseif low:find("port", 1, true) or low:find("index", 1, true) then
            v = valMap.portIndex or 0
        elseif low:find("remove", 1, true) then
            v = valMap.bRemove == true
        elseif low:find("action", 1, true) then
            v = valMap.action or 0
        elseif low:find("itemstack", 1, true) then
            if cls:find("Struct", 1, true) then
                v = { Item = valMap.item, Count = valMap.amount or 1 }
            else
                v = valMap.item
            end
        elseif low:find("filter", 1, true) and cls:find("Struct", 1, true) then
            v = valMap.filterStruct
        elseif low:find("item", 1, true) or low:find("filter", 1, true) then
            v = valMap.item
        elseif low:find("amount", 1, true) or low:find("count", 1, true) or low:find("limit", 1, true) then
            v = valMap.amount or 0
        elseif cls:find("Bool", 1, true) then
            v = false
        elseif cls:find("Int", 1, true) then
            v = 0
        end
        table.insert(args, v)
    end

    local okCall, cmdObj = pcall(function()
        return sig.cdo[funcName](sig.cdo, table.unpack(args))
    end)
    if not okCall then
        Core.Log(string.format("[StationMap] InputCmd %s call err: %s", key, tostring(cmdObj)))
        return false
    end
    if Core.IsValidObj(cmdObj) then
        -- DMSPlayerController:AddInputCommand takes TWO params: (InReceiverID:Int32, InCommand:UInputCommand*)
        local okAdd, errAdd = pcall(function() pc:AddInputCommand(valMap.receiverId, cmdObj) end)
        if not okAdd then
            Core.Log(string.format("[StationMap] AddInputCommand(%s, %s) err: %s", tostring(valMap.receiverId), key, tostring(errAdd)))
            return false
        end
        return true
    end
    return false
end

local function ApplyMachineConfig(pc, targetMachine, cfg)
    if not Core.IsValidObj(pc) or not Core.IsValidObj(targetMachine) or not cfg then return false end
    local receiverId = 0
    pcall(function() if targetMachine.ID ~= nil then receiverId = tonumber(targetMachine.ID) or 0 end end)
    if receiverId == 0 then return false end

    local playerObjId = GetPlayerObjectID(pc)
    local applied = false

    -- 1. Recipe (Assemblers, Refineries, etc.)
    if Core.IsValidObj(cfg.recipe) then
        if InvokeCreateInputCommand(pc, "SetRecipeInput", "CreateInputSetRecipe", {
            receiverId = receiverId,
            recipe = cfg.recipe,
            playerObjId = playerObjId,
        }) then
            applied = true
        end
    end

    -- 2. Splitter / Belt Balancer priorities (verified from live Splitter log: Config=0 is OutputPriority, Config=1 is InputPriority, Config2=portIndex)
    local hasPrio = (cfg.priorityInput ~= nil and cfg.priorityInput >= 0) or (cfg.priorityOutput ~= nil and cfg.priorityOutput >= 0)
    if hasPrio then
        if cfg.priorityOutput ~= nil and cfg.priorityOutput >= 0 then
            if InvokeCreateInputCommand(pc, "SetConfigInput", "CreateInputSetConfig2", {
                receiverId = receiverId,
                config = 0,
                config2 = cfg.priorityOutput,
                playerObjId = playerObjId,
            }) then
                applied = true
            end
        end
        if cfg.priorityInput ~= nil and cfg.priorityInput >= 0 then
            if InvokeCreateInputCommand(pc, "SetConfigInput", "CreateInputSetConfig2", {
                receiverId = receiverId,
                config = 1,
                config2 = cfg.priorityInput,
                playerObjId = playerObjId,
            }) then
                applied = true
            end
        end
    end
    if cfg.priorityInput == nil and cfg.priorityOutput == nil and cfg.config ~= nil and cfg.config ~= 0 then
        if cfg.config2 ~= nil and cfg.config2 ~= 0 then
            if InvokeCreateInputCommand(pc, "SetConfigInput", "CreateInputSetConfig2", {
                receiverId = receiverId,
                config = cfg.config,
                config2 = cfg.config2,
                playerObjId = playerObjId,
            }) then
                applied = true
            end
        else
            if InvokeCreateInputCommand(pc, "SetConfigInput", "CreateInputSetConfig", {
                receiverId = receiverId,
                config = cfg.config,
                playerObjId = playerObjId,
            }) then
                applied = true
            end
        end
    end

    -- 2b. Disabled ports: when a recipe was also set, poll until m.Recipe replicates
    -- (handles high-RTT multiplayer without blind fixed delays) before toggling ports.
    if cfg.disabledPorts and #cfg.disabledPorts > 0 then
        local capM = targetMachine
        local capRecvId = receiverId
        local capPorts = cfg.disabledPorts
        local expectedRecipeAddr = Core.IsValidObj(cfg.recipe) and cfg.recipe:GetAddress() or nil
        local deadlineClock = os.clock() + 2.5

        local function applyDisabledPortsNow()
            local curPC = Core.GetLocalPlayerController()
            if not Core.IsValidObj(capM) or not Core.IsValidObj(curPC) then return end
            local portInputCls = Core.FindOrLoadClass("/Script/MainSequence.MachinePortInput")
            for _, portIdx in ipairs(capPorts) do
                local shouldToggle = true
                pcall(function()
                    if capM.PortStates then
                        local cur = capM.PortStates[portIdx + 1]
                        if cur == false then shouldToggle = false end
                    elseif capM.IsPortEnabled then
                        local en = capM:IsPortEnabled(portIdx)
                        if en == false then shouldToggle = false end
                    end
                end)
                if shouldToggle then
                    if Core.IsValidObj(portInputCls) then
                        local okNew, cmdObj = pcall(StaticConstructObject, portInputCls, curPC)
                        if okNew and Core.IsValidObj(cmdObj) then
                            local okMut = pcall(function() cmdObj:TogglePortEnabled(portIdx) end)
                            if okMut then
                                pcall(function() curPC:AddInputCommand(capRecvId, cmdObj) end)
                            end
                        end
                    end
                end
            end
        end

        if expectedRecipeAddr then
            local function pollRecipeThenPorts()
                if not Core.IsValidObj(capM) then return end
                local recipeReady = false
                pcall(function()
                    local curR = capM.Recipe
                    if Core.IsValidObj(curR) and curR:GetAddress() == expectedRecipeAddr then
                        recipeReady = true
                    end
                end)
                if recipeReady or os.clock() >= deadlineClock then
                    applyDisabledPortsNow()
                else
                    ExecuteInGameThreadWithDelay(100, pollRecipeThenPorts)
                end
            end
            ExecuteInGameThreadWithDelay(100, pollRecipeThenPorts)
        else
            ExecuteInGameThreadAfterFrames(1, applyDisabledPortsNow)
        end
        applied = true
    end

    -- 3. Splitter / Belt Balancer per-port Filters array
    if cfg.filters and #cfg.filters > 0 then
        for _, f in ipairs(cfg.filters) do
            if Core.IsValidObj(f.item) then
                if InvokeCreateInputCommand(pc, "SetItemInput", "CreateInputSetItem", {
                    receiverId = receiverId,
                    item = f.item,
                    amount = f.count or 1,
                    config = f.idx or 0,
                    playerObjId = playerObjId,
                }) then
                    applied = true
                end
            end
        end
    end

    -- 3b. Single item filter
    if Core.IsValidObj(cfg.filterItem) then
        if InvokeCreateInputCommand(pc, "SetItemInput", "CreateInputSetItem", {
            receiverId = receiverId,
            item = cfg.filterItem,
            amount = 1,
            config = 0,
            playerObjId = playerObjId,
        }) then
            applied = true
        end
    end

    -- 4. Logistic filters (Containers / Drone Bays / etc.)
    if cfg.logisticFilters and #cfg.logisticFilters > 0 then
        for _, lf in ipairs(cfg.logisticFilters) do
            if InvokeCreateInputCommand(pc, "LogisticFilterInput", "CreateInputLogisticFilter", {
                receiverId = receiverId,
                portIndex = lf.portIndex or lf.idx or 0,
                item = lf.item,
                action = lf.action or 0,
                amount = lf.amount or 0,
                filterStruct = lf.raw,
                bRemove = false,
                playerObjId = playerObjId,
            }) then
                applied = true
            end
        end
    end

    -- 5. Working / Paused state (only send if paused)
    if cfg.bWorking == false then
        if InvokeCreateInputCommand(pc, "SetWorkingInput", "CreateInputSetWorking", {
            receiverId = receiverId,
            bWorking = false,
            playerObjId = playerObjId,
        }) then
            applied = true
        end
    end

    return applied
end

local function IssueRemoteBuildMachine(pc, station, platform, platBounds, buildable, locX, locY, locZ, wx, wy, wz, yawDeg, recipe, machineConfig)
    if not (Core.IsValidObj(pc) and Core.IsValidObj(buildable)) then
        return false, "Invalid controller or buildable"
    end
    if not PlayerHasBuildableMaterials(pc, buildable, 1) then
        return false, "Insufficient materials in inventory"
    end

    local targetFrame = Core.IsValidObj(station) and station or platform
    if not Core.IsValidObj(targetFrame) then
        return false, "No target station"
    end

    local quat = {
        X = 0.0,
        Y = 0.0,
        Z = math.sin(math.rad((yawDeg or 0.0) * 0.5)),
        W = math.cos(math.rad((yawDeg or 0.0) * 0.5)),
    }
    local localTransform = {
        Rotation = quat,
        Translation = { X = locX, Y = locY, Z = locZ },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }
    local worldTransform = {
        Rotation = quat,
        Translation = { X = wx, Y = wy, Z = wz },
        Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
    }

    local frameId = 0
    pcall(function() if targetFrame.ID ~= nil then frameId = tonumber(targetFrame.ID) or 0 end end)
    local platId = 0
    if Core.IsValidObj(platform) then
        pcall(function() if platform.ID ~= nil then platId = tonumber(platform.ID) or 0 end end)
    end
    local gx = math.floor(locX / BuildGridDivisor + 0.5)
    local gy = math.floor(locY / BuildGridDivisor + 0.5)
    local gz = math.floor(locZ / BuildHeightDivisor + 0.5)
    local rotSteps = ((math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4) + 4) % 4

    local cmdSuccess = false
    local callErr = nil

    -- Primary path: DMSPlayerController:AddBuildCommand(BuildCommand) (verified native builder entry point)
    local addBuildLayout = InspectAddBuildCommandLayout()
    if addBuildLayout and addBuildLayout.fields and addBuildLayout.fields["Buildable"] and pc.AddBuildCommand then
        local fs = addBuildLayout.fieldStructs or {}
        local function makeFP(v) return { Value = math.floor(v * 65536.0 + 0.5) } end
        local function makeVec(sName, x, y, z)
            local low = (sName or ""):lower()
            if low == "pvector" or low:find("fp", 1, true) or low:find("fixed", 1, true) then
                return { X = makeFP(x), Y = makeFP(y), Z = makeFP(z) }
            elseif low == "intvector" then
                return { X = math.floor(x + 0.5), Y = math.floor(y + 0.5), Z = math.floor(z + 0.5) }
            end
            return { X = x, Y = y, Z = z }
        end
        local function makeQuat(sName, x, y, z, w)
            local low = (sName or ""):lower()
            if low == "pquat" or low:find("fp", 1, true) or low:find("fixed", 1, true) then
                return { X = makeFP(x), Y = makeFP(y), Z = makeFP(z), W = makeFP(w) }
            end
            return { X = x, Y = y, Z = z, W = w }
        end

        local solarSysId = 0
        local chunkX, chunkY, chunkZ = 0.0, 0.0, 0.0
        pcall(function()
            if targetFrame.SolarSystemID ~= nil then solarSysId = tonumber(targetFrame.SolarSystemID) or 0 end
            if targetFrame.ChunkLocation then
                chunkX, chunkY, chunkZ = Core.GetFPVector(targetFrame.ChunkLocation)
            end
        end)

        local bldClsLow = ""
        pcall(function() bldClsLow = buildable:GetFName():ToString():lower() end)
        local isUndergroundBld = bldClsLow:find("underground", 1, true) ~= nil
        local buildCfgVal = (isUndergroundBld and machineConfig and machineConfig.config) or 0

        local bCmd = {
            Buildable = buildable,
            Location = makeVec(fs["Location"], locX / 100.0, locY / 100.0, locZ / 100.0),
            Quat = makeQuat(fs["Quat"], quat.X, quat.Y, quat.Z, quat.W),
            ChunkLocation = makeVec(fs["ChunkLocation"], chunkX, chunkY, chunkZ),
            SolarSystemID = solarSysId,
            AttachTargetID = frameId,
            GridTransform = {
                GridLocation = { X = gx, Y = gy },
                Height = gz,
                GridRotation = rotSteps,
            },
            Config = buildCfgVal,
        }
        Core.Log(string.format("[StationMap] Calling AddBuildCommand(attachId=%d, sys=%d, chunk=(%.0f,%.0f,%.0f), loc=(%.2f,%.2f,%.2f), grid=(%d,%d), h=%d, rot=%d)",
            frameId, solarSysId, chunkX, chunkY, chunkZ, locX / 100.0, locY / 100.0, locZ / 100.0, gx, gy, gz, rotSteps))
        local okCmd, errCmd = pcall(function() pc:AddBuildCommand(bCmd) end)
        Core.Log(string.format("[StationMap] AddBuildCommand returned ok=%s err=%s", tostring(okCmd), tostring(errCmd)))
        if okCmd then
            cmdSuccess = true
        else
            callErr = tostring(errCmd)
        end
    else
        callErr = "AddBuildCommand not available on PlayerController"
    end

    if not cmdSuccess then
        Core.Log("[StationMap] IssueRemoteBuildMachine failed: " .. tostring(callErr))
        return false, callErr or "Build command failed (see UE4SS.log)"
    end

    return true, nil
end

local function IssueRemoteDisassembleMachine(pc, machine)
    if not Core.IsValidObj(pc) or not Core.IsValidObj(machine) or not pc.AddDisassembleCommand then
        return false, "AddDisassembleCommand unavailable"
    end
    local mId = 0
    pcall(function() if machine.ID ~= nil then mId = tonumber(machine.ID) or 0 end end)
    if mId == 0 then return false, "Machine has no valid ID" end

    if DisassembleSigCache == nil then
        local ufunc = StaticFindObject("/Script/MainSequence.DMSPlayerController:AddDisassembleCommand")
        DisassembleSigCache = { params = {} }
        local pLog = {}
        if Core.IsValidObj(ufunc) then
            pcall(function()
                ufunc:ForEachProperty(function(prop)
                    local pn = prop:GetFName():ToString()
                    local pCls = ""
                    pcall(function() pCls = prop:GetClass():GetFName():ToString() end)
                    if pn ~= "ReturnValue" then
                        local stFields = nil
                        if pCls == "StructProperty" and prop.GetStruct then
                            local okS, st = pcall(function() return prop:GetStruct() end)
                            if okS and Core.IsValidObj(st) and st.ForEachProperty then
                                stFields = {}
                                st:ForEachProperty(function(fp)
                                    local fn = fp:GetFName():ToString()
                                    local fc = ""
                                    pcall(function() fc = fp:GetClass():GetFName():ToString() end)
                                    stFields[fn] = fc
                                end)
                            end
                        end
                        table.insert(DisassembleSigCache.params, { name = pn, cls = pCls, fields = stFields })
                        table.insert(pLog, pn .. ":" .. pCls)
                    end
                end)
            end)
        end
        Core.Log("[StationMap] DisassembleSig: " .. table.concat(pLog, ", "))
    end

    local args = {}
    for _, p in ipairs(DisassembleSigCache.params) do
        local cls = p.cls or ""
        local low = p.name:lower()
        if cls == "StructProperty" and p.fields then
            local st = {}
            for fn, fc in pairs(p.fields) do
                local fl = fn:lower()
                if fc:find("Int", 1, true) then
                    st[fn] = mId
                elseif fc:find("Object", 1, true) then
                    st[fn] = machine
                elseif fc:find("Bool", 1, true) then
                    st[fn] = false
                end
            end
            table.insert(args, st)
        elseif cls:find("Int", 1, true) then
            table.insert(args, mId)
        elseif cls:find("Object", 1, true) then
            table.insert(args, machine)
        elseif cls:find("Bool", 1, true) then
            table.insert(args, false)
        else
            table.insert(args, (low:find("mass", 1, true) and false or mId))
        end
    end

    local ok, err = pcall(function() pc:AddDisassembleCommand(table.unpack(args)) end)
    if not ok then
        Core.Log(string.format("[StationMap] AddDisassembleCommand(id=%d) err: %s", mId, tostring(err)))
        return false, tostring(err)
    end
    return true, nil
end

local function IsSelectableMachine(rm)
    if not rm or not Core.IsValidObj(rm.machine) then return false end
    if not Core.IsValidObj(rm.buildable) then return false end
    local cat = rm.cat or ""
    if cat == "Dock" or cat == "Elevator" or cat == "DroneBay" or cat == "Command" then
        return false
    end
    local low = (rm.actorClsPath or ""):lower()
    if low:find("dock", 1, true) or low:find("elevator", 1, true) or low:find("dronebay", 1, true)
        or low:find("stationblock", 1, true) or low:find("commandmodule", 1, true)
        or low:find("airlock", 1, true) or low:find("teleporter", 1, true)
        or low:find("turret", 1, true) or low:find("solar", 1, true)
    then
        return false
    end
    return true
end

local function IsSplitterOrBalancerCls(clsPath)
    local low = (clsPath or ""):lower()
    return (low:find("splitter", 1, true) ~= nil) or (low:find("balancer", 1, true) ~= nil)
end

local function IsPlainConveyorBeltRm(rm)
    if not rm then return false end
    local low = (rm.actorClsPath or ""):lower()
    return (rm.cat == "Conveyor" or low:find("conveyorbelt", 1, true) ~= nil) and (low:find("underground", 1, true) == nil)
end

local function IsSameMachineType(item, rm)
    if not item or not rm then return false end
    if Core.IsValidObj(item.buildable) and Core.IsValidObj(rm.buildable) then
        if item.buildable:GetAddress() == rm.buildable:GetAddress() then
            return true
        end
    end
    if item.actorClsPath and rm.actorClsPath and item.actorClsPath ~= "" and item.actorClsPath == rm.actorClsPath then
        return true
    end
    return false
end

local function EvaluatePasteGhostOverlap(item, sx, sy, pX, pY, finalYaw, floor)
    local rx, ry = GetRotatedCellDims(item.cellsX or 1, item.cellsY or 1, finalYaw)
    local hw, hh = rx * CELL_CM * 0.5, ry * CELL_CM * 0.5
    local overlaps = {}
    local seenAddr = {}

    local function checkFootprintAgainst(fx, fy)
        local candidates = {}
        local candSeen = {}
        Perf.QueryMachinesInRect(fx - hw - 10.0, fx + hw + 10.0, fy - hh - 10.0, fy + hh + 10.0, candidates, candSeen)
        for i = 1, #candidates do
            local rm = candidates[i]
            if not PendingDeletes[rm.addr] and not seenAddr[rm.addr] then
                local hitMain = (math.abs(fx - rm.x) < (hw + rm.halfW - 10.0)) and (math.abs(fy - rm.y) < (hh + rm.halfH - 10.0))
                local hitPair = rm.pairX and rm.pairY and (math.abs(fx - rm.pairX) < (hw + rm.halfW - 10.0)) and (math.abs(fy - rm.pairY) < (hh + rm.halfH - 10.0))
                if hitMain or hitPair then
                    seenAddr[rm.addr] = true
                    table.insert(overlaps, rm)
                end
            end
        end
    end

    checkFootprintAgainst(sx, sy)
    if pX and pY then checkFootprintAgainst(pX, pY) end

    if #overlaps == 0 then
        return true, false, nil
    end

    -- Exception A: Same machine type at the same footprint (including 90-deg rotation of non-square 2x1 machines)
    if #overlaps == 1 and IsSelectableMachine(overlaps[1]) and IsSameMachineType(item, overlaps[1]) then
        local rm = overlaps[1]
        local sameCenter = math.abs(rm.x - sx) < 25.0 and math.abs(rm.y - sy) < 25.0
        local rotated2x1 = (math.abs(rm.halfW - hw) > 10.0 or math.abs(rm.halfH - hh) > 10.0)
            and math.abs(rm.x - sx) <= (CELL_CM * 0.55) and math.abs(rm.y - sy) <= (CELL_CM * 0.55)
        if sameCenter or rotated2x1 then
            return true, true, overlaps
        end
    end

    -- Exception B: Splitter or Belt Balancer overwriting one or more plain Conveyor Belts
    if IsSplitterOrBalancerCls(item.actorClsPath) then
        local allBelts = true
        for _, rm in ipairs(overlaps) do
            if not (IsSelectableMachine(rm) and IsPlainConveyorBeltRm(rm)) then
                allBelts = false
                break
            end
        end
        if allBelts then
            return true, true, overlaps
        end
    end

    -- Disallowed overwrite: skip placing ghost at this position
    return false, false, nil
end

--------------------------------------------------------------------------------
-- UI Creation & Rendering
--------------------------------------------------------------------------------

local function ClearCanvasChildren(canvas)
    if Core.IsValidObj(canvas) then
        pcall(function() canvas:ClearChildren() end)
    end
end

local function SetImageWidgetOpacity(img, col)
    if not Core.IsValidObj(img) then return end
    pcall(function()
        if img.SetColorAndOpacity then
            img:SetColorAndOpacity(col)
        elseif img.SetBrushTintColor then
            img:SetBrushTintColor({ SpecifiedColor = col, ColorUseRule = 0 })
        end
    end)
end

-- Creates a reliable clickable button backed by WBP_Button_C (using Overlay instead of broken SetContentForSlot)
local function CreateLabeledButton(parentWindow, pc, outer, labelStr, fontSz, widthOpt, heightOpt, bgCol, textCol, onClick, trackList)
    local btn = Core.CreateUserWidget(PATHS.WBPButtonClass, parentWindow, pc)
    local txt = Core.CreateUserWidget(PATHS.WBPTextClass, parentWindow, pc)
    local ov = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    if not (Core.IsValidObj(btn) and Core.IsValidObj(txt) and Core.IsValidObj(ov)) then
        return nil, nil, nil
    end

    pcall(function()
        if bgCol and btn.SetBackgroundColour then
            btn:SetBackgroundColour(bgCol)
        end
        btn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        local bSlot = ov:AddChildToOverlay(btn)
        if Core.IsValidObj(bSlot) then
            bSlot:SetHorizontalAlignment(0) -- Fill
            bSlot:SetVerticalAlignment(0)   -- Fill
        end

        local tSlot = ov:AddChildToOverlay(txt)
        if Core.IsValidObj(tSlot) then
            tSlot:SetHorizontalAlignment(2) -- Center
            tSlot:SetVerticalAlignment(2)   -- Center
            tSlot:SetPadding({ Left = 6.0, Top = 2.0, Right = 6.0, Bottom = 2.0 })
        end
        -- Re-apply size/text/visibility AFTER parenting (WBP_Text_C Construct resets defaults on parent attach)
        local function ApplyTextProps()
            if not Core.IsValidObj(txt) then return end
            pcall(function()
                txt:SetVisibility(3) -- HitTestInvisible so clicks reach WBP_Button_C underneath
                if Core.IsValidObj(txt.TextBlock) then
                    txt.TextBlock:SetVisibility(3)
                end
                txt:SetSize(fontSz or 12)
                txt:SetText(Core.MakeText(labelStr or ""))
                if textCol and Core.IsValidObj(txt.TextBlock) and txt.TextBlock.SetColorAndOpacity then
                    txt.TextBlock:SetColorAndOpacity({ SpecifiedColor = textCol, ColorUseRule = 0 })
                end
            end)
        end
        ApplyTextProps()
        ExecuteInGameThreadAfterFrames(1, ApplyTextProps)
    end)

    Core.RegisterWBPButtonClick(btn, onClick)
    table.insert(trackList or TrackedButtons, btn)

    if widthOpt or heightOpt then
        local sb = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
        if Core.IsValidObj(sb) then
            pcall(function()
                if widthOpt then sb:SetWidthOverride(widthOpt) end
                if heightOpt then sb:SetHeightOverride(heightOpt) end
                sb:AddChild(ov)
            end)
            return sb, btn, txt
        end
    end
    return ov, btn, txt
end

local BELT_TIER_COLORS = {
    [1] = { R = 0.98, G = 0.84, B = 0.12, A = 1.0 }, -- Mk1: Yellow
    [2] = { R = 0.96, G = 0.48, B = 0.08, A = 1.0 }, -- Mk2: Orange
    [3] = { R = 0.90, G = 0.18, B = 0.16, A = 1.0 }, -- Mk3: Red
}

local function GetTierArrowColor(tier)
    local t = tonumber(tier) or 1
    if t <= 1 then return BELT_TIER_COLORS[1]
    elseif t == 2 then return BELT_TIER_COLORS[2]
    else return BELT_TIER_COLORS[3] end
end

local function AddSharpChevronToCanvas(outer, canvas, tipX, cy, armLen, armThick, col, zBase)
    -- Two 42-deg arms whose right tips intersect cleanly at (tipX, cy) forming a crisp V chevron (>)
    local rad = math.rad(42.0)
    local halfCos = (armLen * 0.5) * math.cos(rad)
    local halfSin = (armLen * 0.5) * math.sin(rad)
    local cx = tipX - halfCos
    for _, sp in ipairs({ { dy = -halfSin, ang = 42.0 }, { dy = halfSin, ang = -42.0 } }) do
        local bar = CreateRawFast(PATHS.BorderClass, outer)
        if Core.IsValidObj(bar) then
            pcall(function()
                bar:SetVisibility(3)
                bar:SetBrushColor(col)
                bar:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
                if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle(sp.ang) end
            end)
            local bs = canvas:AddChildToCanvas(bar)
            SetCanvasSlot(bs, cx, cy + sp.dy, armLen, armThick, 0.5, 0.5, zBase)
        end
    end
end

local function RenderDirectionChevron(outer, canvas, cx, cy, sizePx, yawDeg, col, zOrder)
    local s = math.max(10.0, sizePx or 18.0)
    local tile = CreateRawFast(PATHS.CanvasPanelClass, outer)
    if not Core.IsValidObj(tile) then return nil end
    pcall(function()
        tile:SetVisibility(3)
        tile:SetRenderTransformPivot({ X = 0.5, Y = 0.5 })
        if math.abs(yawDeg or 0.0) > 0.1 and tile.SetRenderTransformAngle then
            tile:SetRenderTransformAngle(yawDeg)
        end
    end)
    local tSlot = canvas:AddChildToCanvas(tile)
    SetCanvasSlot(tSlot, cx, cy, s, s, 0.5, 0.5, zOrder)

    local armLen = math.max(6.0, s * 0.44)
    local armThick = math.max(1.8, math.min(3.2, s * 0.12))
    AddSharpChevronToCanvas(outer, tile, s * 0.68, s * 0.5, armLen, armThick, col, 1)
    return tile
end

local PORT_BG_COL = { R = 0.08, G = 0.10, B = 0.14, A = 0.88 }
local PORT_DASH_COL = { R = 0.0, G = 0.0, B = 0.0, A = 0.98 }
local function RenderUnconnectedItemPort(outer, canvas, px, py, portSize, zOrder, outWidgets)
    local sz = math.max(12.0, portSize or 18.0)
    -- Compact 2-widget port badge (6.5x fewer UMG widgets than 13-dash borders!)
    local bOuter = AddBorderFast(outer, canvas, px, py, sz, sz, PORT_DASH_COL, zOrder)
    local bInner = AddBorderFast(outer, canvas, px, py, math.max(6.0, sz - 4.0), math.max(6.0, sz - 4.0), PORT_BG_COL, zOrder + 1)
    if outWidgets then
        if bOuter then table.insert(outWidgets, bOuter) end
        if bInner then table.insert(outWidgets, bInner) end
    end
end

local function RenderDashedLine(outer, canvas, x1, y1, x2, y2, col, thickness, dashLen, gapLen, zOrder, outWidgets)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 4.0 then return end
    local ang = math.deg(math.atan(dy, dx))
    local dLen = dashLen or 10.0
    local gLen = gapLen or 7.0
    local step = dLen + gLen
    local ux, uy = dx / dist, dy / dist
    local t = 4.0
    while t < dist - 4.0 do
        local segLen = math.min(dLen, (dist - 4.0) - t)
        if segLen >= 2.0 then
            local mid = t + segLen * 0.5
            local b = AddBorderFast(outer, canvas, x1 + ux * mid, y1 + uy * mid, segLen, thickness or 2.4, col, zOrder)
            if b then
                pcall(function()
                    b:SetRenderTransformPivot(ALIGN_CENTER)
                    if math.abs(ang) > 0.1 and b.SetRenderTransformAngle then b:SetRenderTransformAngle(ang) end
                end)
                if outWidgets then table.insert(outWidgets, b) end
            end
        end
        t = t + step
    end
end

local function CreateMachineVisualWidget(parentWindow, pc, outer, targetCanvas, mx, my, pxW, pxH, yawDeg, cat, spriteEntry, isGhost, validGhost, zBase, hasBottomOverlay, outWidgets)
    local fillW = math.max(6.0, pxW - 2.0)
    local fillH = math.max(6.0, pxH - 2.0)

    -- Fast 2D conveyor belt visual: 4 borders directly on targetCanvas (no per-tile CanvasPanel wrapper!)
    if cat == "Conveyor" then
        local tier = (spriteEntry and spriteEntry.tier) or 1
        local tierDark = (tier == 1) and 1.0 or ((tier == 2) and 0.78 or 0.62)
        local bgCol = isGhost and (validGhost and COLORS.GhostValid or COLORS.GhostInvalid)
            or { R = 0.22 * tierDark, G = 0.24 * tierDark, B = 0.27 * tierDark, A = 0.96 }
        local bdrCol = isGhost and (validGhost and COLORS.GhostBorderOk or COLORS.GhostBorderBad)
            or { R = 0.06, G = 0.07, B = 0.09, A = 0.98 }
        local railCol = isGhost and bdrCol or { R = 0.05, G = 0.06, B = 0.08, A = 0.98 }
        local arrowCol = isGhost and bdrCol or GetTierArrowColor(tier)

        local norm = (math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
        local isVert = (norm == 1 or norm == 3)
        local railThick = math.max(2.0, math.min(fillW, fillH) * 0.12)
        local bedW = isVert and math.max(4.0, fillW - railThick * 2.0) or fillW
        local bedH = isVert and fillH or math.max(4.0, fillH - railThick * 2.0)

        local bRail = AddBorderFast(outer, targetCanvas, mx, my, fillW, fillH, railCol, zBase)
        local bBed = AddBorderFast(outer, targetCanvas, mx, my, bedW, bedH, bgCol, zBase + 1)
        if outWidgets then
            if bRail then table.insert(outWidgets, bRail) end
            if bBed then table.insert(outWidgets, bBed) end
        end

        -- Single crisp directional chevron (2 borders) rotated to yawDeg
        local armLen = math.max(6.0, math.min(pxW, pxH) * 0.30)
        local armThick = math.max(1.8, math.min(2.8, math.min(pxW, pxH) * 0.065))
        local halfArm = armLen * 0.3536
        local rad = math.rad(yawDeg or 0.0)
        local cosA, sinA = math.cos(rad), math.sin(rad)
        for _, sign in ipairs({ -1.0, 1.0 }) do
            local lx = -halfArm * 0.2
            local ly = sign * halfArm
            local rx = lx * cosA - ly * sinA
            local ry = lx * sinA + ly * cosA
            local bar = AddBorderFast(outer, targetCanvas, mx + rx, my + ry, armLen, armThick, arrowCol, zBase + 2)
            if bar then
                pcall(function()
                    bar:SetRenderTransformPivot(ALIGN_CENTER)
                    if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle((yawDeg or 0.0) - sign * 45.0) end
                end)
                if outWidgets then table.insert(outWidgets, bar) end
            end
        end
        return bBed
    end

    local bgCol = (spriteEntry and spriteEntry.bgCol) or GetColorForMachine(cat)
    local bdrCol = (spriteEntry and spriteEntry.borderCol) or { R = 0.08, G = 0.10, B = 0.14, A = 1.0 }
    if isGhost then
        bgCol = validGhost and COLORS.GhostValid or COLORS.GhostInvalid
        bdrCol = validGhost and COLORS.GhostBorderOk or COLORS.GhostBorderBad
    end

    -- Outer subtle frame border + full-footprint colored fill covering the entire machine rectangle
    local bdrBox = AddBorderFast(outer, targetCanvas, mx, my, math.max(6.0, pxW), math.max(6.0, pxH), bdrCol, zBase)
    local fillBox = AddBorderFast(outer, targetCanvas, mx, my, fillW, fillH, bgCol, zBase + 1)
    if outWidgets then
        if bdrBox then table.insert(outWidgets, bdrBox) end
        if fillBox then table.insert(outWidgets, fillBox) end
    end

    -- Centered 2D build-menu machine asset inside the colored rectangle
    if spriteEntry and Core.IsValidObj(spriteEntry.tex) then
        local img = CreateRawFast(PATHS.ImageClass, outer)
        if Core.IsValidObj(img) then
            local shiftUp = (hasBottomOverlay and pxH >= 52.0)
            local iconDim
            if spriteEntry.fullTileTex then
                iconDim = math.max(6.0, math.min(fillW, fillH))
            else
                local availH = shiftUp and (fillH * 0.56) or (fillH * 0.82)
                local availW = fillW * 0.82
                iconDim = math.max(6.0, math.min(availW, availH))
            end
            local iconY = shiftUp and (my - fillH * 0.17) or my
            pcall(function()
                img:SetVisibility(3)
                img:SetBrushFromTexture(spriteEntry.tex, false)
                if isGhost then
                    SetImageWidgetOpacity(img, validGhost and { R = 0.85, G = 1.0, B = 1.0, A = 0.72 } or { R = 1.0, G = 0.5, B = 0.5, A = 0.72 })
                else
                    SetImageWidgetOpacity(img, { R = 1.0, G = 1.0, B = 1.0, A = 1.0 })
                end
                if spriteEntry.directional and math.abs(yawDeg or 0.0) > 0.1 and img.SetRenderTransformAngle then
                    img:SetRenderTransformAngle(yawDeg)
                end
            end)
            local islot = targetCanvas:AddChildToCanvas(img)
            SetCanvasSlot(islot, mx, iconY, iconDim, iconDim, 0.5, 0.5, zBase + 2)
            if outWidgets then table.insert(outWidgets, img) end
        end
    end

    return fillBox
end

local function AddMiniChevronAt(outer, canvas, cx, cy, armLen, armThick, yawDeg, col, zOrder, outWidgets)
    local halfArm = armLen * 0.3536
    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    for _, sign in ipairs({ -1.0, 1.0 }) do
        local lx = -halfArm * 0.2
        local ly = sign * halfArm
        local rx = lx * cosA - ly * sinA
        local ry = lx * sinA + ly * cosA
        local bar = AddBorderFast(outer, canvas, cx + rx, cy + ry, armLen, armThick, col, zOrder)
        if bar then
            pcall(function()
                bar:SetRenderTransformPivot(ALIGN_CENTER)
                if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle((yawDeg or 0.0) - sign * 45.0) end
            end)
            if outWidgets then table.insert(outWidgets, bar) end
        end
    end
end

local YELLOW_CHEVRON_COL = { R = 1.0, G = 0.86, B = 0.14, A = 0.98 }
local function AddSplitterOrBalancerChevrons(outer, canvas, mx, my, pxW, pxH, yawDeg, clsLow, zOrder, outWidgets)
    local isSplitter = clsLow:find("splitter", 1, true) ~= nil
    local isBalancer = clsLow:find("balancer", 1, true) ~= nil
    if not isSplitter and not isBalancer then return end

    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    local function toCanvas(lx, ly)
        return mx + (lx * cosA - ly * sinA), my + (lx * sinA + ly * cosA)
    end

    -- Local unrotated dimensions (yaw=0 -> forward is +X, right is +Y)
    local norm = (math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
    local unrotW = (norm == 1 or norm == 3) and pxH or pxW
    local unrotH = (norm == 1 or norm == 3) and pxW or pxH
    local armLen = math.max(5.0, math.min(unrotW, unrotH) * 0.20)
    local armThick = math.max(1.6, math.min(2.4, armLen * 0.26))

    if isSplitter then
        -- Splitter (1x1): 4 sides -> back (-X) input facing inward (+X), front (+X) & left (-Y) & right (+Y) outputs facing outward
        local edgeX = unrotW * 0.38
        local edgeY = unrotH * 0.38
        local bx, by = toCanvas(-edgeX, 0.0)
        AddMiniChevronAt(outer, canvas, bx, by, armLen, armThick, (yawDeg or 0.0), YELLOW_CHEVRON_COL, zOrder, outWidgets)
        local fx, fy = toCanvas(edgeX, 0.0)
        AddMiniChevronAt(outer, canvas, fx, fy, armLen, armThick, (yawDeg or 0.0), YELLOW_CHEVRON_COL, zOrder, outWidgets)
        local lx, ly = toCanvas(0.0, -edgeY)
        AddMiniChevronAt(outer, canvas, lx, ly, armLen, armThick, (yawDeg or 0.0) - 90.0, YELLOW_CHEVRON_COL, zOrder, outWidgets)
        local rx, ry = toCanvas(0.0, edgeY)
        AddMiniChevronAt(outer, canvas, rx, ry, armLen, armThick, (yawDeg or 0.0) + 90.0, YELLOW_CHEVRON_COL, zOrder, outWidgets)
    elseif isBalancer then
        -- Belt Balancer (2x1): 2 main sides -> 2 inputs on back (-X) facing inward (+X), 2 outputs on front (+X) facing outward (+X)
        local edgeX = unrotW * 0.36
        local laneY = unrotH * 0.25
        for _, sideSign in ipairs({ -1.0, 1.0 }) do
            local ix, iy = toCanvas(-edgeX, sideSign * laneY)
            AddMiniChevronAt(outer, canvas, ix, iy, armLen, armThick, (yawDeg or 0.0), YELLOW_CHEVRON_COL, zOrder, outWidgets)
            local ox, oy = toCanvas(edgeX, sideSign * laneY)
            AddMiniChevronAt(outer, canvas, ox, oy, armLen, armThick, (yawDeg or 0.0), YELLOW_CHEVRON_COL, zOrder, outWidgets)
        end
    end
end

local REPLACE_ICON_COL = { R = 0.85, G = 0.97, B = 1.00, A = 0.98 }
local function DrawReplaceIcon(outer, canvas, cx, cy, pxW, pxH, zOrder)
    -- Crisp opposing horizontal swap arrows (⇄) centered on the blue replace ghost
    local dim = math.max(12.0, math.min(pxW, pxH) * 0.44)
    local barLen = dim * 0.72
    local thick = math.max(2.0, dim * 0.14)
    local offY = dim * 0.24
    local tipLen = math.max(4.5, dim * 0.30)

    -- Top arrow pointing RIGHT (→)
    AddBorderFast(outer, canvas, cx - dim * 0.04, cy - offY, barLen, thick, REPLACE_ICON_COL, zOrder)
    AddMiniChevronAt(outer, canvas, cx + barLen * 0.42, cy - offY, tipLen, thick, 0.0, REPLACE_ICON_COL, zOrder)
    -- Bottom arrow pointing LEFT (←)
    AddBorderFast(outer, canvas, cx + dim * 0.04, cy + offY, barLen, thick, REPLACE_ICON_COL, zOrder)
    AddMiniChevronAt(outer, canvas, cx - barLen * 0.42, cy + offY, tipLen, thick, 180.0, REPLACE_ICON_COL, zOrder)
end

local function RenderBorderOutline(outer, canvas, cx, cy, w, h, thickness, col, zOrder)
    local t = thickness or 2.0
    local halfW = w * 0.5
    local halfH = h * 0.5
    AddBorderFast(outer, canvas, cx, cy - halfH, w, t, col, zOrder)
    AddBorderFast(outer, canvas, cx, cy + halfH, w, t, col, zOrder)
    AddBorderFast(outer, canvas, cx - halfW, cy, t, h, col, zOrder)
    AddBorderFast(outer, canvas, cx + halfW, cy, t, h, col, zOrder)
end

local function CountTableKeys(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

UpdateStatusBanner = function(textOverride)
    if not MapUI then return end
    local selCount = CountTableKeys(SelectedMachines) + CountTableKeys(SelectedGhosts)
    if Core.IsValidObj(MapUI.SelPillWrap) and Core.IsValidObj(MapUI.SelPillText) then
        pcall(function()
            MapUI.SelPillText:SetText(Core.MakeText(string.format("Selected: %d", selCount)))
            MapUI.SelPillWrap:SetVisibility(selCount > 0 and 0 or 1)
        end)
    end
    local delCount = CountTableKeys(PendingDeletes)
    if Core.IsValidObj(MapUI.DelPillWrap) and Core.IsValidObj(MapUI.DelPillText) then
        pcall(function()
            MapUI.DelPillText:SetText(Core.MakeText(string.format("Deleting: %d", delCount)))
            MapUI.DelPillWrap:SetVisibility(delCount > 0 and 0 or 1)
        end)
    end
    if Core.IsValidObj(MapUI.ModePillWrap) and Core.IsValidObj(MapUI.ModePillText) then
        local modeMsg = textOverride
        if not modeMsg and InteractionMode == "Paste" then
            modeMsg = string.format("Pasting %d  (%d°)", #Clipboard, PendingRotationDeg)
        end
        pcall(function()
            if modeMsg and modeMsg ~= "" then
                MapUI.ModePillText:SetText(Core.MakeText(modeMsg))
                MapUI.ModePillWrap:SetVisibility(0)
            else
                MapUI.ModePillWrap:SetVisibility(1)
            end
        end)
    end
    local hasSelection = (selCount > 0)
    local isPasting = (InteractionMode == "Paste" and #Clipboard > 0)
        or (InteractionMode == "Place" and Core.IsValidObj(PendingBuildable))
    if Core.IsValidObj(MapUI.HintSelectLabel) then
        pcall(function() MapUI.HintSelectLabel:SetText(Core.MakeText(isPasting and "Paste" or "Box Select")) end)
    end
    if Core.IsValidObj(MapUI.HintCopyRow) then
        pcall(function() MapUI.HintCopyRow:SetVisibility(hasSelection and 3 or 1) end)
    end
    if Core.IsValidObj(MapUI.HintDeleteRow) then
        pcall(function() MapUI.HintDeleteRow:SetVisibility(hasSelection and 3 or 1) end)
    end
    if Core.IsValidObj(MapUI.HintRotateRow) then
        pcall(function() MapUI.HintRotateRow:SetVisibility(isPasting and 3 or 1) end)
    end
    if Core.IsValidObj(MapUI.HintCancelRow) then
        pcall(function() MapUI.HintCancelRow:SetVisibility(isPasting and 3 or 1) end)
    end
end

local APPLY_BG_ENABLED   = { R = 0.74, G = 0.48, B = 0.06, A = 0.96 }
local APPLY_BG_DISABLED  = { R = 0.15, G = 0.17, B = 0.20, A = 0.75 }
local APPLY_TXT_DISABLED = { R = 0.60, G = 0.64, B = 0.70, A = 0.85 }

local COST_TXT_LACKING = { R = 0.6105, G = 0.0000, B = 0.0612, A = 1.00 } -- #cd0046 in sRGB
local COST_TXT_REFUND  = { R = 0.1400, G = 0.7200, B = 0.2400, A = 1.00 }
local COST_TXT_OK      = { R = 0.8800, G = 0.9200, B = 0.9600, A = 1.00 }

local function SetWBPTextColor(w, col)
    if not Core.IsValidObj(w) or not col then return end
    pcall(function()
        if w.SetColorAndOpacity then
            w:SetColorAndOpacity(col)
        end
        if Core.IsValidObj(w.TextBlock) and w.TextBlock.SetColorAndOpacity then
            w.TextBlock:SetColorAndOpacity({ SpecifiedColor = col, ColorUseRule = 0 })
        end
    end)
end

local CachedUserWidgetClasses = {}
local CachedWblCDO = nil

local function CreateUserWidgetFast(classPath, owner, pc)
    if not Core.IsValidObj(owner) then return nil end
    if not Core.IsValidObj(CachedWblCDO) then
        CachedWblCDO = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    end
    local cls = CachedUserWidgetClasses[classPath]
    if not Core.IsValidObj(cls) then
        cls = Core.FindOrLoadClass(classPath)
        if Core.IsValidObj(cls) then
            CachedUserWidgetClasses[classPath] = cls
        end
    end
    if not (Core.IsValidObj(CachedWblCDO) and Core.IsValidObj(cls)) then return nil end
    local ok, w = pcall(function() return CachedWblCDO:Create(owner, cls, pc) end)
    return (ok and Core.IsValidObj(w)) and w or nil
end

local function BuildCostSummarySignature(summary)
    if not summary or not summary.entries or #summary.entries == 0 then return "" end
    local parts = { summary.isCreative and "C" or "S" }
    for _, e in ipairs(summary.entries) do
        local iAddr = Core.IsValidObj(e.item) and e.item:GetAddress() or 0
        parts[#parts + 1] = string.format("%s:%d:%d:%d", tostring(iAddr), e.net or 0, e.have or 0, e.lacking and 1 or 0)
    end
    return table.concat(parts, "|")
end

local function RefreshModificationCostPanel(summary, freshPC)
    if not MapUI or not Core.IsValidObj(MapUI.CostPanel) or not Core.IsValidObj(MapUI.CostListVBox) then return end
    local entries = summary and summary.entries or {}
    if #entries == 0 then
        MapUI.LastCostSig = ""
        pcall(function() MapUI.CostPanel:SetVisibility(1) end) -- Collapsed
        return
    end

    local sig = BuildCostSummarySignature(summary)
    if MapUI.LastCostSig == sig then
        pcall(function() MapUI.CostPanel:SetVisibility(0) end)
        return
    end
    MapUI.LastCostSig = sig

    pcall(function() MapUI.CostListVBox:ClearChildren() end)
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = Core.IsValidObj(freshPC) and freshPC or Core.GetLocalPlayerController()
    local isCreative = summary.isCreative

    for idx, entry in ipairs(entries) do
        local row = CreateRawFast(PATHS.HorizontalBoxClass, outer)
        if Core.IsValidObj(row) then
            pcall(function() row:SetVisibility(3) end)

            -- Native item icon (24x24 WBP_Item_C)
            local iconSb = CreateRawFast(PATHS.SizeBoxClass, outer)
            local itemW = CreateUserWidgetFast(PATHS.WBPItemClass, MapUI.Window, pc)
            if Core.IsValidObj(iconSb) and Core.IsValidObj(itemW) then
                pcall(function()
                    iconSb:SetWidthOverride(24.0)
                    iconSb:SetHeightOverride(24.0)
                    iconSb:SetVisibility(3)
                    itemW:SetVisibility(3)
                    itemW:SetItem(entry.item)
                    iconSb:AddChild(itemW)
                end)
                local iSlot = row:AddChildToHorizontalBox(iconSb)
                if Core.IsValidObj(iSlot) then
                    pcall(function() iSlot:SetVerticalAlignment(2) end)
                end
            end

            -- Net cost label (e.g. "0/40x", "10/10x", "-5x", or "∞/40x" in Creative Mode)
            local amtStr
            local amtCol
            if entry.net < 0 then
                amtStr = string.format("%dx", entry.net)
                amtCol = COST_TXT_REFUND
            elseif isCreative then
                amtStr = string.format("∞/%dx", entry.net)
                amtCol = COST_TXT_OK
            else
                amtStr = string.format("%d/%dx", entry.have, entry.net)
                amtCol = entry.lacking and COST_TXT_LACKING or COST_TXT_OK
            end

            local amtTxt = CreateUserWidgetFast(PATHS.WBPTextClass, MapUI.Window, pc)
            if Core.IsValidObj(amtTxt) then
                pcall(function()
                    amtTxt:SetVisibility(3)
                    amtTxt:SetSize(11)
                    amtTxt:SetText(Core.MakeText(amtStr))
                end)
                SetWBPTextColor(amtTxt, amtCol)
                local aSlot = row:AddChildToHorizontalBox(amtTxt)
                if Core.IsValidObj(aSlot) then
                    pcall(function()
                        aSlot:SetVerticalAlignment(2)
                        aSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end
            end

            -- Item display name (red #cd0046 when lacking so missing materials stand out clearly)
            local nameTxt = CreateUserWidgetFast(PATHS.WBPTextClass, MapUI.Window, pc)
            if Core.IsValidObj(nameTxt) then
                pcall(function()
                    nameTxt:SetVisibility(3)
                    nameTxt:SetSize(11)
                    nameTxt:SetText(Core.MakeText(entry.name))
                end)
                SetWBPTextColor(nameTxt, entry.lacking and COST_TXT_LACKING or COLORS.PlayerLocal)
                local nSlot = row:AddChildToHorizontalBox(nameTxt)
                if Core.IsValidObj(nSlot) then
                    pcall(function()
                        nSlot:SetVerticalAlignment(2)
                        nSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end
            end

            local rSlot = MapUI.CostListVBox:AddChildToVerticalBox(row)
            if Core.IsValidObj(rSlot) then
                pcall(function()
                    rSlot:SetHorizontalAlignment(1)
                    rSlot:SetPadding({ Left = 0.0, Top = (idx == 1) and 0.0 or 5.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end
    end

    pcall(function() MapUI.CostPanel:SetVisibility(0) end) -- Visible
end

UpdateActionBar = function(force)
    if not MapUI then return end
    local delCount = CountTableKeys(PendingDeletes)
    local pendingN = #PendingGhosts + delCount
    local sig = string.format("%d:%d:%s", #PendingGhosts, delCount, tostring(ApplyInProgress))
    if not force and Perf.LastPendingSig == sig then
        return
    end
    Perf.LastPendingSig = sig
    local pc = Core.GetLocalPlayerController()
    local matSummary = (pendingN > 0) and ComputePendingMaterialSummary(pc) or { isCreative = false, hasMissing = false, entries = {} }
    local hasMissing = (pendingN > 0) and (matSummary.hasMissing == true)
    local canApply = (pendingN > 0) and (not ApplyInProgress) and (not hasMissing)

    RefreshModificationCostPanel(matSummary, pc)

    if Core.IsValidObj(MapUI.ValidationBox) then
        pcall(function()
            MapUI.ValidationBox:SetVisibility(hasMissing and 0 or 1) -- Visible vs Collapsed
        end)
    end
    if Core.IsValidObj(MapUI.ApplyBtnText) then
        pcall(function()
            if pendingN > 0 then
                MapUI.ApplyBtnText:SetText(Core.MakeText(string.format("Apply Changes (%d)", pendingN)))
            else
                MapUI.ApplyBtnText:SetText(Core.MakeText("Apply Changes"))
            end
            if Core.IsValidObj(MapUI.ApplyBtnText.TextBlock) and MapUI.ApplyBtnText.TextBlock.SetColorAndOpacity then
                MapUI.ApplyBtnText.TextBlock:SetColorAndOpacity({
                    SpecifiedColor = canApply and COLORS.PlayerLocal or APPLY_TXT_DISABLED,
                    ColorUseRule = 0,
                })
            end
        end)
    end
    if Core.IsValidObj(MapUI.ApplyBtnWidget) then
        pcall(function()
            if MapUI.ApplyBtnWidget.SetBackgroundColour then
                MapUI.ApplyBtnWidget:SetBackgroundColour(canApply and APPLY_BG_ENABLED or APPLY_BG_DISABLED)
            end
            if MapUI.ApplyBtnWidget.SetIsEnabled then
                MapUI.ApplyBtnWidget:SetIsEnabled(canApply)
            end
        end)
    end
    if Core.IsValidObj(MapUI.ApplyBtn) then
        pcall(function()
            if MapUI.ApplyBtn.SetRenderOpacity then
                MapUI.ApplyBtn:SetRenderOpacity(canApply and 1.0 or 0.55)
            end
        end)
    end
    if Core.IsValidObj(MapUI.DiscardBtn) then
        pcall(function()
            MapUI.DiscardBtn:SetVisibility(pendingN > 0 and 0 or 1) -- Visible vs Collapsed
        end)
    end
end

local function FitViewTransformToFloor()
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then return end

    local minX, maxX = math.huge, -math.huge
    local minY, maxY = math.huge, -math.huge
    for _, pe in ipairs(floor.platforms) do
        local b = pe.bounds
        if b.cx - b.ex < minX then minX = b.cx - b.ex end
        if b.cx + b.ex > maxX then maxX = b.cx + b.ex end
        if b.cy - b.ey < minY then minY = b.cy - b.ey end
        if b.cy + b.ey > maxY then maxY = b.cy + b.ey end
    end

    local cx, cy = (minX + maxX) * 0.5, (minY + maxY) * 0.5
    if floor.machines and #floor.machines > 0 then
        local xs, ys = {}, {}
        for _, me in ipairs(floor.machines) do
            table.insert(xs, me.x)
            table.insert(ys, me.y)
            if me.x - 300.0 < minX then minX = me.x - 300.0 end
            if me.x + 300.0 > maxX then maxX = me.x + 300.0 end
            if me.y - 300.0 < minY then minY = me.y - 300.0 end
            if me.y + 300.0 > maxY then maxY = me.y + 300.0 end
        end
        table.sort(xs)
        table.sort(ys)
        cx = xs[math.ceil(#xs * 0.5)]
        cy = ys[math.ceil(#ys * 0.5)]
    end

    -- Center on local player's position if on this floor; otherwise fall back to median of machines/platforms
    local centeredOnPlayer = false
    pcall(function()
        local pc = MapUI and MapUI.PC or Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and Core.IsValidObj(pc.Pawn) then
            local loc = pc.Pawn:K2_GetActorLocation()
            if loc and type(loc.X) == "number" then
                local plx, ply, plz = StationData.WorldToStationLocal(CurrentFrameXform, loc.X, loc.Y or 0.0, loc.Z or 0.0, nil, nil, nil)
                if math.abs(plz - floor.z) <= 260.0 then
                    cx, cy = plx, ply
                    centeredOnPlayer = true
                end
            end
        end
    end)

    local spanX = math.max(1200.0, maxX - minX)
    local spanY = math.max(1200.0, maxY - minY)
    local pad = 90.0
    local availW = math.max(300.0, ViewTransform.canvasW - pad)
    local availH = math.max(300.0, ViewTransform.canvasH - pad)

    -- Start moderately zoomed in around the player (~36px/cell) so only the nearby area loads initially
    local fitted = math.min(availW / spanX, availH / spanY)
    local minStartScale = centeredOnPlayer and 0.36 or 0.28
    ViewTransform.cx = cx
    ViewTransform.cy = cy
    ViewTransform.scale = Core.Clamp(math.max(fitted, minStartScale), 0.14, 0.90)
    ViewTransform.floorZ = floor.z
    ViewTransform.hasFitted = true
end

local CachedSlateLibCDO = nil
local CachedWidgetLayoutLibCDO = nil
local function GetSlateLibCDO()
    if not Core.IsValidObj(CachedSlateLibCDO) then
        CachedSlateLibCDO = Core.GetCDO(PATHS.SlateLibCDO)
    end
    return CachedSlateLibCDO
end
local function GetWidgetLayoutLibCDO()
    if not Core.IsValidObj(CachedWidgetLayoutLibCDO) then
        CachedWidgetLayoutLibCDO = Core.GetCDO(PATHS.WidgetLayoutLibCDO)
    end
    return CachedWidgetLayoutLibCDO
end

local function MeasureMapCanvasSize()
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return false end
    local slateLib = GetSlateLibCDO()
    local layoutLib = GetWidgetLayoutLibCDO()
    local pc = Core.GetLocalPlayerController()

    if Core.IsValidObj(slateLib) and slateLib.GetLocalSize then
        for _, wgt in ipairs({ MapUI.MapCanvas, MapUI.MapBg }) do
            if Core.IsValidObj(wgt) and wgt.GetCachedGeometry then
                local ok, sz = pcall(function() return slateLib:GetLocalSize(wgt:GetCachedGeometry()) end)
                if ok and sz then
                    local w, h = tonumber(sz.X), tonumber(sz.Y)
                    if IsFiniteNum(w) and IsFiniteNum(h) and w > 120.0 and h > 120.0 then
                        local changed = (math.abs(w - ViewTransform.canvasW) > 4.0 or math.abs(h - ViewTransform.canvasH) > 4.0)
                        ViewTransform.canvasW = w
                        ViewTransform.canvasH = h
                        return changed
                    end
                end
            end
        end
    end

    if Core.IsValidObj(layoutLib) and Core.IsValidObj(pc) and layoutLib.GetViewportSize then
        local okV, rawVp = pcall(function() return layoutLib:GetViewportSize(pc) end)
        local vpScale = 1.0
        pcall(function()
            if layoutLib.GetViewportScale then
                local s = tonumber(layoutLib:GetViewportScale(pc))
                if IsFiniteNum(s) and s > 0.05 then vpScale = s end
            end
        end)
        if okV and rawVp and IsFiniteNum(tonumber(rawVp.X)) and IsFiniteNum(tonumber(rawVp.Y)) and rawVp.X > 100 then
            local umgW = rawVp.X / vpScale
            local umgH = rawVp.Y / vpScale
            local w = umgW
            local h = umgH
            if w > 120.0 and h > 120.0 then
                local changed = (math.abs(w - ViewTransform.canvasW) > 4.0 or math.abs(h - ViewTransform.canvasH) > 4.0)
                ViewTransform.canvasW = w
                ViewTransform.canvasH = h
                return changed
            end
        end
    end
    return false
end

local function EnsureDynOverlayPool(outer, pc)
    if not MapUI or not Core.IsValidObj(MapUI.OverlayCanvas) then return nil end
    local pool = MapUI.DynPool
    if pool and Core.IsValidObj(pool.MarqueeFill) and Core.IsValidObj(pool.TipBorder) then
        return pool
    end
    ClearCanvasChildren(MapUI.OverlayCanvas)

    local function makeBox(col, z)
        local b = CreateRawFast(PATHS.BorderClass, outer)
        if not Core.IsValidObj(b) then return nil, nil end
        pcall(function()
            b:SetBrushColor(col)
            b:SetVisibility(1)
        end)
        local s = MapUI.OverlayCanvas:AddChildToCanvas(b)
        if Core.IsValidObj(s) then pcall(function() s:SetZOrder(z) end) end
        return b, s
    end

    local mFill, mFillSlot = makeBox(COLORS.BoxSelectFill, 50)
    local mTop, mTopSlot   = makeBox(COLORS.BoxSelectLine, 51)
    local mBot, mBotSlot   = makeBox(COLORS.BoxSelectLine, 51)
    local mLeft, mLeftSlot = makeBox(COLORS.BoxSelectLine, 51)
    local mRight, mRightSlot = makeBox(COLORS.BoxSelectLine, 51)

    local tipBorder = CreateRawFast(PATHS.BorderClass, outer)
    local tipHBox   = CreateRawFast(PATHS.HorizontalBoxClass, outer)
    local tipIcon   = Core.CreateUserWidget(PATHS.WBPItemClass, MapUI.Window, pc)
    local tipTxt    = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
    local tipSlot   = nil
    if Core.IsValidObj(tipBorder) and Core.IsValidObj(tipHBox) and Core.IsValidObj(tipIcon) and Core.IsValidObj(tipTxt) then
        pcall(function()
            tipBorder:SetBrushColor(COLORS.TooltipBg)
            tipBorder:SetPadding({ Left = 6.0, Top = 4.0, Right = 8.0, Bottom = 4.0 })
            tipBorder:SetVisibility(1)
            tipIcon:SetIconSize(22.0)
            tipIcon:SetVisibility(1)
            tipTxt:SetSize(12)
            local iSlot = tipHBox:AddChildToHorizontalBox(tipIcon)
            if Core.IsValidObj(iSlot) then
                iSlot:SetVerticalAlignment(2)
                iSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 6.0, Bottom = 0.0 })
            end
            local tSlot = tipHBox:AddChildToHorizontalBox(tipTxt)
            if Core.IsValidObj(tSlot) then tSlot:SetVerticalAlignment(2) end
            tipBorder:AddChild(tipHBox)
            tipSlot = MapUI.OverlayCanvas:AddChildToCanvas(tipBorder)
        end)
    end

    pool = {
        MarqueeFill = mFill, MarqueeFillSlot = mFillSlot,
        MarqueeTop = mTop, MarqueeTopSlot = mTopSlot,
        MarqueeBot = mBot, MarqueeBotSlot = mBotSlot,
        MarqueeLeft = mLeft, MarqueeLeftSlot = mLeftSlot,
        MarqueeRight = mRight, MarqueeRightSlot = mRightSlot,
        MarqueeVis = false,
        TipBorder = tipBorder, TipSlot = tipSlot,
        TipIcon = tipIcon, TipTxt = tipTxt,
        TipVis = false, TipIconVis = false,
        LastTipText = nil, LastTipItemAddr = nil,
    }
    MapUI.DynPool = pool
    return pool
end

RefreshDynamicOverlay = function(preHoveredPort, preHoveredMachine, hasPreHover)
    if not MapUI or not Core.IsValidObj(MapUI.OverlayCanvas) then return end

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = Core.GetLocalPlayerController()
    local pool = EnsureDynOverlayPool(outer, pc)

    -- 1. Box-select live marquee (pooled widgets, zero allocations per frame)
    if pool then
        if MouseState.lDraggingBox and MouseState.lastCursorMx and MouseState.lastCursorMy then
            local x1 = math.min(MouseState.lStartX, MouseState.lastCursorMx)
            local x2 = math.max(MouseState.lStartX, MouseState.lastCursorMx)
            local y1 = math.min(MouseState.lStartY, MouseState.lastCursorMy)
            local y2 = math.max(MouseState.lStartY, MouseState.lastCursorMy)
            local bw = math.max(4.0, x2 - x1)
            local bh = math.max(4.0, y2 - y1)
            local bx = (x1 + x2) * 0.5
            local by = (y1 + y2) * 0.5
            local th = 2.0

            SetCanvasSlot(pool.MarqueeFillSlot, bx, by, bw, bh, 0.5, 0.5, 50)
            SetCanvasSlot(pool.MarqueeTopSlot, bx, y1 + th * 0.5, bw, th, 0.5, 0.5, 51)
            SetCanvasSlot(pool.MarqueeBotSlot, bx, y2 - th * 0.5, bw, th, 0.5, 0.5, 51)
            SetCanvasSlot(pool.MarqueeLeftSlot, x1 + th * 0.5, by, th, bh, 0.5, 0.5, 51)
            SetCanvasSlot(pool.MarqueeRightSlot, x2 - th * 0.5, by, th, bh, 0.5, 0.5, 51)
            if not pool.MarqueeVis then
                pool.MarqueeVis = true
                for _, w in ipairs({ pool.MarqueeFill, pool.MarqueeTop, pool.MarqueeBot, pool.MarqueeLeft, pool.MarqueeRight }) do
                    if Core.IsValidObj(w) then pcall(function() w:SetVisibility(3) end) end
                end
            end
        elseif pool.MarqueeVis then
            pool.MarqueeVis = false
            for _, w in ipairs({ pool.MarqueeFill, pool.MarqueeTop, pool.MarqueeBot, pool.MarqueeLeft, pool.MarqueeRight }) do
                if Core.IsValidObj(w) then pcall(function() w:SetVisibility(1) end) end
            end
        end
    end

    -- 2. Cursor ghost previews (Place mode or repeatable Factorio-style Paste mode)
    -- Rendered ONCE into MapUI.GhostPreviewCanvas (inside bgPanZoom) and moved in O(1) via SetPosition on mouse move!
    local showGhostPreview = (InteractionMode == "Place" or InteractionMode == "Paste")
        and MouseState.lastCursorMx and MouseState.lastCursorMy
        and MouseState.lastCursorMx >= 0 and MouseState.lastCursorMx <= ViewTransform.canvasW
        and MouseState.lastCursorMy >= 0 and MouseState.lastCursorMy <= ViewTransform.canvasH
        and Core.IsValidObj(MapUI.GhostPreviewCanvas) and Core.IsValidObj(MapUI.GhostPreviewSlot)

    if showGhostPreview then
        local wx, wy = CanvasToWorld(MouseState.lastCursorMx, MouseState.lastCursorMy)
        local sig = nil
        local anchorSx, anchorSy = wx, wy
        local anchorValid = true

        if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
            local cx, cy = StationData.GetMachineFootprintCells(nil, PendingBuildable)
            sig = string.format("Place:%s:%d", tostring(PendingBuildable:GetAddress()), PendingRotationDeg)
            anchorSx, anchorSy = SnapWorldToMachineGrid(wx, wy, cx, cy, PendingRotationDeg)
            anchorValid = IsPointOverAnyFloorModule(anchorSx, anchorSy, floor)
                and (not IsFootprintBlockedByWall(anchorSx, anchorSy, cx, cy, PendingRotationDeg, floor))
            if GhostPreviewSig ~= sig then
                GhostPreviewSig = sig
                ClearCanvasChildren(MapUI.GhostPreviewCanvas)
                local clsKey = select(1, GetMachineClassKey(nil, PendingBuildable))
                local sprite = RequestMachineSprite(clsKey, nil, "Other", PendingBuildable)
                local rx, ry = GetRotatedCellDims(cx, cy, PendingRotationDeg)
                local pxW = rx * BASE_CELL_PX
                local pxH = ry * BASE_CELL_PX
                CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.GhostPreviewCanvas, 0.0, 0.0, pxW, pxH, PendingRotationDeg, "Other", sprite, true, true, 55, false)
                RenderBorderOutline(outer, MapUI.GhostPreviewCanvas, 0.0, 0.0, pxW, pxH, 2.5, COLORS.GhostBorderOk, 56)
            end
        elseif InteractionMode == "Paste" and #Clipboard > 0 then
            sig = string.format("Paste:%d:%d", ClipboardGen, PendingRotationDeg)
            anchorSx = SnapAxisToCellGrid(wx, ViewTransform.gridOriginX, 1)
            anchorSy = SnapAxisToCellGrid(wy, ViewTransform.gridOriginY, 1)
            if GhostPreviewSig ~= sig then
                GhostPreviewSig = sig
                Perf.GhostPreviewGen = (Perf.GhostPreviewGen or 0) + 1
                local myPreviewGen = Perf.GhostPreviewGen
                ClearCanvasChildren(MapUI.GhostPreviewCanvas)
                local rad = math.rad(PendingRotationDeg)
                local cosA, sinA = math.cos(rad), math.sin(rad)
                local clipSnap = Clipboard
                local skipBeltOutline = (#clipSnap > 40)
                local pIdx = 1
                local totalP = #clipSnap

                local function pumpGhostPreview()
                    if myPreviewGen ~= Perf.GhostPreviewGen or GhostPreviewSig ~= sig or not IsMapOpen() or not MapUI or not Core.IsValidObj(MapUI.GhostPreviewCanvas) then
                        return
                    end
                    local budgetEnd = os.clock() + 0.0030
                    local built = 0
                    while pIdx <= totalP and (built < 12 or os.clock() < budgetEnd) and built < 50 do
                        local item = clipSnap[pIdx]
                        pIdx = pIdx + 1
                        built = built + 1
                        local rdx = item.dx * cosA - item.dy * sinA
                        local rdy = item.dx * sinA + item.dy * cosA
                        local fYaw = (item.yaw or 0.0) + PendingRotationDeg
                        local rx, ry = GetRotatedCellDims(item.cellsX or 1, item.cellsY or 1, fYaw)
                        local pxW = rx * BASE_CELL_PX
                        local pxH = ry * BASE_CELL_PX
                        local offBx = rdx * BASE_PX_PER_CM
                        local offBy = rdy * BASE_PX_PER_CM
                        local itemCat = item.cat or "Other"
                        CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.GhostPreviewCanvas, offBx, offBy, pxW, pxH, fYaw, itemCat, item.sprite, true, true, 55, false)
                        if not (skipBeltOutline and itemCat == "Conveyor") then
                            RenderBorderOutline(outer, MapUI.GhostPreviewCanvas, offBx, offBy, pxW, pxH, 2.5, COLORS.GhostBorderOk, 56)
                        end
                        local clsLow = (item.actorClsPath or ""):lower()
                        if clsLow:find("splitter", 1, true) or clsLow:find("balancer", 1, true) then
                            AddSplitterOrBalancerChevrons(outer, MapUI.GhostPreviewCanvas, offBx, offBy, pxW, pxH, fYaw, clsLow, 57)
                        elseif clsLow:find("underground", 1, true) then
                            AddMiniChevronAt(outer, MapUI.GhostPreviewCanvas, offBx, offBy, math.min(pxW, pxH) * 0.30, 2.2, fYaw, COLORS.GhostBorderOk, 57)
                            if item.pairDx and item.pairDy then
                                local rpdx = item.pairDx * cosA - item.pairDy * sinA
                                local rpdy = item.pairDx * sinA + item.pairDy * cosA
                                local pBx = offBx + rpdx * BASE_PX_PER_CM
                                local pBy = offBy + rpdy * BASE_PX_PER_CM
                                CreateMachineVisualWidget(MapUI.Window, pc, outer, MapUI.GhostPreviewCanvas, pBx, pBy, pxW, pxH, fYaw, itemCat, item.sprite, true, true, 55, false)
                                RenderBorderOutline(outer, MapUI.GhostPreviewCanvas, pBx, pBy, pxW, pxH, 2.5, COLORS.GhostBorderOk, 56)
                                AddMiniChevronAt(outer, MapUI.GhostPreviewCanvas, pBx, pBy, math.min(pxW, pxH) * 0.30, 2.2, fYaw, COLORS.GhostBorderOk, 57)
                                RenderDashedLine(outer, MapUI.GhostPreviewCanvas, offBx, offBy, pBx, pBy, COLORS.GhostBorderOk, 2.6, 10.0, 6.0, 58)
                                local linkAng = math.deg(math.atan(pBy - offBy, pBx - offBx))
                                AddMiniChevronAt(outer, MapUI.GhostPreviewCanvas, (offBx + pBx) * 0.5, (offBy + pBy) * 0.5, 10.0, 2.4, linkAng, COLORS.GhostBorderOk, 59)
                            end
                        end
                    end
                    if pIdx <= totalP then
                        ExecuteInGameThreadAfterFrames(1, pumpGhostPreview)
                    end
                end
                pumpGhostPreview()
            end
        else
            showGhostPreview = false
        end

        if showGhostPreview then
            local bx, by = WorldToBaseCanvas(anchorSx, anchorSy)
            pcall(function()
                MapUI.GhostPreviewSlot:SetPosition({ X = bx, Y = by })
                MapUI.GhostPreviewCanvas:SetRenderOpacity(anchorValid and 0.90 or 0.40)
                MapUI.GhostPreviewCanvas:SetVisibility(4)
            end)
        end
    end

    if not showGhostPreview and Core.IsValidObj(MapUI.GhostPreviewCanvas) then
        pcall(function() MapUI.GhostPreviewCanvas:SetVisibility(1) end)
    end

    -- 3. Hover tooltips (pooled widgets, zero allocations; reuses pre-resolved hover when provided)
    local hoveredMachine = nil
    local hoveredPort = nil
    if InteractionMode == "Select" and not MouseState.lDraggingBox and not MouseState.rPanning
        and MouseState.lastCursorMx and MouseState.lastCursorMy
        and MouseState.lastCursorMx >= 0 and MouseState.lastCursorMx <= ViewTransform.canvasW
        and MouseState.lastCursorMy >= 0 and MouseState.lastCursorMy <= ViewTransform.canvasH
    then
        if hasPreHover then
            hoveredPort = preHoveredPort
            hoveredMachine = preHoveredMachine
        else
            local wx, wy = CanvasToWorld(MouseState.lastCursorMx, MouseState.lastCursorMy)
            for _, rp in ipairs(RenderedPorts) do
                if math.abs(wx - rp.x) <= rp.halfW and math.abs(wy - rp.y) <= rp.halfH then
                    hoveredPort = rp
                    break
                end
            end
            if not hoveredPort then
                local bestD2 = math.huge
                for _, rm in ipairs(RenderedMachines) do
                    if math.abs(wx - rm.x) <= rm.halfW and math.abs(wy - rm.y) <= rm.halfH then
                        local d2 = (wx - rm.x) ^ 2 + (wy - rm.y) ^ 2
                        if d2 < bestD2 then
                            bestD2 = d2
                            hoveredMachine = rm
                        end
                    end
                end
            end
        end

        if pool and Core.IsValidObj(pool.TipBorder) and Core.IsValidObj(pool.TipTxt) then
            local tipLabel = nil
            local tipItem = nil
            local tipW = 195.0
            local tipH = 28.0
            if hoveredPort then
                tipLabel = "Item Port"
                if hoveredPort.isInput and not hoveredPort.isOutput then
                    tipLabel = "Item Port (Input)"
                elseif hoveredPort.isOutput and not hoveredPort.isInput then
                    tipLabel = "Item Port (Output)"
                elseif hoveredPort.isInput and hoveredPort.isOutput then
                    tipLabel = "Item Port (Input / Output)"
                end
                tipW = 195.0
                tipH = 28.0
            elseif hoveredMachine then
                local mLabel = hoveredMachine.displayName or "Machine"
                local carriedItem = (hoveredMachine.cat == "Conveyor") and StationData.GetPrimaryItemForMachine(hoveredMachine.machine) or nil
                if Core.IsValidObj(carriedItem) then
                    local itemName = "Item"
                    pcall(function()
                        if carriedItem.DisplayName then itemName = carriedItem.DisplayName:ToString()
                        elseif carriedItem.Name then itemName = carriedItem.Name:ToString()
                        else itemName = SafeFNameStr(carriedItem) or "Item" end
                    end)
                    tipLabel = mLabel .. " - " .. itemName
                    tipItem = carriedItem
                    tipW = math.max(190.0, math.min(340.0, #tipLabel * 7.5 + 48.0))
                    tipH = 32.0
                else
                    tipLabel = mLabel
                    tipW = math.max(120.0, math.min(300.0, #mLabel * 7.8 + 24.0))
                    tipH = 28.0
                end
            end

            if tipLabel then
                pcall(function()
                    if pool.LastTipText ~= tipLabel then
                        pool.TipTxt:SetText(Core.MakeText(tipLabel))
                        pool.LastTipText = tipLabel
                    end
                    if Core.IsValidObj(tipItem) and Core.IsValidObj(pool.TipIcon) then
                        local iAddr = tipItem:GetAddress()
                        if pool.LastTipItemAddr ~= iAddr then
                            pool.TipIcon:SetItem(tipItem)
                            pool.LastTipItemAddr = iAddr
                        end
                        if not pool.TipIconVis then
                            pool.TipIcon:SetVisibility(3)
                            pool.TipIconVis = true
                        end
                    elseif pool.TipIconVis and Core.IsValidObj(pool.TipIcon) then
                        pool.TipIcon:SetVisibility(1)
                        pool.TipIconVis = false
                    end
                    local tx = Core.Clamp(MouseState.lastCursorMx + 14.0, 8.0, math.max(8.0, ViewTransform.canvasW - tipW - 8.0))
                    local ty = Core.Clamp(MouseState.lastCursorMy - 8.0, tipH + 6.0, ViewTransform.canvasH - 8.0)
                    SetCanvasSlot(pool.TipSlot, tx, ty, tipW, tipH, 0.0, 1.0, 80)
                    if not pool.TipVis then
                        pool.TipBorder:SetVisibility(3)
                        pool.TipVis = true
                    end
                end)
            elseif pool.TipVis then
                pool.TipVis = false
                pcall(function() pool.TipBorder:SetVisibility(1) end)
            end
        end
    elseif pool and pool.TipVis and Core.IsValidObj(pool.TipBorder) then
        pool.TipVis = false
        pcall(function() pool.TipBorder:SetVisibility(1) end)
    end

    LastHoveredPortIdx = hoveredPort and hoveredPort.idx or nil
    LastHoveredConvAddr = (hoveredMachine and hoveredMachine.cat == "Conveyor") and hoveredMachine.addr or nil
    LastHoveredMachineAddr = hoveredMachine and hoveredMachine.addr or nil
    LastHadDynamicOverlay = (MouseState.lDraggingBox or InteractionMode ~= "Select" or hoveredMachine ~= nil or hoveredPort ~= nil)
end

local function DrawSingleGhostOnSelectionCanvas(outer, pc, gp, compactGhosts, replaceFillCol, replaceBdrCol)
    local canvas = MapUI.SelectionCanvas
    local nBefore = (canvas.GetChildrenCount and canvas:GetChildrenCount()) or 0
    local gbx, gby = WorldToBaseCanvas(gp.x, gp.y)
    local rx, ry = GetRotatedCellDims(gp.cellsX or 1, gp.cellsY or 1, gp.yaw or 0)
    local pxW = math.max(8.0, rx * BASE_CELL_PX)
    local pxH = math.max(8.0, ry * BASE_CELL_PX)
    local gpCat = gp.cat or "Other"
    local sprite = gp.actorClsPath and RequestMachineSprite(gp.actorClsPath, nil, gpCat, gp.buildable) or gp.sprite
    CreateMachineVisualWidget(MapUI.Window, pc, outer, canvas, gbx, gby, pxW, pxH, gp.yaw or 0, gpCat, sprite, true, true, 6, false)
    if gp.isReplace then
        AddBorderFast(outer, canvas, gbx, gby, pxW, pxH, replaceFillCol, 7)
    end
    local bdrCol = gp.isReplace and replaceBdrCol or COLORS.GhostBorderOk
    if not (compactGhosts and gpCat == "Conveyor" and not gp.isReplace) then
        RenderBorderOutline(outer, canvas, gbx, gby, pxW, pxH, gp.isReplace and 2.5 or 2.0, bdrCol, 8)
    end
    if gp.isReplace then
        DrawReplaceIcon(outer, canvas, gbx, gby, pxW, pxH, 11)
    end
    local clsLow = (gp.actorClsPath or ""):lower()
    if clsLow:find("splitter", 1, true) or clsLow:find("balancer", 1, true) then
        AddSplitterOrBalancerChevrons(outer, canvas, gbx, gby, pxW, pxH, gp.yaw or 0, clsLow, 9)
    elseif clsLow:find("underground", 1, true) then
        AddMiniChevronAt(outer, canvas, gbx, gby, math.min(pxW, pxH) * 0.30, 2.2, gp.yaw or 0, bdrCol, 9)
        if gp.pairX and gp.pairY then
            local pbx, pby = WorldToBaseCanvas(gp.pairX, gp.pairY)
            CreateMachineVisualWidget(MapUI.Window, pc, outer, canvas, pbx, pby, pxW, pxH, gp.yaw or 0, gpCat, sprite, true, true, 6, false)
            if gp.isReplace then
                AddBorderFast(outer, canvas, pbx, pby, pxW, pxH, replaceFillCol, 7)
                DrawReplaceIcon(outer, canvas, pbx, pby, pxW, pxH, 11)
            end
            RenderBorderOutline(outer, canvas, pbx, pby, pxW, pxH, gp.isReplace and 2.5 or 2.0, bdrCol, 8)
            AddMiniChevronAt(outer, canvas, pbx, pby, math.min(pxW, pxH) * 0.30, 2.2, gp.yaw or 0, bdrCol, 9)
            RenderDashedLine(outer, canvas, gbx, gby, pbx, pby, bdrCol, 2.6, 10.0, 6.0, 9)
            local linkAng = math.deg(math.atan(pby - gby, pbx - gbx))
            AddMiniChevronAt(outer, canvas, (gbx + pbx) * 0.5, (gby + pby) * 0.5, 10.0, 2.4, linkAng, bdrCol, 10)
        end
    end
    if gp.ghostId and canvas.GetChildrenCount and canvas.GetChildAt then
        Perf.GhostWidgetsById = Perf.GhostWidgetsById or {}
        local wList = {}
        local nAfter = canvas:GetChildrenCount()
        for ci = nBefore, nAfter - 1 do
            local ch = canvas:GetChildAt(ci)
            if Core.IsValidObj(ch) then wList[#wList + 1] = ch end
        end
        Perf.GhostWidgetsById[gp.ghostId] = wList
    end
end

function Perf.DrawSingleDeleteMark(outer, dm)
    local canvas = MapUI and MapUI.SelectionCanvas
    if not Core.IsValidObj(canvas) or not dm then return end
    local nBefore = (canvas.GetChildrenCount and canvas:GetChildrenCount()) or 0
    local delFillCol = { R = 0.88, G = 0.10, B = 0.10, A = 0.44 }
    local delBdrCol  = { R = 1.00, G = 0.22, B = 0.22, A = 0.98 }
    local delXCol    = { R = 1.00, G = 0.16, B = 0.16, A = 1.00 }
    local function drawMark(bx, by, pxW, pxH)
        AddBorderFast(outer, canvas, bx, by, pxW, pxH, delFillCol, 3)
        RenderBorderOutline(outer, canvas, bx, by, pxW, pxH, 2.5, delBdrCol, 4)
        local xLen = math.max(12.0, math.min(pxW, pxH) * 0.72)
        local xThick = math.max(2.6, math.min(5.0, xLen * 0.13))
        for _, ang in ipairs({ 45.0, -45.0 }) do
            local bar = AddBorderFast(outer, canvas, bx, by, xLen, xThick, delXCol, 5)
            if bar then
                pcall(function()
                    bar:SetRenderTransformPivot(ALIGN_CENTER)
                    if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle(ang) end
                end)
            end
        end
    end
    local bx, by = WorldToBaseCanvas(dm.x, dm.y)
    local rx, ry = GetRotatedCellDims(dm.cellsX or 1, dm.cellsY or 1, dm.yaw or 0)
    local pxW = math.max(8.0, rx * BASE_CELL_PX)
    local pxH = math.max(8.0, ry * BASE_CELL_PX)
    drawMark(bx, by, pxW, pxH)
    if dm.pairX and dm.pairY then
        local pbx, pby = WorldToBaseCanvas(dm.pairX, dm.pairY)
        drawMark(pbx, pby, pxW, pxH)
    end
    if dm.addr and canvas.GetChildrenCount and canvas.GetChildAt then
        Perf.DeleteWidgetsByAddr = Perf.DeleteWidgetsByAddr or {}
        local wList = {}
        local nAfter = canvas:GetChildrenCount()
        for ci = nBefore, nAfter - 1 do
            local ch = canvas:GetChildAt(ci)
            if Core.IsValidObj(ch) then wList[#wList + 1] = ch end
        end
        Perf.DeleteWidgetsByAddr[dm.addr] = wList
    end
end

function Perf.RemoveGhostWidgets(idSet)
    if not Perf.GhostWidgetsById or not idSet then return end
    for gid, _ in pairs(idSet) do
        local wList = Perf.GhostWidgetsById[gid]
        if wList then
            for i = 1, #wList do
                if Core.IsValidObj(wList[i]) then pcall(function() wList[i]:RemoveFromParent() end) end
            end
            Perf.GhostWidgetsById[gid] = nil
        end
    end
end

function Perf.RemoveDeleteWidgets(addrSet)
    if not Perf.DeleteWidgetsByAddr or not addrSet then return end
    for addr, _ in pairs(addrSet) do
        local wList = Perf.DeleteWidgetsByAddr[addr]
        if wList then
            for i = 1, #wList do
                if Core.IsValidObj(wList[i]) then pcall(function() wList[i]:RemoveFromParent() end) end
            end
            Perf.DeleteWidgetsByAddr[addr] = nil
        end
    end
end

function Perf.AddDeleteWidgets(newDeletes)
    if not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) or not newDeletes or #newDeletes == 0 then return end
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local myFullGen = Perf.SelRenderGen or 0
    local dIdx = 1
    local totalD = #newDeletes
    local function pumpAddDel()
        if (Perf.SelRenderGen or 0) ~= myFullGen or not IsMapOpen() or not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then return end
        local budgetEnd = os.clock() + 0.0030
        local ops = 0
        while dIdx <= totalD and (ops < 12 or os.clock() < budgetEnd) and ops < 60 do
            local dm = newDeletes[dIdx]
            dIdx = dIdx + 1
            if math.abs((dm.z or floor.z) - floor.z) <= 250.0 then
                ops = ops + 1
                Perf.DrawSingleDeleteMark(outer, dm)
            end
        end
        if dIdx <= totalD then
            ExecuteInGameThreadAfterFrames(1, pumpAddDel)
        end
    end
    pumpAddDel()
end

local function AppendGhostsToSelectionCanvas(newGhosts)
    if not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) or not newGhosts or #newGhosts == 0 then return end
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = MapUI.PC
    local myFullGen = Perf.SelRenderGen or 0
    local replaceFillCol = { R = 0.12, G = 0.48, B = 0.98, A = 0.44 }
    local replaceBdrCol  = { R = 0.28, G = 0.76, B = 1.00, A = 0.98 }
    local compactGhosts = (#PendingGhosts > 40)
    local gIdx = 1
    local totalG = #newGhosts

    local function pumpAppend()
        if (Perf.SelRenderGen or 0) ~= myFullGen or not IsMapOpen() or not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then
            return
        end
        local budgetEnd = os.clock() + 0.0030
        local ops = 0
        while gIdx <= totalG and (ops < 10 or os.clock() < budgetEnd) and ops < 50 do
            local gp = newGhosts[gIdx]
            gIdx = gIdx + 1
            if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
                ops = ops + 1
                DrawSingleGhostOnSelectionCanvas(outer, pc, gp, compactGhosts, replaceFillCol, replaceBdrCol)
            end
        end
        if gIdx <= totalG then
            ExecuteInGameThreadAfterFrames(1, pumpAppend)
        end
    end
    pumpAppend()
end

local function RefreshSelectionLayer(selectionOnly)
    if not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then return end
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local outer = Core.GetWidgetOuter(MapUI.Window)
    local pc = MapUI.PC

    -- Build unified highlight list for BOTH SelectedMachines and SelectedGhosts (never touches ghost/delete widgets!)
    local function buildHighlightList()
        local list = {}
        for _, rm in ipairs(RenderedMachines) do
            if SelectedMachines[rm.addr] ~= nil then
                list[#list + 1] = rm
            end
        end
        for _, gp in pairs(SelectedGhosts) do
            if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
                list[#list + 1] = gp
            end
        end
        return list
    end

    local function startHighlightPump(selList)
        Perf.SelOnlyGen = (Perf.SelOnlyGen or 0) + 1
        local mySelOnlyGen = Perf.SelOnlyGen
        if Perf.SelHighlightWidgets then
            for _, w in ipairs(Perf.SelHighlightWidgets) do
                if Core.IsValidObj(w) then pcall(function() w:RemoveFromParent() end) end
            end
        end
        Perf.SelHighlightWidgets = {}
        if #selList == 0 then return end

        -- Consistent, fast single-highlight fill for ALL selection sizes (1 to N machines/ghosts:
        -- 5x fewer UMG widgets and uniform visual style regardless of selection count).
        local selHighlightCol = { R = COLORS.Selected.R, G = COLORS.Selected.G, B = COLORS.Selected.B, A = 0.46 }
        local sIdx = 1
        local function addTrackedSelBorder(bx, by, w, h, col, z)
            local b = AddBorderFast(outer, MapUI.SelectionCanvas, bx, by, w, h, col, z)
            if b then Perf.SelHighlightWidgets[#Perf.SelHighlightWidgets + 1] = b end
        end
        local function pumpSelOnly()
            if mySelOnlyGen ~= Perf.SelOnlyGen or not IsMapOpen() or not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then
                return
            end
            local budgetEnd = os.clock() + 0.0030
            local ops = 0
            while sIdx <= #selList and (ops < 20 or os.clock() < budgetEnd) and ops < 120 do
                local rm = selList[sIdx]
                sIdx = sIdx + 1
                ops = ops + 1
                local bx, by = WorldToBaseCanvas(rm.x, rm.y)
                local rx, ry = GetRotatedCellDims(rm.cellsX or 1, rm.cellsY or 1, rm.yaw or 0)
                local pxW = math.max(8.0, rx * BASE_CELL_PX)
                local pxH = math.max(8.0, ry * BASE_CELL_PX)
                addTrackedSelBorder(bx, by, pxW, pxH, selHighlightCol, 12)
                if rm.pairX and rm.pairY then
                    local pbx, pby = WorldToBaseCanvas(rm.pairX, rm.pairY)
                    addTrackedSelBorder(pbx, pby, pxW, pxH, selHighlightCol, 12)
                end
            end
            if sIdx <= #selList then
                ExecuteInGameThreadAfterFrames(1, pumpSelOnly)
            end
        end
        pumpSelOnly()
    end

    -- Fast path: update ONLY selection highlights (machines + ghosts) without touching stamped ghosts/deletes!
    if selectionOnly then
        startHighlightPump(buildHighlightList())
        UpdateStatusBanner()
        return
    end

    Perf.SelRenderGen = (Perf.SelRenderGen or 0) + 1
    local mySelGen = Perf.SelRenderGen
    Perf.SelHighlightWidgets = {}
    Perf.GhostWidgetsById = {}
    Perf.DeleteWidgetsByAddr = {}
    ClearCanvasChildren(MapUI.SelectionCanvas)

    local delList = {}
    for _, dm in pairs(PendingDeletes) do
        if math.abs((dm.z or floor.z) - floor.z) <= 250.0 then
            delList[#delList + 1] = dm
        end
    end
    local ghostList = {}
    for _, gp in ipairs(PendingGhosts) do
        if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
            ghostList[#ghostList + 1] = gp
        end
    end

    local delFillCol = { R = 0.88, G = 0.10, B = 0.10, A = 0.44 }
    local delBdrCol  = { R = 1.00, G = 0.22, B = 0.22, A = 0.98 }
    local delXCol    = { R = 1.00, G = 0.16, B = 0.16, A = 1.00 }
    local replaceFillCol = { R = 0.12, G = 0.48, B = 0.98, A = 0.44 }
    local replaceBdrCol  = { R = 0.28, G = 0.76, B = 1.00, A = 0.98 }
    local compactGhosts = (#ghostList > 40)

    local function drawDeleteMark(bx, by, pxW, pxH)
        AddBorderFast(outer, MapUI.SelectionCanvas, bx, by, pxW, pxH, delFillCol, 3)
        RenderBorderOutline(outer, MapUI.SelectionCanvas, bx, by, pxW, pxH, 2.5, delBdrCol, 4)
        local xLen = math.max(12.0, math.min(pxW, pxH) * 0.72)
        local xThick = math.max(2.6, math.min(5.0, xLen * 0.13))
        for _, ang in ipairs({ 45.0, -45.0 }) do
            local bar = AddBorderFast(outer, MapUI.SelectionCanvas, bx, by, xLen, xThick, delXCol, 5)
            if bar then
                pcall(function()
                    bar:SetRenderTransformPivot(ALIGN_CENTER)
                    if bar.SetRenderTransformAngle then bar:SetRenderTransformAngle(ang) end
                end)
            end
        end
    end

    local dIdx, gIdx = 1, 1
    local function pumpSelectionLayer()
        if mySelGen ~= Perf.SelRenderGen or not IsMapOpen() or not MapUI or not Core.IsValidObj(MapUI.SelectionCanvas) then
            return
        end
        local budgetEnd = os.clock() + 0.0030
        local ops = 0

        while dIdx <= #delList and (ops < 10 or os.clock() < budgetEnd) and ops < 60 do
            local dm = delList[dIdx]
            dIdx = dIdx + 1
            ops = ops + 1
            Perf.DrawSingleDeleteMark(outer, dm)
        end

        while dIdx > #delList and gIdx <= #ghostList and (ops < 10 or os.clock() < budgetEnd) and ops < 50 do
            local gp = ghostList[gIdx]
            gIdx = gIdx + 1
            ops = ops + 1
            DrawSingleGhostOnSelectionCanvas(outer, pc, gp, compactGhosts, replaceFillCol, replaceBdrCol)
        end

        if dIdx <= #delList or gIdx <= #ghostList then
            ExecuteInGameThreadAfterFrames(1, pumpSelectionLayer)
        end
    end

    pumpSelectionLayer()
    startHighlightPump(buildHighlightList())
    UpdateActionBar()
    UpdateStatusBanner()
end

RefreshStationMapCanvas = function(machinesOnly)
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return end

    local mCanvas = Core.IsValidObj(MapUI.MachineCanvas) and MapUI.MachineCanvas or MapUI.MapCanvas
    if mCanvas == MapUI.MapCanvas then
        machinesOnly = false
    end

    local pc = MapUI.PC
    local useRT = (Perf.RT ~= nil) and Perf.RT.IsSupported(pc)

    if not machinesOnly then
        MeasureMapCanvasSize()
        if not ViewTransform.hasFitted then
            FitViewTransformToFloor()
        end
        ClearCanvasChildren(MapUI.MapCanvas)
        RenderedGridLines = {}
        LastGridTier = nil
        LastGridZoomRatio = nil
    end

    if useRT then
        local curStAddr = Core.IsValidObj(CurrentStation) and tostring(CurrentStation:GetAddress()) or nil
        if Perf.FloorRTCacheStation ~= curStAddr then
            Perf.DestroyActiveRT()
            ClearCanvasChildren(mCanvas)
            Perf.FloorRTCacheStation = curStAddr
        else
            if Perf.ActiveRT and Perf.ActiveRT.SetFloorVisible then
                Perf.ActiveRT.SetFloorVisible(false)
            end
            if machinesOnly then
                Perf.DestroyFloorRT(SelectedFloorIdx)
            end
        end
    else
        Perf.DestroyActiveRT()
        ClearCanvasChildren(mCanvas)
    end
    ClearCanvasChildren(MapUI.SelectionCanvas)
    ClearCanvasChildren(MapUI.IconCanvas)
    RenderedMachines = {}
    RenderedConveyors = {}
    RenderedPorts = {}
    Perf.MachineGrid = {}
    Perf.PortGrid = {}
    RenderedMachineWidgets = {}
    LastHoveredPortIdx = nil
    Perf.LastIconCanvasVisible = nil
    FloorIconButtons = {}

    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor or #floor.platforms == 0 then
        ApplyViewTransform()
        UpdateStatusBanner("No station modules on this floor")
        RefreshDynamicOverlay()
        return
    end

    local outer = Core.GetWidgetOuter(MapUI.Window)
    local cellPx = BASE_CELL_PX

    local deferredGridLines = {}
    local deferredWalls = {}
    local myCanvasGen = CanvasRenderGen

    local function getPaddedVisibleWorldRect()
        local scale = math.max(0.05, ViewTransform.scale or 0.36)
        local halfW = (math.max(300.0, ViewTransform.canvasW or 1200.0) * 0.5) / scale
        local halfH = (math.max(200.0, ViewTransform.canvasH or 800.0) * 0.5) / scale
        local padX = math.max(600.0, halfW * 0.35)
        local padY = math.max(600.0, halfH * 0.35)
        return ViewTransform.cx - halfW - padX, ViewTransform.cx + halfW + padX,
               ViewTransform.cy - halfH - padY, ViewTransform.cy + halfH + padY
    end

    -- Render station module platforms and crisp zoom-adaptive grid lines on MapCanvas (Z=2..4)
    -- beneath both RT tiles and UMG fallback machines so grid squares never alias or blur on zoom.
    if not machinesOnly then
        CanvasRenderGen = CanvasRenderGen + 1
        myCanvasGen = CanvasRenderGen

        local bMinX, bMaxX, bMinY, bMaxY = math.huge, -math.huge, math.huge, -math.huge
        for _, pe in ipairs(floor.platforms) do
            local b = pe.bounds
            if b.cx - b.ex < bMinX then bMinX = b.cx - b.ex end
            if b.cx + b.ex > bMaxX then bMaxX = b.cx + b.ex end
            if b.cy - b.ey < bMinY then bMinY = b.cy - b.ey end
            if b.cy + b.ey > bMaxY then bMaxY = b.cy + b.ey end
        end
        if floor.machines then
            for _, me in ipairs(floor.machines) do
                if me.x - 400.0 < bMinX then bMinX = me.x - 400.0 end
                if me.x + 400.0 > bMaxX then bMaxX = me.x + 400.0 end
                if me.y - 400.0 < bMinY then bMinY = me.y - 400.0 end
                if me.y + 400.0 > bMaxY then bMaxY = me.y + 400.0 end
            end
        end
        local padCm = 400.0
        local minCol = math.floor((bMinX - padCm - ViewTransform.gridOriginX) / CELL_CM)
        local maxCol = math.ceil((bMaxX + padCm - ViewTransform.gridOriginX) / CELL_CM)
        local minRow = math.floor((bMinY - padCm - ViewTransform.gridOriginY) / CELL_CM)
        local maxRow = math.ceil((bMaxY + padCm - ViewTransform.gridOriginY) / CELL_CM)
        if (maxCol - minCol) < 48 then
            local extra = math.ceil((48 - (maxCol - minCol)) * 0.5)
            minCol = minCol - extra
            maxCol = maxCol + extra
        end
        if (maxRow - minRow) < 40 then
            local extra = math.ceil((40 - (maxRow - minRow)) * 0.5)
            minRow = minRow - extra
            maxRow = maxRow + extra
        end
        minCol = math.floor(minCol / 8) * 8
        maxCol = math.ceil(maxCol / 8) * 8
        minRow = math.floor(minRow / 8) * 8
        maxRow = math.ceil(maxRow / 8) * 8

        local totalCols = maxCol - minCol
        local totalRows = maxRow - minRow
        local maxDim = math.max(totalCols, totalRows)
        local stepCells = 1
        if maxDim > 480 then
            stepCells = 4
        elseif maxDim > 240 then
            stepCells = 2
        end

        local gridMinX = ViewTransform.gridOriginX + minCol * CELL_CM
        local gridMaxX = ViewTransform.gridOriginX + maxCol * CELL_CM
        local gridMinY = ViewTransform.gridOriginY + minRow * CELL_CM
        local gridMaxY = ViewTransform.gridOriginY + maxRow * CELL_CM

        local bGridMinX, bGridMinY = WorldToBaseCanvas(gridMinX, gridMinY)
        local bGridMaxX, bGridMaxY = WorldToBaseCanvas(gridMaxX, gridMaxY)
        local gridSpanW = math.max(100.0, bGridMaxX - bGridMinX)
        local gridSpanH = math.max(100.0, bGridMaxY - bGridMinY)
        local gridMidX = (bGridMinX + bGridMaxX) * 0.5
        local gridMidY = (bGridMinY + bGridMaxY) * 0.5

        local function addGridAxisLines(startIdx, endIdx, isVertical, spanOther, midOther)
            local maxLines = 260
            local drawn = 0
            local originAxis = isVertical and ViewTransform.gridOriginX or ViewTransform.gridOriginY
            for idx = startIdx, endIdx, stepCells do
                drawn = drawn + 1
                if drawn > maxLines then break end
                local wPos = originAxis + idx * CELL_CM
                local bx, by = WorldToBaseCanvas(isVertical and wPos or 0.0, isVertical and 0.0 or wPos)
                local posX = isVertical and bx or midOther
                local posY = isVertical and midOther or by
                local isMajor4 = ((idx % 4) == 0)
                local isMajor8 = ((idx % 8) == 0)
                local initThick = isMajor4 and 2.2 or 1.4
                if isMajor4 then
                    local line, s = AddBorderFast(
                        outer, MapUI.MapCanvas, posX, posY,
                        isVertical and initThick or spanOther,
                        isVertical and spanOther or initThick,
                        COLORS.GridMajor, 3
                    )
                    if line and s then
                        table.insert(RenderedGridLines, {
                            border = line,
                            slot = s,
                            isVertical = isVertical,
                            spanOther = spanOther,
                            isMajor4 = true,
                            isMajor8 = isMajor8,
                        })
                    end
                else
                    table.insert(deferredGridLines, {
                        posX = posX, posY = posY,
                        w = isVertical and initThick or spanOther,
                        h = isVertical and spanOther or initThick,
                        isVertical = isVertical,
                        spanOther = spanOther,
                    })
                end
            end
        end

        addGridAxisLines(minCol, maxCol, true, gridSpanH, gridMidY)
        addGridAxisLines(minRow, maxRow, false, gridSpanW, gridMidX)
        UpdateGridAppearanceForZoom(ViewTransform.scale / BASE_PX_PER_CM)

        for _, pe in ipairs(floor.platforms) do
            local b = pe.bounds
            local mx, my = WorldToBaseCanvas(b.cx, b.cy)
            local mw = math.max(12.0, b.ex * 2.0 * BASE_PX_PER_CM)
            local mh = math.max(12.0, b.ey * 2.0 * BASE_PX_PER_CM)

            AddBorderFast(outer, MapUI.MapCanvas, mx, my, mw, mh, COLORS.ModuleFill, 2)
            RenderBorderOutline(outer, MapUI.MapCanvas, mx, my, mw, mh, 5.5, COLORS.ModuleBorder, 4)
        end

        if not useRT and floor.walls and #floor.walls > 0 then
            for _, w in ipairs(floor.walls) do
                local wx, wy = WorldToBaseCanvas(w.cx, w.cy)
                local ww = math.max(6.0, (w.maxX - w.minX) * BASE_PX_PER_CM)
                local wh = math.max(6.0, (w.maxY - w.minY) * BASE_PX_PER_CM)
                table.insert(deferredWalls, {
                    wx = wx, wy = wy, ww = ww, wh = wh,
                    minX = w.minX, maxX = w.maxX, minY = w.minY, maxY = w.maxY,
                    rendered = false,
                })
            end
        end

        local gIdx = 1
        local visibleWallQueue = {}
        local wQueueIdx = 1
        local wallBorderPad = 11.0
        local staticPumpRunning = false

        local function pumpStaticBatch()
            if myCanvasGen ~= CanvasRenderGen or not IsMapOpen() or not Core.IsValidObj(ActiveMapWin) or not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then
                staticPumpRunning = false
                return
            end
            local budgetEnd = os.clock() + 0.0025
            local addedGrid = false
            local gCount = 0
            while gIdx <= #deferredGridLines and (gCount < 6 or os.clock() < budgetEnd) and gCount < 20 do
                local dg = deferredGridLines[gIdx]
                local line, s = AddBorderFast(outer, MapUI.MapCanvas, dg.posX, dg.posY, dg.w, dg.h, COLORS.GridLine, 3)
                if line and s then
                    table.insert(RenderedGridLines, {
                        border = line,
                        slot = s,
                        isVertical = dg.isVertical,
                        spanOther = dg.spanOther,
                        isMajor4 = false,
                        isMajor8 = false,
                    })
                    addedGrid = true
                end
                gIdx = gIdx + 1
                gCount = gCount + 1
            end
            if addedGrid and gIdx > #deferredGridLines then
                LastGridTier = nil
                UpdateGridAppearanceForZoom(ViewTransform.scale / BASE_PX_PER_CM)
            end
            local wCount = 0
            while wQueueIdx <= #visibleWallQueue and (wCount < 4 or os.clock() < budgetEnd) and wCount < 16 do
                local dw = visibleWallQueue[wQueueIdx]
                AddBorderFast(outer, MapUI.MapCanvas, dw.wx, dw.wy, dw.ww + wallBorderPad, dw.wh + wallBorderPad, COLORS.WallBorder, 5)
                AddBorderFast(outer, MapUI.MapCanvas, dw.wx, dw.wy, dw.ww + 1.0, dw.wh + 1.0, COLORS.WallFill, 6)
                wQueueIdx = wQueueIdx + 1
                wCount = wCount + 1
            end
            if gIdx <= #deferredGridLines or wQueueIdx <= #visibleWallQueue then
                ExecuteInGameThreadAfterFrames(2, pumpStaticBatch)
            else
                staticPumpRunning = false
            end
        end

        OnViewportChangedStatic = function()
            if myCanvasGen ~= CanvasRenderGen or not IsMapOpen() then return end
            local vMinX, vMaxX, vMinY, vMaxY = getPaddedVisibleWorldRect()
            for _, dw in ipairs(deferredWalls) do
                if not dw.rendered and dw.maxX >= vMinX and dw.minX <= vMaxX and dw.maxY >= vMinY and dw.minY <= vMaxY then
                    dw.rendered = true
                    table.insert(visibleWallQueue, dw)
                end
            end
            if not staticPumpRunning and (gIdx <= #deferredGridLines or wQueueIdx <= #visibleWallQueue) then
                staticPumpRunning = true
                ExecuteInGameThreadAfterFrames(1, pumpStaticBatch)
            end
        end
        OnViewportChangedStatic()
    end

    if useRT then
        MachineRenderGen = MachineRenderGen + 1
        local floorWallCount = (floor.walls and #floor.walls) or 0
        local floorMachCount = (floor.machines and #floor.machines) or 0
        local cachedEntry = Perf.FloorRTCache[SelectedFloorIdx]
        if cachedEntry and cachedEntry.rtFloor and cachedEntry.wallCount == floorWallCount
            and (cachedEntry.machCount > 0 or floorMachCount == 0)
        then
            -- Instant <1ms floor switch: reuse cached mega-tile RTs and spatial indices!
            Perf.ActiveRT = cachedEntry.rtFloor
            cachedEntry.rtFloor.SetFloorVisible(true)
            RenderedMachines = cachedEntry.renderedMachines
            RenderedConveyors = cachedEntry.renderedConveyors
            RenderedPorts = cachedEntry.renderedPorts
            Perf.MachineGrid = cachedEntry.machineGrid
            Perf.PortGrid = cachedEntry.portGrid
            OnViewportChangedMachines = cachedEntry.onViewportChanged
            SyncFloorMachinesIncremental = cachedEntry.syncIncremental
            RefreshSingleMachineVisual = cachedEntry.refreshSingle
            if cachedEntry.onViewportChanged then cachedEntry.onViewportChanged() end
            if cachedEntry.resumePump then cachedEntry.resumePump() end
            Core.Log(string.format("[StationMapRT] Instant cached floor switch: floor=%d tiles=%d machines=%d",
                SelectedFloorIdx, cachedEntry.rtFloor.GetTileCount(), #RenderedMachines))
        else
            if cachedEntry then
                Perf.DestroyFloorRT(SelectedFloorIdx)
            end
            local rtFloor = Perf.RT.CreateFloorRenderer({
                worldCtx = pc,
                outer = outer,
                parentCanvas = mCanvas,
                basePxPerCm = BASE_PX_PER_CM,
                cellCm = CELL_CM,
                gridOriginX = ViewTransform.gridOriginX,
                gridOriginY = ViewTransform.gridOriginY,
                colors = {
                    PlatformFill   = COLORS.ModuleFill,
                    PlatformBorder = COLORS.ModuleBorder,
                    WallBorder     = COLORS.WallBorder,
                    WallFill       = COLORS.WallFill,
                },
                getTierArrowColor = GetTierArrowColor,
                getMachineColor   = GetColorForMachine,
            })

            if rtFloor then
                Perf.ActiveRT = rtFloor

            local deferWallDirty = (#(floor.machines or {}) > 0)
            if floor.walls and #floor.walls > 0 then
                for _, w in ipairs(floor.walls) do
                    rtFloor.AddWall(w.cx, w.cy, math.max(12.0, w.maxX - w.minX), math.max(12.0, w.maxY - w.minY), deferWallDirty)
                end
            end

            local function getPaddedVisibleWorldRectRT()
                local scale = math.max(0.05, ViewTransform.scale or 0.36)
                local halfW = (math.max(300.0, ViewTransform.canvasW or 1200.0) * 0.5) / scale
                local halfH = (math.max(200.0, ViewTransform.canvasH or 800.0) * 0.5) / scale
                local padX = math.max(600.0, halfW * 0.35)
                local padY = math.max(600.0, halfH * 0.35)
                return ViewTransform.cx - halfW - padX, ViewTransform.cx + halfW + padX,
                       ViewTransform.cy - halfH - padY, ViewTransform.cy + halfH + padY
            end

            local floorMachines = floor.machines or {}
            local presentAddrs = {}
            local knownByAddr = {}
            local toIndexQueue = {}
            local idxCursor = 1
            local tileCmRT = (Perf.RT and Perf.RT.TILE_WORLD_CM) or 800.0
            local vcx = ViewTransform.cx or 0.0
            local vcy = ViewTransform.cy or 0.0
            for _, me in ipairs(floorMachines) do
                if Core.IsValidObj(me.machine) then
                    local addr = me.machine:GetAddress()
                    presentAddrs[addr] = true
                    knownByAddr[addr] = me
                    local tx = math.floor((me.x or 0.0) / tileCmRT)
                    local ty = math.floor((me.y or 0.0) / tileCmRT)
                    local tcx = (tx + 0.5) * tileCmRT - vcx
                    local tcy = (ty + 0.5) * tileCmRT - vcy
                    me._rtTileKey = tx * 100000 + ty
                    me._rtTileDist = tcx * tcx + tcy * tcy
                    toIndexQueue[#toIndexQueue + 1] = me
                end
            end
            -- Group machines contiguously by RT tile, ordered outward from viewport center,
            -- so each tile completes indexing and renders immediately (once, with zero multi-second wait).
            if #toIndexQueue > 1 then
                table.sort(toIndexQueue, function(a, b)
                    if a._rtTileKey == b._rtTileKey then return false end
                    if a._rtTileDist ~= b._rtTileDist then return a._rtTileDist < b._rtTileDist end
                    return a._rtTileKey < b._rtTileKey
                end)
            end

            local bldMetaCache = {}
            local seenUndergroundPairs = {}
            local ugLinkByKey = {}
            local ugKeysByAddr = {}
            local portHalfCm = 32.0
            local nextPortId = 0
            local rtPumpRunning = false
            local rtTileInProgress = (#toIndexQueue > 0)
            local rtWallsFlushed = (not deferWallDirty)
            local rtDrawCount = 0
            local rtDrawSumMs = 0.0
            local rtDrawMaxMs = 0.0
            local rtLoggedDone = false

            local function removeMachineRT(mAddr)
                rtFloor.RemoveMachine(mAddr)
                local pKeys = ugKeysByAddr[mAddr]
                if pKeys then
                    for _, pk in ipairs(pKeys) do
                        rtFloor.RemoveUndergroundLink(pk, ugLinkByKey[pk])
                        ugLinkByKey[pk] = nil
                        seenUndergroundPairs[pk] = nil
                    end
                    ugKeysByAddr[mAddr] = nil
                end
                SelectedMachines[mAddr] = nil
                for i = #RenderedMachines, 1, -1 do
                    if RenderedMachines[i].addr == mAddr then
                        Perf.RemoveMachine(RenderedMachines[i])
                        table.remove(RenderedMachines, i)
                    end
                end
                for i = #RenderedConveyors, 1, -1 do
                    if RenderedConveyors[i].addr == mAddr then table.remove(RenderedConveyors, i) end
                end
                for i = #RenderedPorts, 1, -1 do
                    if RenderedPorts[i].ownerAddr == mAddr then
                        Perf.RemovePort(RenderedPorts[i])
                        table.remove(RenderedPorts, i)
                    end
                end
            end

            local function indexOneMachineRT(me, deferDirty, inPlaceAdditive)
                local m = me.machine
                if not Core.IsValidObj(m) then return end
                local mAddr = m:GetAddress()
                if not presentAddrs[mAddr] then return end

                local mwx, mwy, mwz, myaw = me.x, me.y, me.z, me.yaw
                local okB, bldRaw = pcall(function() return m.Buildable end)
                local bld = okB and Core.IsValidObj(bldRaw) and bldRaw or nil
                local bldAddr = bld and bld:GetAddress() or nil
                local meta = bldAddr and bldMetaCache[bldAddr] or nil
                local cat, cellsX, cellsY, clsKey, sprite, dispName
                if meta then
                    cat = meta.cat
                    cellsX = meta.cellsX
                    cellsY = meta.cellsY
                    clsKey = meta.clsKey
                    sprite = meta.sprite
                    dispName = meta.dispName
                else
                    cat = StationData.GetMachineCategory(m)
                    cellsX, cellsY = StationData.GetMachineFootprintCells(m)
                    clsKey = select(1, GetMachineClassKey(m, bld))
                    sprite = RequestMachineSprite(clsKey, m, cat, bld)
                    dispName = StationData.GetMachineDisplayName(m)
                    if bldAddr then
                        bldMetaCache[bldAddr] = {
                            cat = cat, cellsX = cellsX, cellsY = cellsY,
                            clsKey = clsKey, sprite = sprite, dispName = dispName,
                        }
                    end
                end
                local rx, ry = GetRotatedCellDims(cellsX, cellsY, myaw)
                local pxW = math.max(8.0, rx * cellPx)

                local rec = nil
                local overlayChips = nil
                local isProducer = false
                if cat ~= "Conveyor" then
                    local okR, recRaw = pcall(function() return m.Recipe end)
                    if okR then rec = recRaw end
                    if cat == "Container" then
                        local topItems = StationData.GetContainerTopItems(m, (pxW >= 72.0) and 2 or 1)
                        if #topItems > 0 then
                            overlayChips = {}
                            for _, entry in ipairs(topItems) do
                                overlayChips[#overlayChips + 1] = { item = entry.Item, rate = nil }
                            end
                        end
                    else
                        local outputs = StationData.GetProducerOutputsAndRates(m)
                        if #outputs > 0 then
                            isProducer = true
                            overlayChips = {}
                            local maxChips = (pxW >= 80.0) and 2 or 1
                            for i = 1, math.min(maxChips, #outputs) do
                                overlayChips[#overlayChips + 1] = { item = outputs[i].Item, rate = outputs[i].Rate }
                            end
                        end
                    end
                end

                local recEntry = {
                    machine = m,
                    addr = mAddr,
                    x = mwx,
                    y = mwy,
                    z = mwz,
                    yaw = myaw,
                    cellsX = cellsX,
                    cellsY = cellsY,
                    halfW = rx * CELL_CM * 0.5,
                    halfH = ry * CELL_CM * 0.5,
                    cat = cat,
                    buildable = bld,
                    recipe = rec,
                    actorClsPath = clsKey,
                    sprite = sprite,
                    displayName = dispName,
                }
                RenderedMachines[#RenderedMachines + 1] = recEntry
                Perf.InsertMachine(recEntry)
                if cat == "Conveyor" then
                    RenderedConveyors[#RenderedConveyors + 1] = recEntry
                    rtFloor.UpsertMachine(mAddr, {
                        x = mwx, y = mwy,
                        rx = rx, ry = ry,
                        yaw = myaw,
                        cat = "Conveyor",
                        sprite = sprite,
                    }, nil, deferDirty, inPlaceAdditive)
                    return
                end

                local clsLow = clsKey and clsKey:lower() or ""
                local isUnderground = (clsLow:find("underground", 1, true) ~= nil)
                local drawExitPair = false
                local uInfo = isUnderground and StationData.GetUndergroundBeltPairInfo(m, CurrentFrameXform) or nil
                if uInfo and uInfo.pairX and uInfo.pairY then
                    recEntry.pairX = uInfo.pairX
                    recEntry.pairY = uInfo.pairY
                    Perf.InsertMachineRect(recEntry, uInfo.pairX, uInfo.pairY)
                    recEntry.ugLength = math.max(2, math.floor(math.sqrt((uInfo.pairX - mwx) ^ 2 + (uInfo.pairY - mwy) ^ 2) / CELL_CM + 0.5) + 1)
                    local pKey = (uInfo.pairAddr and (mAddr < uInfo.pairAddr and (mAddr .. ":" .. uInfo.pairAddr) or (uInfo.pairAddr .. ":" .. mAddr))) or tostring(mAddr)
                    if not seenUndergroundPairs[pKey] then
                        seenUndergroundPairs[pKey] = true
                        local arrowCol = GetTierArrowColor(sprite and sprite.tier or 1)
                        local lineCol = { R = arrowCol.R, G = arrowCol.G, B = arrowCol.B, A = 0.80 }
                        local x1, y1, x2, y2 = mwx, mwy, uInfo.pairX, uInfo.pairY
                        if uInfo.isInput == false then
                            x1, y1, x2, y2 = uInfo.pairX, uInfo.pairY, mwx, mwy
                        end
                        local linkEntry = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, lineCol = lineCol, arrowCol = arrowCol }
                        ugLinkByKey[pKey] = linkEntry
                        ugKeysByAddr[mAddr] = ugKeysByAddr[mAddr] or {}
                        table.insert(ugKeysByAddr[mAddr], pKey)
                        if uInfo.pairAddr then
                            ugKeysByAddr[uInfo.pairAddr] = ugKeysByAddr[uInfo.pairAddr] or {}
                            table.insert(ugKeysByAddr[uInfo.pairAddr], pKey)
                        end
                        rtFloor.AddUndergroundLink(pKey, linkEntry, deferDirty)
                    end
                    if not (uInfo.pairAddr and presentAddrs[uInfo.pairAddr]) then
                        drawExitPair = true
                    end
                end

                local portList = {}
                local isTransportOnly = (cat == "Conveyor")
                    or clsLow:find("splitter", 1, true) or clsLow:find("balancer", 1, true)
                    or clsLow:find("merger", 1, true) or isUnderground
                if not isTransportOnly then
                    local ports = StationData.GetMachineItemPorts(m, mwx, mwy, myaw, cellsX, cellsY, CurrentFrameXform)
                    local seenMachinePorts = {}
                    for _, p in ipairs(ports) do
                        local cellKey = string.format("%.0f,%.0f", p.px / 25.0, p.py / 25.0)
                        local existing = seenMachinePorts[cellKey]
                        if not existing then
                            nextPortId = nextPortId + 1
                            existing = {
                                idx = nextPortId,
                                x = p.px,
                                y = p.py,
                                halfW = portHalfCm,
                                halfH = portHalfCm,
                                isInput = p.isInput == true,
                                isOutput = p.isOutput == true,
                                machineName = recEntry.displayName,
                                ownerAddr = mAddr,
                            }
                            seenMachinePorts[cellKey] = existing
                            RenderedPorts[#RenderedPorts + 1] = existing
                            Perf.InsertPort(existing)
                            portList[#portList + 1] = { x = p.px, y = p.py }
                        else
                            if p.isInput then existing.isInput = true end
                            if p.isOutput then existing.isOutput = true end
                        end
                    end
                end

                local drawEntry = {
                    x = mwx, y = mwy,
                    rx = rx, ry = ry,
                    yaw = myaw,
                    cat = cat,
                    clsLow = clsLow,
                    sprite = sprite,
                    overlayChips = overlayChips,
                    isProducer = isProducer,
                    isUnderground = isUnderground,
                    drawExitPair = drawExitPair,
                    pairX = recEntry.pairX,
                    pairY = recEntry.pairY,
                }
                rtFloor.UpsertMachine(mAddr, drawEntry, portList, deferDirty, inPlaceAdditive)
            end

            local function logRTFloorDone()
                if rtLoggedDone then return end
                rtLoggedDone = true
                local st = rtFloor.GetStats and rtFloor.GetStats() or nil
                if st and st.slices > 0 then
                    Core.Log(string.format("[StationMapRT] Floor render done: tiles=%d slices=%d max=%.2fms alloc=%.1fms walls=%.1fms belts=%.1fms(%d->%d) mach=%.1fms end=%.1fms",
                        rtFloor.GetTileCount(), st.slices, st.maxSliceMs,
                        st.allocMs, st.wallsMs, st.beltsMs, st.rawBelts, st.beltRuns, st.machinesMs, st.endMs))
                end
            end

            local function pumpRT()
                if Perf.ActiveRT ~= rtFloor or not IsMapOpen() then
                    rtPumpRunning = false
                    return
                end

                -- Phase 1: Index all queued machines first (5.5ms/frame pure Lua with full bldMetaCache,
                -- ~40-80ms total) so machine-rich center mega-tiles begin drawing almost immediately with
                -- zero redundant tile wipes/re-renders.
                if idxCursor <= #toIndexQueue then
                    local budgetEnd = os.clock() + 0.0055
                    local indexed = 0
                    local defer = (not rtWallsFlushed)
                    while idxCursor <= #toIndexQueue and (indexed < 50 or os.clock() < budgetEnd) and indexed < 320 do
                        indexOneMachineRT(toIndexQueue[idxCursor], defer)
                        idxCursor = idxCursor + 1
                        indexed = indexed + 1
                    end
                    if idxCursor > #toIndexQueue and not rtWallsFlushed then
                        rtWallsFlushed = true
                        rtFloor.MarkAllTilesDirtySorted(ViewTransform.cx, ViewTransform.cy)
                    end
                    ExecuteInGameThreadAfterFrames(1, pumpRT)
                    return
                end

                if not rtWallsFlushed then
                    rtWallsFlushed = true
                    rtFloor.MarkAllTilesDirtySorted(ViewTransform.cx, ViewTransform.cy)
                end

                -- Phase 2: Progressively draw mega-tiles (machine-rich center tiles first, 2.5ms/slice).
                if rtFloor.HasDirtyTiles() then
                    local moreDirty, drawMs = rtFloor.PumpDirtyTiles(1, 0.0025)
                    rtDrawCount = rtDrawCount + 1
                    rtDrawSumMs = rtDrawSumMs + (drawMs or 0.0)
                    if (drawMs or 0.0) > rtDrawMaxMs then rtDrawMaxMs = drawMs or 0.0 end
                    local nextFrames = ((drawMs or 0.0) > 4.0) and 2 or 1
                    if moreDirty then
                        ExecuteInGameThreadAfterFrames(nextFrames, pumpRT)
                    else
                        rtPumpRunning = false
                        logRTFloorDone()
                    end
                    return
                end

                rtPumpRunning = false
                logRTFloorDone()
            end

            local function startRTPump()
                if not rtPumpRunning and Perf.ActiveRT == rtFloor and IsMapOpen() then
                    if idxCursor <= #toIndexQueue or rtFloor.HasDirtyTiles() then
                        rtPumpRunning = true
                        ExecuteInGameThreadAfterFrames(1, pumpRT)
                    end
                end
            end

            OnViewportChangedMachines = function()
                if Perf.ActiveRT ~= rtFloor or not IsMapOpen() then return end
                local vMinX, vMaxX, vMinY, vMaxY = getPaddedVisibleWorldRectRT()
                rtFloor.UpdateViewport(vMinX, vMaxX, vMinY, vMaxY)
                if idxCursor <= #toIndexQueue or (rtFloor.HasDirtyTiles and rtFloor.HasDirtyTiles()) then
                    startRTPump()
                end
            end

            local syncGenRT = 0
            SyncFloorMachinesIncremental = function()
                if Perf.ActiveRT ~= rtFloor or not Core.IsValidObj(CurrentStation) or not Core.IsValidObj(ActiveMapWin) or not IsMapOpen() then return 0 end
                local curFl = CurrentFloors[SelectedFloorIdx]
                if not curFl then return 0 end

                syncGenRT = syncGenRT + 1
                local mySyncGen = syncGenRT
                StationData.InvalidateMachineCache()
                local allMachines = StationData.GetAllStationMachines(CurrentStation, curFl.platforms, CurrentWalkFrame) or {}

                -- Fast O(N) address-only diff: stationary machines never move, so we reuse knownByAddr
                -- and skip machines already known on other floors — ONLY calling GetMachineLocalPosAndYaw
                -- on genuinely NEW machines! (Turns a 1,892-machine multi-second scan into <2ms!)
                local otherFloorAddrs = {}
                for fIdx, fl in ipairs(CurrentFloors) do
                    if fIdx ~= SelectedFloorIdx and fl and fl.machines then
                        for i = 1, #fl.machines do
                            local om = fl.machines[i].machine
                            if Core.IsValidObj(om) then
                                otherFloorAddrs[om:GetAddress()] = true
                            end
                        end
                    end
                end

                local liveList = {}
                local liveByAddr = {}
                local newCandidates = {}
                for i = 1, #allMachines do
                    local m = allMachines[i]
                    if Core.IsValidObj(m) then
                        local addr = m:GetAddress()
                        local existing = knownByAddr[addr]
                        if existing then
                            liveList[#liveList + 1] = existing
                            liveByAddr[addr] = existing
                        elseif not otherFloorAddrs[addr] then
                            newCandidates[#newCandidates + 1] = m
                        end
                    end
                end

                local function applyDiff()
                    if mySyncGen ~= syncGenRT or Perf.ActiveRT ~= rtFloor or not IsMapOpen() then return 0 end
                    curFl.machines = liveList
                    local removedCount = 0
                    for addr, _ in pairs(knownByAddr) do
                        if not liveByAddr[addr] then
                            knownByAddr[addr] = nil
                            presentAddrs[addr] = nil
                            removeMachineRT(addr)
                            removedCount = removedCount + 1
                        end
                    end

                    local addedCount = 0
                    for addr, me in pairs(liveByAddr) do
                        if not knownByAddr[addr] then
                            knownByAddr[addr] = me
                            presentAddrs[addr] = true
                            local tx = math.floor((me.x or 0.0) / tileCmRT)
                            local ty = math.floor((me.y or 0.0) / tileCmRT)
                            me._rtTileKey = tx * 100000 + ty
                            toIndexQueue[#toIndexQueue + 1] = me
                            addedCount = addedCount + 1
                        end
                    end

                    if removedCount > 0 then
                        LastHoveredPortIdx = nil
                        LastHoveredMachineAddr = nil
                        RefreshSelectionLayer(true)
                        RefreshDynamicOverlay()
                    end
                    if removedCount > 0 or addedCount > 0 then
                        startRTPump()
                        if RevalidatePendingChanges then
                            RevalidatePendingChanges(false)
                        end
                    end
                    return removedCount + addedCount
                end

                if #newCandidates <= 40 then
                    for i = 1, #newCandidates do
                        local m = newCandidates[i]
                        if Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m) then
                            local lx, ly, lz, lyaw = StationData.GetMachineLocalPosAndYaw(m, CurrentFrameXform)
                            if lx and ly and lz and math.abs(lz - curFl.z) <= 220.0 then
                                local addr = m:GetAddress()
                                local me = { machine = m, x = lx, y = ly, z = lz, yaw = lyaw or 0.0 }
                                liveList[#liveList + 1] = me
                                liveByAddr[addr] = me
                            end
                        end
                    end
                    return applyDiff()
                end

                -- Large batch of new machines (>40): time-slice GetMachineLocalPosAndYaw at 4ms/frame
                local scanIdx = 1
                local totalScan = #newCandidates
                local function pumpNewScan()
                    if mySyncGen ~= syncGenRT or Perf.ActiveRT ~= rtFloor or not IsMapOpen() then return end
                    local budgetEnd = os.clock() + 0.0040
                    local step = 0
                    while scanIdx <= totalScan and (step < 20 or os.clock() < budgetEnd) and step < 120 do
                        local m = newCandidates[scanIdx]
                        scanIdx = scanIdx + 1
                        step = step + 1
                        if Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m) then
                            local lx, ly, lz, lyaw = StationData.GetMachineLocalPosAndYaw(m, CurrentFrameXform)
                            if lx and ly and lz and math.abs(lz - curFl.z) <= 220.0 then
                                local addr = m:GetAddress()
                                local me = { machine = m, x = lx, y = ly, z = lz, yaw = lyaw or 0.0 }
                                liveList[#liveList + 1] = me
                                liveByAddr[addr] = me
                            end
                        end
                    end
                    if scanIdx <= totalScan then
                        ExecuteInGameThreadAfterFrames(1, pumpNewScan)
                    else
                        applyDiff()
                    end
                end
                ExecuteInGameThreadAfterFrames(1, pumpNewScan)
                return #newCandidates
            end

            RefreshSingleMachineVisual = function(mAddr)
                if Perf.ActiveRT ~= rtFloor then return end
                local me = knownByAddr[mAddr]
                if not me or not Core.IsValidObj(me.machine) then return end
                -- In-place additive update: keep the mega-tile RT intact (no tile wipe!) and redraw
                -- only this machine's updated icon/recipe chip directly on top of its footprint.
                for i = #RenderedMachines, 1, -1 do
                    if RenderedMachines[i].addr == mAddr then
                        Perf.RemoveMachine(RenderedMachines[i])
                        table.remove(RenderedMachines, i)
                    end
                end
                for i = #RenderedConveyors, 1, -1 do
                    if RenderedConveyors[i].addr == mAddr then table.remove(RenderedConveyors, i) end
                end
                for i = #RenderedPorts, 1, -1 do
                    if RenderedPorts[i].ownerAddr == mAddr then
                        Perf.RemovePort(RenderedPorts[i])
                        table.remove(RenderedPorts, i)
                    end
                end
                indexOneMachineRT(me, false, true)
                startRTPump()
            end

            -- Save into persistent per-floor RT cache for instant <1ms floor switching
            Perf.FloorRTCache[SelectedFloorIdx] = {
                rtFloor = rtFloor,
                wallCount = floorWallCount,
                machCount = floorMachCount,
                renderedMachines = RenderedMachines,
                renderedConveyors = RenderedConveyors,
                renderedPorts = RenderedPorts,
                machineGrid = Perf.MachineGrid,
                portGrid = Perf.PortGrid,
                onViewportChanged = OnViewportChangedMachines,
                syncIncremental = SyncFloorMachinesIncremental,
                refreshSingle = RefreshSingleMachineVisual,
                resumePump = startRTPump,
            }

            -- Kick off first viewport cull + RT pump immediately
            local vMinX, vMaxX, vMinY, vMaxY = getPaddedVisibleWorldRectRT()
            rtFloor.UpdateViewport(vMinX, vMaxX, vMinY, vMaxY)
            startRTPump()
            Core.Log(string.format("[StationMapRT] Initialized mega-tile RT floor: floor=%d tiles=%d machines=%d", SelectedFloorIdx, rtFloor.GetTileCount(), #toIndexQueue))
            else
                useRT = false
            end
        end
    end

    if not useRT then
    MachineRenderGen = MachineRenderGen + 1
    local myMachineGen = MachineRenderGen
    local deferredPorts = {}

    -- 3. Index placed machines for viewport-driven lazy streaming (permanent once loaded, never unloaded on pan)
    local floorMachines = floor.machines or {}
    local presentAddrs = {}
    local pendingMachines = {}
    for _, me in ipairs(floorMachines) do
        if Core.IsValidObj(me.machine) then
            presentAddrs[me.machine:GetAddress()] = true
            table.insert(pendingMachines, { me = me, rendered = false })
        end
    end
    local seenUndergroundPairs = {}
    local undergroundPairWidgets = {} -- pKey -> { widgets = {} }
    local undergroundPairKeyByAddr = {} -- mAddr -> { pKey1, ... }
    local portBadgeBasePx = math.max(14.0, BASE_CELL_PX * 0.58)
    local portHalfCm = 32.0
    local nextPortId = 0

    -- Stream ONLY viewport-visible machines and their port badges, grouped into spatial UCanvasPanel chunks
    -- so off-screen chunks are Collapsed (SetVisibility(1)) on pan/zoom to keep Slate render cost low.
    do
        local CHUNK_CM = 1600.0
        local machineChunks = {} -- "cx,cy" -> { canvas, minX, maxX, minY, maxY, visible }
        local iconChunks = {}    -- "cx,cy" -> { canvas, minX, maxX, minY, maxY, visible }
        local pendingByChunk = {} -- "cx,cy" -> { minX, maxX, minY, maxY, items = {}, unrendered = 0 }

        local function getChunkCoords(wx, wy)
            local cx = math.floor((wx or 0.0) / CHUNK_CM)
            local cy = math.floor((wy or 0.0) / CHUNK_CM)
            return cx, cy, cx .. "," .. cy
        end

        local function addPendingToChunk(pm)
            local cx, cy, ck = getChunkCoords(pm.me.x, pm.me.y)
            local bucket = pendingByChunk[ck]
            if not bucket then
                bucket = {
                    minX = cx * CHUNK_CM - 300.0,
                    maxX = (cx + 1) * CHUNK_CM + 300.0,
                    minY = cy * CHUNK_CM - 300.0,
                    maxY = (cy + 1) * CHUNK_CM + 300.0,
                    items = {},
                    unrendered = 0,
                }
                pendingByChunk[ck] = bucket
            end
            bucket.items[#bucket.items + 1] = pm
            if not pm.rendered and not pm.removed then
                bucket.unrendered = bucket.unrendered + 1
            end
            pm.chunkBucket = bucket
        end

        local function getOrCreateChunkCanvas(chunkMap, parentCanvas, wx, wy)
            if not Core.IsValidObj(parentCanvas) then return parentCanvas end
            local cx, cy, ck = getChunkCoords(wx, wy)
            local entry = chunkMap[ck]
            if entry and Core.IsValidObj(entry.canvas) then
                return entry.canvas
            end
            local c = CreateRawFast(PATHS.CanvasPanelClass, outer)
            if not Core.IsValidObj(c) then return parentCanvas end
            pcall(function()
                c:SetClipping(0)
                c:SetVisibility(4) -- SelfHitTestInvisible
                local sl = parentCanvas:AddChildToCanvas(c)
                if Core.IsValidObj(sl) then
                    sl:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                    sl:SetAlignment({ X = 0.0, Y = 0.0 })
                    sl:SetPosition({ X = 0.0, Y = 0.0 })
                    sl:SetSize({ X = 1.0, Y = 1.0 })
                end
            end)
            entry = {
                canvas = c,
                minX = cx * CHUNK_CM - 400.0,
                maxX = (cx + 1) * CHUNK_CM + 400.0,
                minY = cy * CHUNK_CM - 400.0,
                maxY = (cy + 1) * CHUNK_CM + 400.0,
                visible = true,
            }
            chunkMap[ck] = entry
            return c
        end

        local visibleMachineQueue = {}
        local mQueueIdx = 1
        local pIdx = 1
        local machinePumpRunning = false
        local knownPendingByAddr = {}
        for _, pm in ipairs(pendingMachines) do
            if pm.me and Core.IsValidObj(pm.me.machine) then
                knownPendingByAddr[pm.me.machine:GetAddress()] = pm
                addPendingToChunk(pm)
            end
        end

        local function removeRenderedMachine(mAddr)
            local track = RenderedMachineWidgets[mAddr]
            if track then
                track.cancelled = true
                for _, w in ipairs(track.widgets) do
                    if Core.IsValidObj(w) then pcall(function() w:RemoveFromParent() end) end
                end
                if track.portWidgets then
                    for _, pw in ipairs(track.portWidgets) do
                        if Core.IsValidObj(pw) then pcall(function() pw:RemoveFromParent() end) end
                    end
                end
                RenderedMachineWidgets[mAddr] = nil
            end
            local pKeys = undergroundPairKeyByAddr[mAddr]
            if pKeys then
                for _, pk in ipairs(pKeys) do
                    local pairEntry = undergroundPairWidgets[pk]
                    if pairEntry then
                        for _, uw in ipairs(pairEntry.widgets) do
                            if Core.IsValidObj(uw) then pcall(function() uw:RemoveFromParent() end) end
                        end
                        undergroundPairWidgets[pk] = nil
                    end
                    seenUndergroundPairs[pk] = nil
                end
                undergroundPairKeyByAddr[mAddr] = nil
            end
            FloorIconButtons[mAddr] = nil
            SelectedMachines[mAddr] = nil
            for i = #RenderedMachines, 1, -1 do
                if RenderedMachines[i].addr == mAddr then
                    Perf.RemoveMachine(RenderedMachines[i])
                    table.remove(RenderedMachines, i)
                end
            end
            for i = #RenderedConveyors, 1, -1 do
                if RenderedConveyors[i].addr == mAddr then table.remove(RenderedConveyors, i) end
            end
            for i = #RenderedPorts, 1, -1 do
                if RenderedPorts[i].ownerAddr == mAddr then
                    Perf.RemovePort(RenderedPorts[i])
                    table.remove(RenderedPorts, i)
                end
            end
        end

        local function processOneMachine(me)
            local m = me.machine
            if not (Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m)) then return end
            local mAddr = m:GetAddress()
            if not presentAddrs[mAddr] then return end
            if RenderedMachineWidgets[mAddr] then return end
            local mWidgets = {}
            local mPortWidgets = {}
            local mTrack = { widgets = mWidgets, portWidgets = mPortWidgets, cancelled = false }
            RenderedMachineWidgets[mAddr] = mTrack

            local mwx, mwy, mwz, myaw = me.x, me.y, me.z, me.yaw
            local mx, my = WorldToBaseCanvas(mwx, mwy)
            local cat = StationData.GetMachineCategory(m)
            local cellsX, cellsY = StationData.GetMachineFootprintCells(m)
            local rx, ry = GetRotatedCellDims(cellsX, cellsY, myaw)
            local pxW = math.max(8.0, rx * cellPx)
            local pxH = math.max(8.0, ry * cellPx)
            local okB, bldRaw = pcall(function() return m.Buildable end)
            local bld = okB and Core.IsValidObj(bldRaw) and bldRaw or nil
            local okR, rec = pcall(function() return m.Recipe end)
            local clsKey = select(1, GetMachineClassKey(m, bld))
            local sprite = RequestMachineSprite(clsKey, m, cat, bld)

            local overlayChips = {}
            local isContainer = (cat == "Container")
            local isProducer = false
            if isContainer then
                local topItems = StationData.GetContainerTopItems(m, (pxW >= 72.0) and 2 or 1)
                for _, entry in ipairs(topItems) do
                    table.insert(overlayChips, { item = entry.Item, rate = nil })
                end
            elseif cat ~= "Conveyor" then
                local outputs = StationData.GetProducerOutputsAndRates(m)
                if #outputs > 0 then
                    isProducer = true
                    local maxChips = (pxW >= 80.0) and 2 or 1
                    for i = 1, math.min(maxChips, #outputs) do
                        table.insert(overlayChips, { item = outputs[i].Item, rate = outputs[i].Rate })
                    end
                end
            end
            local hasBottomOverlay = (#overlayChips > 0)

            local recEntry = {
                machine = m,
                addr = mAddr,
                x = mwx,
                y = mwy,
                z = mwz,
                yaw = myaw,
                cellsX = cellsX,
                cellsY = cellsY,
                halfW = rx * CELL_CM * 0.5,
                halfH = ry * CELL_CM * 0.5,
                cat = cat,
                buildable = bld,
                recipe = okR and rec or nil,
                actorClsPath = clsKey,
                sprite = sprite,
                displayName = StationData.GetMachineDisplayName(m),
            }
            table.insert(RenderedMachines, recEntry)
            Perf.InsertMachine(recEntry)
            local mTargetCanvas = getOrCreateChunkCanvas(machineChunks, mCanvas, mwx, mwy)
            if cat == "Conveyor" then
                table.insert(RenderedConveyors, recEntry)
                CreateMachineVisualWidget(MapUI.Window, pc, outer, mTargetCanvas, mx, my, pxW, pxH, myaw, "Conveyor", sprite, false, true, 10, false, mWidgets)
            else
                CreateMachineVisualWidget(MapUI.Window, pc, outer, mTargetCanvas, mx, my, pxW, pxH, myaw, cat, sprite, false, true, 10, hasBottomOverlay, mWidgets)
            end

            -- Underground belt enhancements + Splitter/Belt Balancer directional yellow chevrons
            local clsLow = clsKey and clsKey:lower() or ""
            if clsLow:find("splitter", 1, true) or clsLow:find("balancer", 1, true) then
                AddSplitterOrBalancerChevrons(outer, mTargetCanvas, mx, my, pxW, pxH, myaw, clsLow, 16, mWidgets)
            end
            local uInfo = (clsLow:find("underground", 1, true) ~= nil) and StationData.GetUndergroundBeltPairInfo(m, CurrentFrameXform) or nil
            if uInfo then
                local arrowCol = GetTierArrowColor(sprite and sprite.tier or 1)
                local ch1 = RenderDirectionChevron(outer, mTargetCanvas, mx, my, math.min(pxW, pxH) * 0.60, myaw, arrowCol, 15)
                if ch1 then table.insert(mWidgets, ch1) end
                if uInfo.pairX and uInfo.pairY then
                    recEntry.pairX = uInfo.pairX
                    recEntry.pairY = uInfo.pairY
                    recEntry.ugLength = math.max(2, math.floor(math.sqrt((uInfo.pairX - mwx) ^ 2 + (uInfo.pairY - mwy) ^ 2) / CELL_CM + 0.5) + 1)
                    local omx, omy = WorldToBaseCanvas(uInfo.pairX, uInfo.pairY)
                    local pKey = (uInfo.pairAddr and (mAddr < uInfo.pairAddr and (mAddr .. ":" .. uInfo.pairAddr) or (uInfo.pairAddr .. ":" .. mAddr))) or mAddr
                    if not seenUndergroundPairs[pKey] then
                        seenUndergroundPairs[pKey] = true
                        local pairW = {}
                        undergroundPairWidgets[pKey] = { widgets = pairW }
                        undergroundPairKeyByAddr[mAddr] = undergroundPairKeyByAddr[mAddr] or {}
                        table.insert(undergroundPairKeyByAddr[mAddr], pKey)
                        if uInfo.pairAddr then
                            undergroundPairKeyByAddr[uInfo.pairAddr] = undergroundPairKeyByAddr[uInfo.pairAddr] or {}
                            table.insert(undergroundPairKeyByAddr[uInfo.pairAddr], pKey)
                        end
                        local lineCol = { R = arrowCol.R, G = arrowCol.G, B = arrowCol.B, A = 0.80 }
                        local x1, y1, x2, y2 = mx, my, omx, omy
                        if uInfo.isInput == false then
                            x1, y1, x2, y2 = omx, omy, mx, my
                        end
                        RenderDashedLine(outer, mCanvas, x1, y1, x2, y2, lineCol, 2.6, 10.0, 6.0, 17, pairW)
                        local linkAng = math.deg(math.atan(y2 - y1, x2 - x1))
                        local chMid = RenderDirectionChevron(outer, mCanvas, (x1 + x2) * 0.5, (y1 + y2) * 0.5, 18.0, linkAng, arrowCol, 18)
                        if chMid then table.insert(pairW, chMid) end
                    end
                    if not (uInfo.pairAddr and presentAddrs[uInfo.pairAddr]) then
                        CreateMachineVisualWidget(MapUI.Window, pc, outer, mCanvas, omx, omy, pxW, pxH, myaw, cat, sprite, false, true, 10, false, mWidgets)
                        local ch2 = RenderDirectionChevron(outer, mCanvas, omx, omy, math.min(pxW, pxH) * 0.60, myaw, arrowCol, 15)
                        if ch2 then table.insert(mWidgets, ch2) end
                    end
                end
            end

            if hasBottomOverlay then
                local isHidden = StationData.IsMachineIconHidden(m)
                local iconSize = Core.Clamp(math.min(pxW * (#overlayChips > 1 and 0.34 or 0.50), pxH * 0.36), 16.0, 32.0)
                local badgeW = #overlayChips * (iconSize + 10.0) + ((#overlayChips > 1) and 4.0 or 0.0)
                if isProducer then
                    badgeW = math.max(badgeW, #overlayChips * math.max(44.0, iconSize + 20.0))
                end
                local badgeH = isProducer and (iconSize + 18.0) or (iconSize + 6.0)
                local badgeY = (pxH >= 52.0) and (my + pxH * 0.24) or my

                local ov = CreateRawFast(PATHS.OverlayClass, outer)
                local iconBtn = Core.CreateUserWidget(PATHS.WBPButtonClass, MapUI.Window, pc)
                local chipsHBox = CreateRawFast(PATHS.HorizontalBoxClass, outer)
                if Core.IsValidObj(ov) and Core.IsValidObj(iconBtn) and Core.IsValidObj(chipsHBox) then
                    table.insert(mWidgets, ov)
                    pcall(function()
                        iconBtn:SetBackgroundColour({ R = 0.03, G = 0.04, B = 0.06, A = 0.72 })
                        iconBtn:SetContentPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                        local bSlot = ov:AddChildToOverlay(iconBtn)
                        if Core.IsValidObj(bSlot) then
                            bSlot:SetHorizontalAlignment(0)
                            bSlot:SetVerticalAlignment(0)
                        end
                        local cSlot = ov:AddChildToOverlay(chipsHBox)
                        if Core.IsValidObj(cSlot) then
                            cSlot:SetHorizontalAlignment(2)
                            cSlot:SetVerticalAlignment(2)
                        end
                        chipsHBox:SetVisibility(3)

                        for ci, chip in ipairs(overlayChips) do
                            local chipVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
                            local itemW = Core.CreateUserWidget(PATHS.WBPItemClass, MapUI.Window, pc)
                            if Core.IsValidObj(chipVBox) and Core.IsValidObj(itemW) then
                                chipVBox:SetVisibility(3)
                                local iwSlot = chipVBox:AddChildToVerticalBox(itemW)
                                if Core.IsValidObj(iwSlot) then iwSlot:SetHorizontalAlignment(2) end
                                itemW.TooltipEnabled = false
                                itemW:SetVisibility(3)
                                itemW:SetIconSize(iconSize)
                                itemW:SetItem(chip.item)
                                itemW:SetColorAndOpacity({ R = 1.0, G = 1.0, B = 1.0, A = isHidden and 0.25 or 1.0 })

                                if chip.rate ~= nil then
                                    local rTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, pc)
                                    if Core.IsValidObj(rTxt) then
                                        local rtSlot = chipVBox:AddChildToVerticalBox(rTxt)
                                        if Core.IsValidObj(rtSlot) then rtSlot:SetHorizontalAlignment(2) end
                                        local rateStr = (chip.rate >= 10.0) and string.format("%.0f/min", chip.rate) or string.format("%.1f/min", chip.rate)
                                        rTxt:SetVisibility(3)
                                        rTxt:SetSize(10)
                                        rTxt:SetText(Core.MakeText(rateStr))
                                    end
                                end

                                local hbSlot = chipsHBox:AddChildToHorizontalBox(chipVBox)
                                if Core.IsValidObj(hbSlot) then
                                    hbSlot:SetVerticalAlignment(2)
                                    if ci > 1 then
                                        hbSlot:SetPadding({ Left = 4.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                                    end
                                end
                            end
                        end
                    end)

                    local iconParent = Core.IsValidObj(MapUI.IconCanvas) and MapUI.IconCanvas or MapUI.MapCanvas
                    local iconTarget = getOrCreateChunkCanvas(iconChunks, iconParent, mwx, mwy)
                    local iSlot = iconTarget:AddChildToCanvas(ov)
                    SetCanvasSlot(iSlot, mx, badgeY, badgeW, badgeH, 0.5, 0.5, 40)

                    FloorIconButtons[mAddr] = { btn = iconBtn, widget = chipsHBox }
                    local capturedM = m
                    local capturedGroup = chipsHBox
                    Core.RegisterWBPButtonClick(iconBtn, function()
                        local nowHidden = StationData.ToggleMachineIcon(capturedM)
                        if Core.IsValidObj(capturedGroup) then
                            pcall(function()
                                capturedGroup:SetRenderOpacity(nowHidden and 0.25 or 1.0)
                            end)
                        end
                    end)
                end
            end

            -- Collect item ports for this machine (always displayed even when overlapping belts/objects)
            local isTransportOnly = (cat == "Conveyor")
                or clsLow:find("splitter", 1, true) or clsLow:find("balancer", 1, true)
                or clsLow:find("merger", 1, true) or clsLow:find("underground", 1, true)
            if not isTransportOnly then
                local ports = StationData.GetMachineItemPorts(m, mwx, mwy, myaw, cellsX, cellsY, CurrentFrameXform)
                local seenMachinePorts = {}
                for _, p in ipairs(ports) do
                    local cellKey = string.format("%.0f,%.0f", p.px / 25.0, p.py / 25.0)
                    local existing = seenMachinePorts[cellKey]
                    if not existing then
                        local pmx, pmy = WorldToBaseCanvas(p.px, p.py)
                        nextPortId = nextPortId + 1
                        existing = {
                            idx = nextPortId,
                            x = p.px,
                            y = p.py,
                            halfW = portHalfCm,
                            halfH = portHalfCm,
                            isInput = p.isInput == true,
                            isOutput = p.isOutput == true,
                            machineName = recEntry.displayName,
                            ownerAddr = mAddr,
                        }
                        seenMachinePorts[cellKey] = existing
                        table.insert(RenderedPorts, existing)
                        Perf.InsertPort(existing)
                        table.insert(deferredPorts, { pmx = pmx, pmy = pmy, outWidgets = mPortWidgets, track = mTrack, targetCanvas = mTargetCanvas })
                    else
                        if p.isInput then existing.isInput = true end
                        if p.isOutput then existing.isOutput = true end
                    end
                end
            end
        end

        local function pumpMachineBatch()
            if myMachineGen ~= MachineRenderGen or not Core.IsValidObj(ActiveMapWin) or not MapUI or not Core.IsValidObj(mCanvas) then
                machinePumpRunning = false
                return
            end
            local budgetEnd = os.clock() + 0.0035
            local mCount = 0
            while mQueueIdx <= #visibleMachineQueue and (mCount < 3 or os.clock() < budgetEnd) and mCount < 14 do
                processOneMachine(visibleMachineQueue[mQueueIdx])
                mQueueIdx = mQueueIdx + 1
                mCount = mCount + 1
            end
            local pCount = 0
            while pIdx <= #deferredPorts and (pCount < 4 or os.clock() < budgetEnd) and pCount < 16 do
                local dp = deferredPorts[pIdx]
                pIdx = pIdx + 1
                if dp and dp.track and not dp.track.cancelled then
                    local pCanvas = Core.IsValidObj(dp.targetCanvas) and dp.targetCanvas or mCanvas
                    RenderUnconnectedItemPort(outer, pCanvas, dp.pmx, dp.pmy, portBadgeBasePx, 22, dp.outWidgets)
                    pCount = pCount + 1
                end
            end
            if mQueueIdx <= #visibleMachineQueue or pIdx <= #deferredPorts then
                ExecuteInGameThreadAfterFrames(2, pumpMachineBatch)
            else
                machinePumpRunning = false
            end
        end

        OnViewportChangedMachines = function()
            if myMachineGen ~= MachineRenderGen then return end
            local vMinX, vMaxX, vMinY, vMaxY = getPaddedVisibleWorldRect()

            -- 1. Stream unrendered machines only from chunks overlapping the viewport
            for _, bucket in pairs(pendingByChunk) do
                if bucket.unrendered > 0
                    and bucket.maxX >= vMinX and bucket.minX <= vMaxX
                    and bucket.maxY >= vMinY and bucket.minY <= vMaxY
                then
                    for i = 1, #bucket.items do
                        local pm = bucket.items[i]
                        if not pm.removed and not pm.rendered then
                            local me = pm.me
                            if me.x >= vMinX and me.x <= vMaxX and me.y >= vMinY and me.y <= vMaxY then
                                pm.rendered = true
                                pm.isCulled = false
                                bucket.unrendered = math.max(0, bucket.unrendered - 1)
                                visibleMachineQueue[#visibleMachineQueue + 1] = me
                            end
                        end
                    end
                end
            end

            -- 2. Viewport-cull spatial chunk UCanvasPanels (Collapse off-screen chunks in O(chunks))
            for _, ch in pairs(machineChunks) do
                if Core.IsValidObj(ch.canvas) then
                    local inView = (ch.maxX >= vMinX and ch.minX <= vMaxX and ch.maxY >= vMinY and ch.minY <= vMaxY)
                    if ch.visible ~= inView then
                        ch.visible = inView
                        pcall(function() ch.canvas:SetVisibility(inView and 4 or 1) end)
                    end
                end
            end
            for _, ch in pairs(iconChunks) do
                if Core.IsValidObj(ch.canvas) then
                    local inView = (ch.maxX >= vMinX and ch.minX <= vMaxX and ch.maxY >= vMinY and ch.minY <= vMaxY)
                    if ch.visible ~= inView then
                        ch.visible = inView
                        pcall(function() ch.canvas:SetVisibility(inView and 4 or 1) end)
                    end
                end
            end

            if not machinePumpRunning and (mQueueIdx <= #visibleMachineQueue or pIdx <= #deferredPorts) then
                machinePumpRunning = true
                ExecuteInGameThreadAfterFrames(1, pumpMachineBatch)
            end
        end

        -- Lightweight machine-only incremental diff sync (~5ms, never rebuilds walls/platforms!)
        SyncFloorMachinesIncremental = function()
            if myMachineGen ~= MachineRenderGen or not Core.IsValidObj(CurrentStation) or not Core.IsValidObj(ActiveMapWin) then return end
            local curFl = CurrentFloors[SelectedFloorIdx]
            if not curFl then return end

            StationData.InvalidateMachineCache()
            local allMachines = StationData.GetAllStationMachines(CurrentStation, curFl.platforms, CurrentWalkFrame)
            local liveList = {}
            local liveByAddr = {}
            for _, m in ipairs(allMachines or {}) do
                if Core.IsValidObj(m) then
                    local lx, ly, lz, lyaw = StationData.GetMachineLocalPosAndYaw(m, CurrentFrameXform)
                    if lx and ly and lz and math.abs(lz - curFl.z) <= 220.0 then
                        local addr = m:GetAddress()
                        local me = { machine = m, x = lx, y = ly, z = lz, yaw = lyaw or 0.0 }
                        table.insert(liveList, me)
                        liveByAddr[addr] = me
                    end
                end
            end
            curFl.machines = liveList

            -- 1. Remove any machine that was deleted in-game
            local removedCount = 0
            for addr, pm in pairs(knownPendingByAddr) do
                if not liveByAddr[addr] then
                    if not pm.rendered and not pm.removed and pm.chunkBucket then
                        pm.chunkBucket.unrendered = math.max(0, pm.chunkBucket.unrendered - 1)
                    end
                    pm.removed = true
                    knownPendingByAddr[addr] = nil
                    presentAddrs[addr] = nil
                    removeRenderedMachine(addr)
                    removedCount = removedCount + 1
                end
            end

            -- 2. Queue ONLY newly added machines
            local addedCount = 0
            for addr, me in pairs(liveByAddr) do
                if not knownPendingByAddr[addr] then
                    presentAddrs[addr] = true
                    local pm = { me = me, rendered = false }
                    knownPendingByAddr[addr] = pm
                    table.insert(pendingMachines, pm)
                    addPendingToChunk(pm)
                    addedCount = addedCount + 1
                end
            end

            if removedCount > 0 then
                LastHoveredPortIdx = nil
                LastHoveredMachineAddr = nil
                RefreshSelectionLayer()
                RefreshDynamicOverlay()
            end
            if addedCount > 0 and OnViewportChangedMachines then OnViewportChangedMachines() end
            if (removedCount > 0 or addedCount > 0) and RevalidatePendingChanges then
                RevalidatePendingChanges(false)
            end
        end

        RefreshSingleMachineVisual = function(mAddr)
            if myMachineGen ~= MachineRenderGen then return end
            local pm = knownPendingByAddr[mAddr]
            if not pm or pm.removed or not pm.me or not Core.IsValidObj(pm.me.machine) then return end
            removeRenderedMachine(mAddr)
            pm.rendered = true
            table.insert(visibleMachineQueue, pm.me)
            if not machinePumpRunning then
                machinePumpRunning = true
                ExecuteInGameThreadAfterFrames(1, pumpMachineBatch)
            end
        end
    end
    end -- if not useRT

    -- 4. Render player markers & nametags on this floor (refreshable on cached map reopen!)
    -- Note: do NOT clear PlayerMarkerWidgets before RefreshPlayerMarkers() removes old widgets from mCanvas!
    RefreshPlayerMarkers = function()
        if not MapUI or not Core.IsValidObj(mCanvas) or not Core.IsValidObj(MapUI.Window) then return end
        for _, pw in ipairs(PlayerMarkerWidgets) do
            if Core.IsValidObj(pw) then pcall(function() pw:RemoveFromParent() end) end
        end
        PlayerMarkerWidgets = {}
        local curFl = CurrentFloors[SelectedFloorIdx]
        if not curFl then return end
        local curPC = Core.GetLocalPlayerController() or pc
        local allPlayers = StationData.GetAllPlayersInfo(curPC)
        for _, p in ipairs(allPlayers) do
            if p.HasPos then
                local plx, ply, plz = StationData.WorldToStationLocal(CurrentFrameXform, p.X, p.Y, p.Z, nil, nil, nil)
                if math.abs(plz - curFl.z) <= 220.0 then
                    local pmx, pmy = WorldToBaseCanvas(plx, ply)
                    local col = p.IsLocal and COLORS.PlayerLocal or (p.IsOnline and COLORS.PlayerOnline or COLORS.PlayerOffline)
                    local pHalo = AddBorderFast(outer, mCanvas, pmx, pmy, 26.0, 26.0, { R = 0.01, G = 0.01, B = 0.01, A = 0.90 }, 44)
                    if pHalo then table.insert(PlayerMarkerWidgets, pHalo) end
                    local pDot = AddBorderFast(outer, mCanvas, pmx, pmy, 20.0, 20.0, col, 45)
                    if pDot then table.insert(PlayerMarkerWidgets, pDot) end
                    local nameWrap = CreateRawFast(PATHS.BorderClass, outer)
                    local nameTxt = Core.CreateUserWidget(PATHS.WBPTextClass, MapUI.Window, curPC)
                    if Core.IsValidObj(nameWrap) and Core.IsValidObj(nameTxt) then
                        pcall(function()
                            nameWrap:SetBrushColor({ R = 0.015, G = 0.018, B = 0.025, A = 0.86 })
                            nameWrap:SetPadding({ Left = 8.0, Top = 3.0, Right = 8.0, Bottom = 3.0 })
                            nameWrap:SetVisibility(3)
                            nameTxt:SetVisibility(3)
                            nameTxt:SetSize(16)
                            nameTxt:SetText(Core.MakeText(p.Name))
                            nameWrap:AddChild(nameTxt)
                        end)
                        SetWBPTextColor(nameTxt, col)
                        local nSlot = mCanvas:AddChildToCanvas(nameWrap)
                        if Core.IsValidObj(nSlot) then
                            pcall(function()
                                nSlot:SetPosition({ X = pmx, Y = pmy - 22.0 })
                                nSlot:SetAlignment({ X = 0.5, Y = 1.0 })
                                nSlot:SetAutoSize(true)
                                nSlot:SetZOrder(46)
                            end)
                        end
                        table.insert(PlayerMarkerWidgets, nameWrap)
                    end
                end
            end
        end
    end
    RefreshPlayerMarkers()

    RefreshSelectionLayer()
    ApplyViewTransform()
    RefreshDynamicOverlay()
end

--------------------------------------------------------------------------------
-- Vertical Paginated Floor Selector (5 visible slots, ^ / v arrows)
--------------------------------------------------------------------------------

local function EnsureSelectedFloorVisibleInPage()
    local total = #CurrentFloors
    if total == 0 then FloorPageTopIdx = 1 return end
    local minTop = math.min(total, FLOOR_PAGE_SIZE)
    if not FloorPageTopIdx then
        FloorPageTopIdx = Core.Clamp(SelectedFloorIdx + math.floor(FLOOR_PAGE_SIZE / 2), minTop, total)
    end
    if SelectedFloorIdx > FloorPageTopIdx then
        FloorPageTopIdx = SelectedFloorIdx
    elseif SelectedFloorIdx <= FloorPageTopIdx - FLOOR_PAGE_SIZE then
        FloorPageTopIdx = SelectedFloorIdx + FLOOR_PAGE_SIZE - 1
    end
    FloorPageTopIdx = Core.Clamp(FloorPageTopIdx, minTop, total)
end

local function UnregisterButtonList(list)
    if not list then return end
    for i = 1, #list do
        Core.UnregisterWBPButtonClick(list[i])
    end
end

RebuildFloorButtons = function()
    if not MapUI or not Core.IsValidObj(MapUI.FloorSlotsBox) then return end
    UnregisterButtonList(FloorRailButtons)
    FloorRailButtons = {}
    ClearCanvasChildren(MapUI.FloorSlotsBox)
    pcall(function() MapUI.FloorSlotsBox:ClearChildren() end)

    local total = #CurrentFloors
    if total == 0 then return end
    EnsureSelectedFloorVisibleInPage()

    local outer = Core.GetWidgetOuter(MapUI.Window)
    local topIdx = FloorPageTopIdx
    local botIdx = math.max(1, topIdx - FLOOR_PAGE_SIZE + 1)

    for flIdx = topIdx, botIdx, -1 do
        local thisIdx = flIdx
        local isSel = (thisIdx == SelectedFloorIdx)
        local bgCol = isSel and { R = 0.62, G = 0.40, B = 0.05, A = 0.98 } or { R = 0.13, G = 0.15, B = 0.18, A = 0.92 }
        local txtCol = isSel and { R = 1.00, G = 0.98, B = 0.92, A = 1.00 } or COLORS.PlayerLocal
        local btnWrap, btn = CreateLabeledButton(
            MapUI.Window, MapUI.PC, outer, tostring(thisIdx), 15, 60.0, 40.0, bgCol, txtCol,
            function()
                ExecuteInGameThreadWithDelay(10, function()
                    SelectedFloorIdx = thisIdx
                    SelectedMachines = {}
                    SelectedGhosts = {}
                    ViewTransform.hasFitted = false
                    RebuildFloorButtons()
                    RefreshStationMapCanvas()
                end)
            end,
            FloorRailButtons
        )
        if Core.IsValidObj(btnWrap) and Core.IsValidObj(btn) then
            pcall(function() btn:SetSelected(isSel) end)
            local slot = MapUI.FloorSlotsBox:AddChildToVerticalBox(btnWrap)
            if Core.IsValidObj(slot) then
                pcall(function()
                    slot:SetPadding({ Left = 0.0, Top = 3.0, Right = 0.0, Bottom = 3.0 })
                    slot:SetHorizontalAlignment(2)
                end)
            end
        end
    end

    local canUp = (topIdx < total)
    local canDown = (botIdx > 1)
    local navBgOn  = { R = 0.13, G = 0.15, B = 0.18, A = 0.92 }
    local navBgOff = { R = 0.10, G = 0.11, B = 0.13, A = 0.65 }

    local function applyNavBtnState(wrap, btnWidget, btnText, enabled)
        if Core.IsValidObj(btnWidget) then
            pcall(function()
                if btnWidget.SetIsEnabled then btnWidget:SetIsEnabled(enabled) end
                if btnWidget.SetBackgroundColour then btnWidget:SetBackgroundColour(enabled and navBgOn or navBgOff) end
            end)
        end
        if Core.IsValidObj(btnText) then
            pcall(function()
                if Core.IsValidObj(btnText.TextBlock) and btnText.TextBlock.SetColorAndOpacity then
                    btnText.TextBlock:SetColorAndOpacity({
                        SpecifiedColor = enabled and COLORS.PlayerLocal or APPLY_TXT_DISABLED,
                        ColorUseRule = 0,
                    })
                end
            end)
        end
        if Core.IsValidObj(wrap) then
            pcall(function()
                if wrap.SetRenderOpacity then wrap:SetRenderOpacity(enabled and 1.0 or 0.40) end
            end)
        end
    end

    applyNavBtnState(MapUI.FloorUpBtn, MapUI.FloorUpBtnWidget, MapUI.FloorUpBtnText, canUp)
    applyNavBtnState(MapUI.FloorDownBtn, MapUI.FloorDownBtnWidget, MapUI.FloorDownBtnText, canDown)
end

--------------------------------------------------------------------------------
-- Selection, Ghost Placement, Copy-Paste & Apply Changes Actions
--------------------------------------------------------------------------------

local function FindUndergroundPairEntry(rm)
    if not rm or not Core.IsValidObj(rm.machine) then return nil end
    local clsLow = (rm.actorClsPath or ""):lower()
    if not clsLow:find("underground", 1, true) then return nil end
    local uInfo = StationData.GetUndergroundBeltPairInfo(rm.machine, CurrentFrameXform)
    if not uInfo or not uInfo.pairAddr then return nil end
    for _, other in ipairs(RenderedMachines) do
        if other.addr == uInfo.pairAddr then return other end
    end
    return nil
end

local function ProposeDeleteSelected()
    -- 1. Instantly remove any selected ghost machines (surgically, without rerendering other ghosts!)
    local removedGhosts = 0
    local ghostIdsToRemove = {}
    local ghostPairsToRemove = {}
    local removedGhostIdSet = {}
    for gid, gp in pairs(SelectedGhosts) do
        ghostIdsToRemove[gid] = true
        if gp.pairGroupId then ghostPairsToRemove[gp.pairGroupId] = true end
    end
    if next(ghostIdsToRemove) ~= nil then
        for i = #PendingGhosts, 1, -1 do
            local gp = PendingGhosts[i]
            if (gp.ghostId and ghostIdsToRemove[gp.ghostId]) or (gp.pairGroupId and ghostPairsToRemove[gp.pairGroupId]) then
                if gp.ghostId then removedGhostIdSet[gp.ghostId] = true end
                table.remove(PendingGhosts, i)
                removedGhosts = removedGhosts + 1
            end
        end
        SelectedGhosts = {}
    end

    -- 2. Mark/unmark selected real machines (and their underground belt pairs) for deletion on Apply Changes
    local added = 0
    local toMark = {}
    for addr, entry in pairs(SelectedMachines) do
        if IsSelectableMachine(entry) then
            toMark[addr] = entry
            local pairRm = FindUndergroundPairEntry(entry)
            if pairRm and IsSelectableMachine(pairRm) then
                toMark[pairRm.addr] = pairRm
            end
        end
    end
    local newlyMarkedDeletes = {}
    local unmarkedDelAddrs = {}
    for addr, entry in pairs(toMark) do
        if PendingDeletes[addr] then
            PendingDeletes[addr] = nil
            unmarkedDelAddrs[addr] = true
        else
            PendingDeletes[addr] = entry
            newlyMarkedDeletes[#newlyMarkedDeletes + 1] = entry
            added = added + 1
        end
    end
    SelectedMachines = {}

    -- Surgical widget updates: NEVER clears SelectionCanvas or rerenders untouched ghosts!
    if next(removedGhostIdSet) ~= nil then
        Perf.RemoveGhostWidgets(removedGhostIdSet)
    end
    if next(unmarkedDelAddrs) ~= nil then
        Perf.RemoveDeleteWidgets(unmarkedDelAddrs)
    end
    if #newlyMarkedDeletes > 0 then
        Perf.AddDeleteWidgets(newlyMarkedDeletes)
    end
    RefreshSelectionLayer(true)
    ExecuteInGameThreadAfterFrames(1, function()
        if IsMapOpen() then UpdateActionBar() end
    end)
    if added > 0 then
        UpdateStatusBanner(string.format("Marked %d machine(s) for deletion (click Apply Changes to delete & refund)", added))
    elseif removedGhosts > 0 then
        UpdateStatusBanner(string.format("Removed %d ghost placement(s)", removedGhosts))
    end
end

local function CopySelectedMachines()
    Clipboard = {}
    local list = {}
    for _, entry in pairs(SelectedMachines) do
        if IsSelectableMachine(entry) then
            table.insert(list, entry)
        end
    end
    -- Also include any selected ghost machines (preserving configs, cat, and underground pair offsets)
    for _, gp in pairs(SelectedGhosts) do
        if Core.IsValidObj(gp.buildable) then
            table.insert(list, {
                machine = nil,
                addr = gp.ghostId,
                x = gp.x, y = gp.y, z = gp.z, yaw = gp.yaw or 0.0,
                pairX = gp.pairX, pairY = gp.pairY, ugLength = gp.ugLength,
                cellsX = gp.cellsX or 1, cellsY = gp.cellsY or 1,
                cat = gp.cat or "Other",
                buildable = gp.buildable,
                recipe = gp.recipe,
                machineConfig = gp.machineConfig,
                actorClsPath = gp.actorClsPath,
                sprite = gp.sprite,
                displayName = gp.name,
            })
        end
    end
    if #list == 0 then
        UpdateStatusBanner("Select one or more machines first (click, Shift+click, or drag box)")
        return
    end

    -- Anchor clipboard offsets around snapped center so copied groups remain grid-aligned
    local cx, cy = 0.0, 0.0
    for _, e in ipairs(list) do
        cx = cx + e.x
        cy = cy + e.y
    end
    cx = cx / #list
    cy = cy / #list
    local anchorX = SnapAxisToCellGrid(cx, ViewTransform.gridOriginX, 1)
    local anchorY = SnapAxisToCellGrid(cy, ViewTransform.gridOriginY, 1)

    ClipboardGen = ClipboardGen + 1
    GhostPreviewSig = nil
    for _, e in ipairs(list) do
        local cellsX = e.cellsX or 1
        local cellsY = e.cellsY or 1
        local mCfg = e.machineConfig or ((e.cat ~= "Conveyor") and Core.IsValidObj(e.machine) and CaptureMachineConfig(e.machine) or nil)
        local pairDx = (e.pairX and e.pairY) and (e.pairX - e.x) or nil
        local pairDy = (e.pairX and e.pairY) and (e.pairY - e.y) or nil
        local ugLen = e.ugLength
        if not ugLen and pairDx and pairDy then
            ugLen = math.max(2, math.floor(math.sqrt(pairDx * pairDx + pairDy * pairDy) / CELL_CM + 0.5) + 1)
        end
        if ugLen and ugLen > 0 then
            mCfg = mCfg or {}
            mCfg.config = ugLen
        end
        table.insert(Clipboard, {
            buildable = e.buildable,
            dx = e.x - anchorX,
            dy = e.y - anchorY,
            pairDx = pairDx,
            pairDy = pairDy,
            ugLength = ugLen,
            yaw = e.yaw or 0.0,
            cat = e.cat or "Other",
            recipe = e.recipe,
            machineConfig = mCfg,
            cellsX = cellsX,
            cellsY = cellsY,
            actorClsPath = e.actorClsPath,
            sprite = e.sprite,
            name = e.displayName,
        })
    end

    -- Deselect original machines once copied so pressing X after a misplaced paste won't mark originals for deletion
    SelectedMachines = {}
    SelectedGhosts = {}
    InteractionMode = "Paste"
    PendingRotationDeg = 0
    RefreshSelectionLayer(true)
    RefreshDynamicOverlay()
end

local function CommitPendingGhosts()
    local delList = {}
    local seenDelAddr = {}
    for _, dm in pairs(PendingDeletes) do
        if Core.IsValidObj(dm.machine) and not seenDelAddr[dm.addr] then
            seenDelAddr[dm.addr] = true
            table.insert(delList, dm)
        end
    end
    -- Also include all valid overwrite targets from blue replace ghosts (disassembled & refunded natively BEFORE building!)
    for _, gp in ipairs(PendingGhosts) do
        if gp.isReplace and gp.replaceTargets then
            for _, rt in ipairs(gp.replaceTargets) do
                if Core.IsValidObj(rt.machine) and not seenDelAddr[rt.addr] then
                    seenDelAddr[rt.addr] = true
                    table.insert(delList, rt)
                end
            end
        end
    end
    Core.Log(string.format("[StationMap] CommitPendingGhosts entered (inProgress=%s, builds=%d, deletes=%d)", tostring(ApplyInProgress), #PendingGhosts, #delList))
    if ApplyInProgress then return end
    if #PendingGhosts == 0 and #delList == 0 then
        UpdateStatusBanner("No pending changes to apply")
        return
    end
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end
    if not StationData.IsPlayerInStation(pc) then
        UpdateStatusBanner("Apply blocked: must be on a station")
        return
    end

    if #PendingGhosts > 0 then
        local okMat, missingBld = CheckMaterialsForPendingList(pc, PendingGhosts, delList)
        if not okMat then
            local mName = "machine"
            pcall(function() mName = missingBld.DisplayName:ToString() end)
            UpdateStatusBanner("Apply blocked: insufficient materials for " .. mName)
            return
        end
    end

    -- Snapshot pre-existing machine addresses across all floors before building
    -- so ApplyMachineConfig only matches newly spawned machines of the expected Buildable.
    local preExistingAddrs = {}
    for _, fl in ipairs(CurrentFloors) do
        if fl and fl.machines then
            for _, me in ipairs(fl.machines) do
                if Core.IsValidObj(me.machine) then
                    preExistingAddrs[me.machine:GetAddress()] = true
                end
            end
        end
    end

    ApplyInProgress = true
    local buildQueue = PendingGhosts
    PendingGhosts = {}
    PendingDeletes = {}
    SelectedGhosts = {}
    UpdateActionBar()
    RefreshSelectionLayer()

    local totalBuilds = #buildQueue
    local totalDeletes = #delList
    local totalCount = totalBuilds + totalDeletes
    local dIdx = 1
    local qIdx = 1
    local deletedCount = 0
    local builtCount = 0
    local disassembledMachines = {}
    local remaining = {}
    local remainingDeletes = {}
    local builtWithConfig = {}
    local lastErr = nil
    local OPS_PER_FRAME = 4

    Core.Log(string.format("[StationMap] ApplyChanges starting incrementally (%d delete(s), %d build(s))", totalDeletes, totalBuilds))
    UpdateStatusBanner(string.format("Applying changes: 0 / %d...", totalCount))

    local function finishApply()
        ApplyInProgress = false
        for _, rem in ipairs(remaining) do
            table.insert(PendingGhosts, rem)
        end
        for _, remD in ipairs(remainingDeletes) do
            PendingDeletes[remD.addr] = remD
        end
        UpdateActionBar()
        RefreshSelectionLayer()

        if builtCount > 0 or deletedCount > 0 then
            local parts = {}
            if builtCount > 0 then table.insert(parts, string.format("built %d", builtCount)) end
            if deletedCount > 0 then table.insert(parts, string.format("deleted %d", deletedCount)) end
            local failN = #remaining + #remainingDeletes
            UpdateStatusBanner("Applied: " .. table.concat(parts, ", ") .. (failN > 0 and (" (" .. failN .. " failed)") or ""))

            -- Poll for newly built machines (handles both instant SP and high-RTT MP replication)
            local cfgApplied = 0
            local configuredAddrs = {}
            local matchedAddrs = {}
            local pendingCfg = {}
            for _, item in ipairs(builtWithConfig) do
                table.insert(pendingCfg, item)
            end
            local pollDeadline = os.clock() + 3.0

            local function syncCrossFloorsIfNeeded(items)
                local needsCrossFloorSync = false
                for _, item in ipairs(items) do
                    if item.floorIdx and item.floorIdx ~= SelectedFloorIdx then
                        needsCrossFloorSync = true
                        break
                    end
                end
                if needsCrossFloorSync and Core.IsValidObj(CurrentStation) then
                    StationData.InvalidateMachineCache()
                    local freshFloors = StationData.BuildStationFloorMap(CurrentStation, CurrentWalkFrame)
                    if freshFloors and #freshFloors == #CurrentFloors then
                        for i = 1, #CurrentFloors do
                            if i ~= SelectedFloorIdx then
                                CurrentFloors[i].machines = freshFloors[i].machines
                            end
                        end
                    end
                end
            end

            local firstSyncChanged = 0
            local function pollNewMachinesAndConfig()
                if SyncFloorMachinesIncremental then
                    local ch = SyncFloorMachinesIncremental()
                    if type(ch) == "number" then firstSyncChanged = firstSyncChanged + ch end
                end
                if #pendingCfg == 0 then
                    return
                end
                syncCrossFloorsIfNeeded(pendingCfg)

                local pc2 = Core.GetLocalPlayerController()
                if not Core.IsValidObj(pc2) then return end

                local stillUnmatched = {}
                for _, item in ipairs(pendingCfg) do
                    local fl = CurrentFloors[item.floorIdx] or CurrentFloors[SelectedFloorIdx]
                    local bestM, bestD2 = nil, 45.0 * 45.0
                    local expectedBldAddr = Core.IsValidObj(item.buildable) and item.buildable:GetAddress() or nil
                    if fl and fl.machines then
                        for _, me in ipairs(fl.machines) do
                            if Core.IsValidObj(me.machine) then
                                local mAddr = me.machine:GetAddress()
                                if not preExistingAddrs[mAddr] and not matchedAddrs[mAddr] then
                                    local bldMatch = true
                                    if expectedBldAddr then
                                        local mBld = StationData.GetMachineBuildable and StationData.GetMachineBuildable(me.machine) or nil
                                        if Core.IsValidObj(mBld) and mBld:GetAddress() ~= expectedBldAddr then
                                            bldMatch = false
                                        end
                                    end
                                    if bldMatch then
                                        local dx = (me.x or 0) - item.x
                                        local dy = (me.y or 0) - item.y
                                        local d2 = dx * dx + dy * dy
                                        if d2 < bestD2 then
                                            bestD2 = d2
                                            bestM = me.machine
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if Core.IsValidObj(bestM) then
                        local bestAddr = bestM:GetAddress()
                        matchedAddrs[bestAddr] = true
                        if ApplyMachineConfig(pc2, bestM, item.machineConfig) then
                            cfgApplied = cfgApplied + 1
                            table.insert(configuredAddrs, bestAddr)
                        end
                    else
                        table.insert(stillUnmatched, item)
                    end
                end

                pendingCfg = stillUnmatched
                if #pendingCfg > 0 and os.clock() < pollDeadline then
                    ExecuteInGameThreadWithDelay(150, pollNewMachinesAndConfig)
                else
                    Core.Log(string.format("[StationMap] Applied machine configs to %d / %d configured machine(s)", cfgApplied, #builtWithConfig))
                    if IsMapOpen() and #configuredAddrs > 0 and RefreshSingleMachineVisual then
                        ExecuteInGameThreadWithDelay(150, function()
                            if IsMapOpen() then
                                for _, addr in ipairs(configuredAddrs) do
                                    RefreshSingleMachineVisual(addr)
                                end
                            end
                        end)
                    end
                end
            end

            ExecuteInGameThreadWithDelay(100, pollNewMachinesAndConfig)
            if #pendingCfg == 0 then
                -- Follow-up sync ONLY for higher-RTT MP clients when the 100ms sync saw 0 changes
                ExecuteInGameThreadWithDelay(650, function()
                    if IsMapOpen() and firstSyncChanged == 0 and SyncFloorMachinesIncremental then
                        SyncFloorMachinesIncremental()
                    end
                end)
            end
        elseif lastErr then
            UpdateStatusBanner("Apply failed: " .. tostring(lastErr))
            RefreshSelectionLayer()
        end
    end

    local buildPhaseStarted = (totalDeletes == 0)
    local safePumpApplyBatch
    local function pumpApplyBatch()
        local curPC = Core.GetLocalPlayerController()
        if not Core.IsValidObj(curPC) or not Core.IsValidObj(CurrentStation) then
            for i = dIdx, totalDeletes do table.insert(remainingDeletes, delList[i]) end
            for i = qIdx, totalBuilds do table.insert(remaining, buildQueue[i]) end
            finishApply()
            return
        end
        local doneThisFrame = 0
        -- Phase 1: Process all deletes & overwrite-target disassembles first (frees tiles & refunds materials natively)
        if dIdx <= totalDeletes then
            while dIdx <= totalDeletes and doneThisFrame < OPS_PER_FRAME do
                local dm = delList[dIdx]
                local ok, err = IssueRemoteDisassembleMachine(curPC, dm.machine)
                if ok then
                    deletedCount = deletedCount + 1
                    table.insert(disassembledMachines, dm.machine)
                else
                    lastErr = err
                    table.insert(remainingDeletes, dm)
                end
                dIdx = dIdx + 1
                doneThisFrame = doneThisFrame + 1
            end
            if dIdx <= totalDeletes then
                UpdateStatusBanner(string.format("Applying changes: %d / %d...", builtCount + deletedCount, totalCount))
                ExecuteInGameThreadAfterFrames(1, safePumpApplyBatch)
                return
            elseif totalBuilds > 0 and not buildPhaseStarted then
                -- Poll until disassembled machines actually vanish from the simulation (handles high-RTT MP),
                -- with a 2.5s safety cap so builds always proceed.
                buildPhaseStarted = true
                UpdateStatusBanner(string.format("Applying changes: %d / %d...", builtCount + deletedCount, totalCount))
                local delDeadline = os.clock() + 2.5
                local function waitForDisassembles()
                    local anyStillAlive = false
                    for _, m in ipairs(disassembledMachines) do
                        if Core.IsValidObj(m) then
                            local pendingKill = false
                            pcall(function()
                                if m.bPendingDestroy == true or m.bIsDestroyed == true then
                                    pendingKill = true
                                end
                            end)
                            if not pendingKill then
                                anyStillAlive = true
                                break
                            end
                        end
                    end
                    if not anyStillAlive or os.clock() >= delDeadline then
                        safePumpApplyBatch()
                    else
                        ExecuteInGameThreadWithDelay(100, waitForDisassembles)
                    end
                end
                ExecuteInGameThreadWithDelay(100, waitForDisassembles)
                return
            end
        end
        -- Phase 2: Build all new & replacement machines
        while qIdx <= totalBuilds and doneThisFrame < OPS_PER_FRAME do
            local g = buildQueue[qIdx]
            local targetFloor = CurrentFloors[g.floorIdx] or CurrentFloors[SelectedFloorIdx]
            local plat, pb = FindPlatformAtWorldXY(g.x, g.y, targetFloor)
            local wx, wy, wz = StationData.StationLocalToWorld(CurrentFrameXform, g.x, g.y, g.z)
            local ok, err = IssueRemoteBuildMachine(curPC, CurrentStation, plat, pb, g.buildable, g.x, g.y, g.z, wx, wy, wz, g.yaw, g.recipe, g.machineConfig)
            if ok then
                builtCount = builtCount + 1
                if g.machineConfig then
                    table.insert(builtWithConfig, {
                        floorIdx = g.floorIdx or SelectedFloorIdx,
                        buildable = g.buildable,
                        x = g.x, y = g.y, z = g.z,
                        machineConfig = g.machineConfig,
                    })
                end
            else
                lastErr = err
                table.insert(remaining, g)
            end
            qIdx = qIdx + 1
            doneThisFrame = doneThisFrame + 1
        end

        if qIdx <= totalBuilds then
            UpdateStatusBanner(string.format("Applying changes: %d / %d...", builtCount + deletedCount, totalCount))
            ExecuteInGameThreadAfterFrames(1, safePumpApplyBatch)
        else
            finishApply()
        end
    end

    safePumpApplyBatch = function()
        local okPump, errPump = pcall(pumpApplyBatch)
        if not okPump then
            Core.Log("[StationMap] pumpApplyBatch error: " .. tostring(errPump))
            lastErr = tostring(errPump)
            finishApply()
        end
    end

    ExecuteInGameThreadAfterFrames(1, safePumpApplyBatch)
end

local function HandleMapLeftClick(mx, my, isShift)
    local floor = CurrentFloors[SelectedFloorIdx]
    if not floor then return end
    local wx, wy = CanvasToWorld(mx, my)

    if InteractionMode == "Place" and Core.IsValidObj(PendingBuildable) then
        local cellsX, cellsY = StationData.GetMachineFootprintCells(nil, PendingBuildable)
        local sx, sy = SnapWorldToMachineGrid(wx, wy, cellsX, cellsY, PendingRotationDeg)
        local onMod = IsPointOverAnyFloorModule(sx, sy, floor)
        if not onMod then
            UpdateStatusBanner("Place inside a station module")
            return
        end
        if IsFootprintBlockedByWall(sx, sy, cellsX, cellsY, PendingRotationDeg, floor) then
            UpdateStatusBanner("Cannot place inside a module wall")
            return
        end
        local pc = Core.GetLocalPlayerController()
        if not PlayerHasBuildableMaterials(pc, PendingBuildable, 1) then
            UpdateStatusBanner("Insufficient materials in inventory")
            return
        end
        local clsKey = select(1, GetMachineClassKey(nil, PendingBuildable))
        NextGhostSeq = NextGhostSeq + 1
        table.insert(PendingGhosts, {
            ghostId = "ghost:" .. tostring(NextGhostSeq),
            buildable = PendingBuildable,
            floorIdx = SelectedFloorIdx,
            x = sx, y = sy, z = floor.z,
            yaw = PendingRotationDeg,
            cellsX = cellsX, cellsY = cellsY,
            actorClsPath = clsKey,
            sprite = clsKey and MachineSpriteCache[clsKey] or nil,
        })
        RefreshSelectionLayer()
        return
    end

    if InteractionMode == "Paste" and #Clipboard > 0 then
        local pc = Core.GetLocalPlayerController()
        local anchorSx = SnapAxisToCellGrid(wx, ViewTransform.gridOriginX, 1)
        local anchorSy = SnapAxisToCellGrid(wy, ViewTransform.gridOriginY, 1)
        local rad = math.rad(PendingRotationDeg)
        local cosA, sinA = math.cos(rad), math.sin(rad)
        local stampId = tostring(os.clock())
        local staged = {}
        local skippedBlocked = 0
        local replacedGhostIds = {}
        local replacedGhostCount = 0

        local function rectsOverlapCm(ax, ay, ahw, ahh, bx, by, bhw, bhh)
            return math.abs(ax - bx) < (ahw + bhw - 8.0) and math.abs(ay - by) < (ahh + bhh - 8.0)
        end

        local function isItemSplitterOrBalancer(it)
            local clsLow = (it.actorClsPath or ""):lower()
            return (clsLow:find("splitter", 1, true) ~= nil) or (clsLow:find("balancer", 1, true) ~= nil)
        end

        -- Evaluate footprint overlap against both existing PendingGhosts and already-staged ghosts:
        -- Splitters & Belt Balancers cleanly replace overlapped ghost Conveyor Belts (matching real Smart Replace!).
        local function checkGhostOverlap(item, sx, sy, pX, pY, finalYaw)
            local rx, ry = GetRotatedCellDims(item.cellsX or 1, item.cellsY or 1, finalYaw)
            local hw, hh = rx * CELL_CM * 0.5, ry * CELL_CM * 0.5
            local canReplaceConveyor = isItemSplitterOrBalancer(item)
            local toReplace = {}

            local function testList(list, allowReplace)
                for _, eg in ipairs(list) do
                    if not replacedGhostIds[eg.ghostId] and math.abs((eg.z or floor.z) - floor.z) <= 250.0 then
                        local erx, ery = GetRotatedCellDims(eg.cellsX or 1, eg.cellsY or 1, eg.yaw or 0)
                        local ehw, ehh = erx * CELL_CM * 0.5, ery * CELL_CM * 0.5
                        local hit = rectsOverlapCm(sx, sy, hw, hh, eg.x, eg.y, ehw, ehh)
                        if not hit and eg.pairX and eg.pairY then
                            hit = rectsOverlapCm(sx, sy, hw, hh, eg.pairX, eg.pairY, ehw, ehh)
                        end
                        if not hit and pX and pY then
                            hit = rectsOverlapCm(pX, pY, hw, hh, eg.x, eg.y, ehw, ehh)
                                or (eg.pairX and eg.pairY and rectsOverlapCm(pX, pY, hw, hh, eg.pairX, eg.pairY, ehw, ehh))
                        end
                        if hit then
                            if allowReplace and canReplaceConveyor and (eg.cat == "Conveyor") then
                                toReplace[#toReplace + 1] = eg
                            else
                                return false
                            end
                        end
                    end
                end
                return true
            end

            if not testList(PendingGhosts, true) then return false, nil end
            if not testList(staged, false) then return false, nil end
            return true, toReplace
        end
        -- Pre-filter floor walls to only those near the clipboard's bounding box for fast O(1) paste validation
        local pasteFloor = floor
        if floor.walls and #floor.walls > 16 then
            local cMinX, cMaxX, cMinY, cMaxY = math.huge, -math.huge, math.huge, -math.huge
            for _, item in ipairs(Clipboard) do
                local rdx = item.dx * cosA - item.dy * sinA
                local rdy = item.dx * sinA + item.dy * cosA
                local px, py = anchorSx + rdx, anchorSy + rdy
                if px < cMinX then cMinX = px end
                if px > cMaxX then cMaxX = px end
                if py < cMinY then cMinY = py end
                if py > cMaxY then cMaxY = py end
                if item.pairDx and item.pairDy then
                    local ppx = px + (item.pairDx * cosA - item.pairDy * sinA)
                    local ppy = py + (item.pairDx * sinA + item.pairDy * cosA)
                    if ppx < cMinX then cMinX = ppx end
                    if ppx > cMaxX then cMaxX = ppx end
                    if ppy < cMinY then cMinY = ppy end
                    if ppy > cMaxY then cMaxY = ppy end
                end
            end
            local pad = 500.0
            local subWalls = {}
            for _, w in ipairs(floor.walls) do
                if w.maxX >= (cMinX - pad) and w.minX <= (cMaxX + pad) and w.maxY >= (cMinY - pad) and w.minY <= (cMaxY + pad) then
                    subWalls[#subWalls + 1] = w
                end
            end
            pasteFloor = { platforms = floor.platforms, walls = subWalls, z = floor.z }
        end

        for _, item in ipairs(Clipboard) do
            if Core.IsValidObj(item.buildable) then
                local rdx = item.dx * cosA - item.dy * sinA
                local rdy = item.dx * sinA + item.dy * cosA
                local finalYaw = (item.yaw or 0.0) + PendingRotationDeg
                local sx, sy = SnapWorldToMachineGrid(anchorSx + rdx, anchorSy + rdy, item.cellsX or 1, item.cellsY or 1, finalYaw)
                local pX, pY = nil, nil
                if item.pairDx and item.pairDy then
                    local rpdx = item.pairDx * cosA - item.pairDy * sinA
                    local rpdy = item.pairDx * sinA + item.pairDy * cosA
                    pX, pY = SnapWorldToMachineGrid(sx + rpdx, sy + rpdy, item.cellsX or 1, item.cellsY or 1, finalYaw)
                end
                local inBounds = IsPointOverAnyFloorModule(sx, sy, pasteFloor)
                    and not IsFootprintBlockedByWall(sx, sy, item.cellsX or 1, item.cellsY or 1, finalYaw, pasteFloor)
                if inBounds and pX and pY then
                    inBounds = IsPointOverAnyFloorModule(pX, pY, pasteFloor)
                        and not IsFootprintBlockedByWall(pX, pY, item.cellsX or 1, item.cellsY or 1, finalYaw, pasteFloor)
                end
                if inBounds then
                    local allowed, isReplace, replaceTargets = EvaluatePasteGhostOverlap(item, sx, sy, pX, pY, finalYaw, pasteFloor)
                    if allowed then
                        local ghostOk, ghostsToReplace = checkGhostOverlap(item, sx, sy, pX, pY, finalYaw)
                        if ghostOk then
                            if ghostsToReplace and #ghostsToReplace > 0 then
                                for _, rg in ipairs(ghostsToReplace) do
                                    if rg.ghostId and not replacedGhostIds[rg.ghostId] then
                                        replacedGhostIds[rg.ghostId] = true
                                        replacedGhostCount = replacedGhostCount + 1
                                    end
                                end
                            end
                            NextGhostSeq = NextGhostSeq + 1
                            table.insert(staged, {
                                ghostId = "ghost:" .. tostring(NextGhostSeq),
                                buildable = item.buildable,
                                floorIdx = SelectedFloorIdx,
                                x = sx, y = sy, z = floor.z,
                                pairX = pX, pairY = pY,
                                ugLength = item.ugLength,
                                yaw = finalYaw,
                                cat = item.cat or "Other",
                                cellsX = item.cellsX or 1,
                                cellsY = item.cellsY or 1,
                                actorClsPath = item.actorClsPath,
                                sprite = item.sprite,
                                recipe = item.recipe,
                                machineConfig = item.machineConfig,
                                name = item.name,
                                isReplace = isReplace,
                                replaceTargets = replaceTargets,
                            })
                        else
                            skippedBlocked = skippedBlocked + 1
                        end
                    else
                        skippedBlocked = skippedBlocked + 1
                    end
                else
                    skippedBlocked = skippedBlocked + 1
                end
            end
        end
        if #staged == 0 then
            UpdateStatusBanner(skippedBlocked > 0 and "Cannot overwrite existing incompatible machines here" or "Paste inside a station module")
            return
        end
        -- Allow freely staging pasted ghosts (matching Ship/Station Designer behavior;
        -- Modification Cost + Build Validation gate Apply Changes).
        -- Select the newly pasted ghost group so pressing X immediately undoes a misplaced paste.
        -- Remove any ghost conveyor belts cleanly replaced by pasted splitters/balancers
        if replacedGhostCount > 0 then
            local kept = {}
            for _, eg in ipairs(PendingGhosts) do
                if not (eg.ghostId and replacedGhostIds[eg.ghostId]) then
                    kept[#kept + 1] = eg
                end
            end
            PendingGhosts = kept
        end

        SelectedMachines = {}
        SelectedGhosts = {}
        for _, g in ipairs(staged) do
            table.insert(PendingGhosts, g)
            if g.ghostId then
                SelectedGhosts[g.ghostId] = g
            end
        end
        -- Surgically remove ONLY the replaced ghost conveyor belt widgets and append ONLY newly pasted ghosts!
        if replacedGhostCount > 0 then
            Perf.RemoveGhostWidgets(replacedGhostIds)
        end
        AppendGhostsToSelectionCanvas(staged)
        RefreshSelectionLayer(true)
        ExecuteInGameThreadAfterFrames(1, function()
            if IsMapOpen() then UpdateActionBar() end
        end)
        if skippedBlocked > 0 then
            UpdateStatusBanner(string.format("Pasted %d machine(s) (%d skipped - blocked)", #staged, skippedBlocked))
        end
        return
    end

    -- Select mode: check stamped ghosts first (drawn on top, testing BOTH underground belt ends), then selectable real machines
    local hitGhost = nil
    local bestGhostDist = math.huge
    for _, gp in ipairs(PendingGhosts) do
        if math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
            local rx, ry = GetRotatedCellDims(gp.cellsX or 1, gp.cellsY or 1, gp.yaw or 0)
            local hw, hh = rx * CELL_CM * 0.5, ry * CELL_CM * 0.5
            local hitPrimary = (math.abs(wx - gp.x) <= hw and math.abs(wy - gp.y) <= hh)
            local hitPair = (gp.pairX and gp.pairY and math.abs(wx - gp.pairX) <= hw and math.abs(wy - gp.pairY) <= hh)
            if hitPrimary or hitPair then
                local tx, ty = hitPrimary and gp.x or gp.pairX, hitPrimary and gp.y or gp.pairY
                local d2 = (wx - tx) ^ 2 + (wy - ty) ^ 2
                if d2 < bestGhostDist then
                    bestGhostDist = d2
                    hitGhost = gp
                end
            end
        end
    end

    local hit = nil
    if not hitGhost then
        local bestDist = math.huge
        for _, rm in ipairs(RenderedMachines) do
            if IsSelectableMachine(rm) then
                local hitPrimary = (math.abs(wx - rm.x) <= rm.halfW and math.abs(wy - rm.y) <= rm.halfH)
                local hitPair = (rm.pairX and rm.pairY and math.abs(wx - rm.pairX) <= rm.halfW and math.abs(wy - rm.pairY) <= rm.halfH)
                if hitPrimary or hitPair then
                    local tx, ty = hitPrimary and rm.x or rm.pairX, hitPrimary and rm.y or rm.pairY
                    local d2 = (wx - tx) ^ 2 + (wy - ty) ^ 2
                    if d2 < bestDist then
                        bestDist = d2
                        hit = rm
                    end
                end
            end
        end
    end

    local hadMachSel = (next(SelectedMachines) ~= nil)
    local hadGhostSel = (next(SelectedGhosts) ~= nil)
    if not hitGhost and not hit and (isShift or (not hadMachSel and not hadGhostSel)) then
        return
    end

    local ghostSelChanged = false
    if not isShift then
        if hadGhostSel then ghostSelChanged = true end
        SelectedMachines = {}
        SelectedGhosts = {}
    end
    if hitGhost and hitGhost.ghostId then
        local toggleOff = isShift and SelectedGhosts[hitGhost.ghostId] ~= nil
        SelectedGhosts[hitGhost.ghostId] = toggleOff and nil or hitGhost
        ghostSelChanged = true
    elseif hit then
        local toggleOff = isShift and SelectedMachines[hit.addr] ~= nil
        SelectedMachines[hit.addr] = toggleOff and nil or hit
        local pairRm = FindUndergroundPairEntry(hit)
        if pairRm and IsSelectableMachine(pairRm) then
            SelectedMachines[pairRm.addr] = toggleOff and nil or pairRm
        end
    end
    RefreshSelectionLayer(true)
end

local function FinishBoxSelect(x1, y1, x2, y2, isShift)
    local wx1, wy1 = CanvasToWorld(math.min(x1, x2), math.min(y1, y2))
    local wx2, wy2 = CanvasToWorld(math.max(x1, x2), math.max(y1, y2))
    local floor = CurrentFloors[SelectedFloorIdx]

    local hadMachSel = (next(SelectedMachines) ~= nil)
    local hadGhostSel = (next(SelectedGhosts) ~= nil)
    local ghostSelChanged = false
    local machSelAdded = false
    if not isShift then
        if hadGhostSel then ghostSelChanged = true end
        SelectedMachines = {}
        SelectedGhosts = {}
    end
    for _, rm in ipairs(RenderedMachines) do
        if IsSelectableMachine(rm) then
            local inMain = (rm.x + rm.halfW) >= wx1 and (rm.x - rm.halfW) <= wx2 and (rm.y + rm.halfH) >= wy1 and (rm.y - rm.halfH) <= wy2
            local inPair = rm.pairX and rm.pairY and (rm.pairX + rm.halfW) >= wx1 and (rm.pairX - rm.halfW) <= wx2 and (rm.pairY + rm.halfH) >= wy1 and (rm.pairY - rm.halfH) <= wy2
            if inMain or inPair then
                SelectedMachines[rm.addr] = rm
                machSelAdded = true
                local pairRm = FindUndergroundPairEntry(rm)
                if pairRm and IsSelectableMachine(pairRm) then
                    SelectedMachines[pairRm.addr] = pairRm
                end
            end
        end
    end
    if floor then
        for _, gp in ipairs(PendingGhosts) do
            if gp.ghostId and math.abs((gp.z or floor.z) - floor.z) <= 250.0 then
                local rx, ry = GetRotatedCellDims(gp.cellsX or 1, gp.cellsY or 1, gp.yaw or 0)
                local hw, hh = rx * CELL_CM * 0.5, ry * CELL_CM * 0.5
                local inMain = (gp.x + hw) >= wx1 and (gp.x - hw) <= wx2 and (gp.y + hh) >= wy1 and (gp.y - hh) <= wy2
                local inPair = gp.pairX and gp.pairY and (gp.pairX + hw) >= wx1 and (gp.pairX - hw) <= wx2 and (gp.pairY + hh) >= wy1 and (gp.pairY - hh) <= wy2
                if inMain or inPair then
                    SelectedGhosts[gp.ghostId] = gp
                    ghostSelChanged = true
                end
            end
        end
    end
    if not machSelAdded and not ghostSelChanged and (isShift or not hadMachSel) then
        return
    end
    RefreshSelectionLayer(true)
end

--------------------------------------------------------------------------------
-- Unified Mouse Polling Inside Map Canvas (Hover, Drag Box-Select, Pan, Ghosts)
--------------------------------------------------------------------------------

local function ZoomMapByFactor(factor, anchorMx, anchorMy)
    local mx = anchorMx or (ViewTransform.canvasW * 0.5)
    local my = anchorMy or (ViewTransform.canvasH * 0.5)
    local beforeWx, beforeWy = CanvasToWorld(mx, my)
    local newScale = Core.Clamp(ViewTransform.scale * factor, 0.04, 1.80)
    if math.abs(newScale - ViewTransform.scale) > 0.0001 then
        ViewTransform.scale = newScale
        ViewTransform.cx = beforeWx - (mx - ViewTransform.canvasW * 0.5) / newScale
        ViewTransform.cy = beforeWy - (my - ViewTransform.canvasH * 0.5) / newScale
        ApplyViewTransform()
        RefreshDynamicOverlay()
    end
end

local function GetMapCanvasCursorPos(pc)
    if not MapUI or not Core.IsValidObj(MapUI.MapCanvas) then return nil, nil end
    local layoutLib = GetWidgetLayoutLibCDO()
    local slateLib = GetSlateLibCDO()
    if not (Core.IsValidObj(layoutLib) and Core.IsValidObj(slateLib) and MapUI.MapCanvas.GetCachedGeometry) then
        return nil, nil
    end

    local targetWidget = Core.IsValidObj(MapUI.MapBg) and MapUI.MapBg or MapUI.MapCanvas
    local okGeom, geom = pcall(function() return targetWidget:GetCachedGeometry() end)
    local lx, ly = nil, nil
    local absPos, vpPos = nil, nil

    if okGeom and geom and layoutLib.GetMousePositionOnPlatform and slateLib.AbsoluteToLocal then
        local okP, ap = pcall(function() return layoutLib:GetMousePositionOnPlatform() end)
        if okP and ap then
            absPos = ap
            local okL, localPos = pcall(function() return slateLib:AbsoluteToLocal(geom, ap) end)
            if okL and localPos then
                local tx = tonumber(localPos.X)
                local ty = tonumber(localPos.Y)
                if IsFiniteNum(tx) and IsFiniteNum(ty) then
                    lx, ly = tx, ty
                end
            end
        end
    end

    if (lx == nil or ly == nil) and Core.IsValidObj(pc) and layoutLib.GetMousePositionOnViewport and MapUI.Window then
        local okVP, vp = pcall(function() return layoutLib:GetMousePositionOnViewport(pc) end)
        if okVP and vp then
            vpPos = vp
            local vx, vy = tonumber(vp.X), tonumber(vp.Y)
            if IsFiniteNum(vx) and IsFiniteNum(vy) then
                local fullW, fullH = nil, nil
                if layoutLib.GetViewportSize then
                    local okVS, rawVp = pcall(function() return layoutLib:GetViewportSize(pc) end)
                    local vpScale = 1.0
                    pcall(function()
                        if layoutLib.GetViewportScale then
                            local s = tonumber(layoutLib:GetViewportScale(pc))
                            if IsFiniteNum(s) and s > 0.05 then vpScale = s end
                        end
                    end)
                    if okVS and rawVp and IsFiniteNum(tonumber(rawVp.X)) and IsFiniteNum(tonumber(rawVp.Y)) and rawVp.X > 100 then
                        fullW = rawVp.X / vpScale
                        fullH = rawVp.Y / vpScale
                    end
                end
                if (not fullW or not fullH) and slateLib.GetLocalSize then
                    local okWG, wGeom = pcall(function() return MapUI.Window:GetCachedGeometry() end)
                    if okWG and wGeom then
                        local okWS, wSz = pcall(function() return slateLib:GetLocalSize(wGeom) end)
                        if okWS and wSz and IsFiniteNum(tonumber(wSz.X)) and IsFiniteNum(tonumber(wSz.Y)) and wSz.X > 100 and wSz.Y > 100 then
                            fullW = wSz.X
                            fullH = wSz.Y
                        end
                    end
                end
                if fullW and fullH then
                    lx = vx
                    ly = vy
                end
            end
        end
    end

    if not CursorDiagLogged and (lx ~= nil) then
        CursorDiagLogged = true
        local ax = absPos and tonumber(absPos.X) or -999
        local ay = absPos and tonumber(absPos.Y) or -999
        if not vpPos and Core.IsValidObj(pc) and layoutLib.GetMousePositionOnViewport then
            pcall(function() vpPos = layoutLib:GetMousePositionOnViewport(pc) end)
        end
        local vpx = vpPos and tonumber(vpPos.X) or -999
        local vpy = vpPos and tonumber(vpPos.Y) or -999
        Core.Log(string.format("[StationMap] CursorDiag local=(%.1f,%.1f) abs=(%.1f,%.1f) vp=(%.1f,%.1f) canvas=(%.1f,%.1f)",
            lx or -999, ly or -999, ax, ay, vpx, vpy, ViewTransform.canvasW, ViewTransform.canvasH))
    end

    return lx, ly
end

local function IsAnyButtonHovered()
    if not MapUI then return false end
    for _, b in ipairs(TrackedButtons) do
        if Core.IsValidObj(b) and b.IsHovered then
            local okH, h = pcall(function() return b:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    for _, b in ipairs(FloorRailButtons) do
        if Core.IsValidObj(b) and b.IsHovered then
            local okH, h = pcall(function() return b:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    for _, panel in ipairs({ MapUI.FloorFrame, MapUI.ApplyPanel, MapUI.CloseBtnFrame, MapUI.CostPanel }) do
        if Core.IsValidObj(panel) and panel.IsHovered then
            local okH, h = pcall(function() return panel:IsHovered() end)
            if okH and h == true then return true end
        end
    end
    return false
end

function Perf.IsHoveredOnMachineIconButton(mx, my)
    if Perf.LastIconCanvasVisible == false or not mx or not my then return false end
    local wx, wy = CanvasToWorld(mx, my)
    local rm = Perf.FindHoveredMachineAt(wx, wy)
    if not rm then return false end
    local ib = FloorIconButtons[rm.addr]
    if ib and Core.IsValidObj(ib.btn) and ib.btn.IsHovered then
        local okH, h = pcall(function() return ib.btn:IsHovered() end)
        if okH and h == true then return true end
    end
    return false
end

local function EnsureInputPoll()
    if InputPollActive then return end
    InputPollActive = true
    Perf.EnsureMapKeys()

    local function Tick()
        if not IsMapOpen() or not MapUI then
            InputPollActive = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            ExecuteInGameThreadAfterFrames(1, Tick)
            return
        end

        -- Update top-right Close (X) button orange hover highlight
        if Core.IsValidObj(MapUI.CloseBtnFrame) and Core.IsValidObj(MapUI.CloseBtnWidget) then
            local isCloseHov = false
            pcall(function()
                isCloseHov = (MapUI.CloseBtnWidget:IsHovered() == true)
                    or (MapUI.CloseBtnFrame:IsHovered() == true)
            end)
            if isCloseHov ~= MapUI.CloseBtnWasHovered then
                MapUI.CloseBtnWasHovered = isCloseHov
                pcall(function()
                    MapUI.CloseBtnFrame:SetBrushColor(isCloseHov
                        and { R = 0.96, G = 0.56, B = 0.06, A = 1.00 }
                        or  { R = 0.92, G = 0.94, B = 0.96, A = 0.95 })
                    if MapUI.CloseBtnWidget.SetBackgroundColour then
                        MapUI.CloseBtnWidget:SetBackgroundColour(isCloseHov
                            and { R = 0.36, G = 0.18, B = 0.02, A = 0.96 }
                            or  { R = 0.06, G = 0.07, B = 0.09, A = 0.92 })
                    end
                    if Core.IsValidObj(MapUI.CloseBtnText) and Core.IsValidObj(MapUI.CloseBtnText.TextBlock)
                        and MapUI.CloseBtnText.TextBlock.SetColorAndOpacity
                    then
                        MapUI.CloseBtnText.TextBlock:SetColorAndOpacity({
                            SpecifiedColor = isCloseHov
                                and { R = 1.00, G = 0.68, B = 0.14, A = 1.00 }
                                or  { R = 0.98, G = 0.98, B = 1.00, A = 1.00 },
                            ColorUseRule = 0,
                        })
                    end
                end)
            end
        end

        -- Keep character movement disabled while Station Map is open without touching BP_CameraPawn_C / movement components
        pcall(function()
            if pc.CharacterInputEnabled == true and pc.AllowCharacterInput then
                pc:AllowCharacterInput(false)
            end
            if pc.IsMoveInputIgnored and not pc:IsMoveInputIgnored() and pc.SetIgnoreMoveInput then
                pc:SetIgnoreMoveInput(true)
            end
            if pc.IsLookInputIgnored and not pc:IsLookInputIgnored() and pc.SetIgnoreLookInput then
                pc:SetIgnoreLookInput(true)
            end
        end)

        -- Detect layout size changes once canvas settles
        if MeasureMapCanvasSize() then
            if not ViewTransform.hasFitted then FitViewTransformToFloor() end
            ApplyViewTransform()
        end

        local mx, my = GetMapCanvasCursorPos(pc)
        local insideMap = (mx ~= nil and my ~= nil and mx >= 0 and mx <= ViewTransform.canvasW and my >= 0 and my <= ViewTransform.canvasH)

        local lDown, rDown, mDown, shiftDown, spaceDown = false, false, false, false, false
        local keyPanX, keyPanY = 0.0, 0.0
        local keyZoom = 0
        pcall(function()
            local K = Perf.MapKeys
            lDown = K.LMB and (pc:IsInputKeyDown(K.LMB) == true) or false
            rDown = K.RMB and (pc:IsInputKeyDown(K.RMB) == true) or false
            mDown = K.MMB and (pc:IsInputKeyDown(K.MMB) == true) or false
            shiftDown = (K.LShift and pc:IsInputKeyDown(K.LShift) == true)
                or (K.RShift and pc:IsInputKeyDown(K.RShift) == true) or false
            spaceDown = K.Space and (pc:IsInputKeyDown(K.Space) == true) or false

            if not WaitingForBuildMenuSelection then
                if (K.W and pc:IsInputKeyDown(K.W)) or (K.Up and pc:IsInputKeyDown(K.Up)) then keyPanY = keyPanY - 1.0 end
                if (K.S and pc:IsInputKeyDown(K.S)) or (K.Down and pc:IsInputKeyDown(K.Down)) then keyPanY = keyPanY + 1.0 end
                if (K.A and pc:IsInputKeyDown(K.A)) or (K.Left and pc:IsInputKeyDown(K.Left)) then keyPanX = keyPanX - 1.0 end
                if (K.D and pc:IsInputKeyDown(K.D)) or (K.Right and pc:IsInputKeyDown(K.Right)) then keyPanX = keyPanX + 1.0 end
                if (K.Equals and pc:WasInputKeyJustPressed(K.Equals)) or (K.Add and pc:WasInputKeyJustPressed(K.Add)) then keyZoom = 1 end
                if (K.Hyphen and pc:WasInputKeyJustPressed(K.Hyphen)) or (K.Subtract and pc:WasInputKeyJustPressed(K.Subtract)) then keyZoom = -1 end
            end
        end)

        local cursorMoved = (mx ~= MouseState.lastCursorMx or my ~= MouseState.lastCursorMy)
        MouseState.lastCursorMx = mx
        MouseState.lastCursorMy = my

        -- Keyboard WASD/Arrow Pan (zero widget rebuild; instant GPU RenderTransform update!)
        if keyPanX ~= 0.0 or keyPanY ~= 0.0 then
            local stepCm = 14.0 / ViewTransform.scale
            ViewTransform.cx = ViewTransform.cx + keyPanX * stepCm
            ViewTransform.cy = ViewTransform.cy + keyPanY * stepCm
            ApplyViewTransform()
        end

        -- Handle Left Mouse Button transitions (Box Select / Click, or Space+LeftDrag to Pan)
        if lDown and not MouseState.wasLDown then
            if insideMap and not WaitingForBuildMenuSelection and not IsAnyButtonHovered() then
                MouseState.lDownInMap = true
                MouseState.lDraggingBox = false
                MouseState.lPanning = spaceDown
                MouseState.lStartX = mx
                MouseState.lStartY = my
                MouseState.lPanStartCx = ViewTransform.cx
                MouseState.lPanStartCy = ViewTransform.cy
            else
                MouseState.lDownInMap = false
                MouseState.lPanning = false
            end
        elseif lDown and MouseState.lDownInMap and mx and my then
            if MouseState.lPanning then
                if cursorMoved then
                    local dx = mx - MouseState.lStartX
                    local dy = my - MouseState.lStartY
                    ViewTransform.cx = MouseState.lPanStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.lPanStartCy - dy / ViewTransform.scale
                    ApplyViewTransform()
                end
            elseif InteractionMode == "Select" and not MouseState.lDraggingBox and insideMap then
                local dx = mx - MouseState.lStartX
                local dy = my - MouseState.lStartY
                if (dx * dx + dy * dy) > 36.0 then
                    MouseState.lDraggingBox = true
                end
            end
        elseif not lDown and MouseState.wasLDown then
            if MouseState.lDownInMap then
                if MouseState.lPanning and mx and my then
                    local dx = mx - MouseState.lStartX
                    local dy = my - MouseState.lStartY
                    ViewTransform.cx = MouseState.lPanStartCx - dx / ViewTransform.scale
                    ViewTransform.cy = MouseState.lPanStartCy - dy / ViewTransform.scale
                    ApplyViewTransform()
                elseif MouseState.lDraggingBox and mx and my then
                    FinishBoxSelect(MouseState.lStartX, MouseState.lStartY, mx, my, shiftDown)
                elseif insideMap then
                    HandleMapLeftClick(mx, my, shiftDown)
                end
            end
            MouseState.lDownInMap = false
            MouseState.lDraggingBox = false
            MouseState.lPanning = false
        end

        -- Handle Right Mouse Button (cancels Place/Paste mode; panning is handled via WASD/Arrows)
        if rDown and not MouseState.wasRDown then
            MouseState.rDownInMap = (insideMap and not WaitingForBuildMenuSelection)
            MouseState.rPanning = false
        elseif not rDown and MouseState.wasRDown then
            if MouseState.rDownInMap and (InteractionMode == "Place" or InteractionMode == "Paste") then
                InteractionMode = "Select"
                PendingBuildable = nil
                UpdateStatusBanner()
                RefreshDynamicOverlay()
            end
            MouseState.rDownInMap = false
            MouseState.rPanning = false
        end

        -- Mouse Wheel (via ScrollBox offset delta + key/axis fallback) & +/- Keyboard Zoom
        local uiHovered = IsAnyButtonHovered()
        if not WaitingForBuildMenuSelection and not uiHovered then
            local scrollDelta = keyZoom
            if scrollDelta == 0 and MapUI and Core.IsValidObj(MapUI.WheelScrollBox) and MapUI.WheelScrollBox.GetScrollOffset then
                pcall(function()
                    local off = tonumber(MapUI.WheelScrollBox:GetScrollOffset())
                    if IsFiniteNum(off) and math.abs(off - 2000.0) > 0.25 then
                        scrollDelta = (off < 2000.0) and 1 or -1
                        MapUI.WheelScrollBox:SetScrollOffset(2000.0)
                    end
                end)
            end
            if scrollDelta == 0 then
                pcall(function()
                    local K = Perf.MapKeys
                    if K.WheelUp and pc:WasInputKeyJustPressed(K.WheelUp) then scrollDelta = 1
                    elseif K.WheelDown and pc:WasInputKeyJustPressed(K.WheelDown) then scrollDelta = -1
                    elseif K.WheelAxis and pc.GetInputAnalogKeyState then
                        local wAxis = tonumber(pc:GetInputAnalogKeyState(K.WheelAxis)) or 0.0
                        if wAxis > 0.05 then scrollDelta = 1
                        elseif wAxis < -0.05 then scrollDelta = -1 end
                    end
                end)
            end
            if scrollDelta ~= 0 then
                ZoomMapByFactor((scrollDelta > 0) and 1.18 or (1.0 / 1.18), insideMap and mx or nil, insideMap and my or nil)
            end
        end

        MouseState.wasLDown = lDown
        MouseState.wasRDown = rDown

        -- Throttled live refresh of player markers (~1.0s) so remote MP players update while map stays open
        if RefreshPlayerMarkers then
            local nowMarker = os.clock()
            if (nowMarker - (MapUI.LastPlayerMarkerClock or 0.0)) >= 1.0 then
                MapUI.LastPlayerMarkerClock = nowMarker
                RefreshPlayerMarkers()
            end
        end

        -- Only rebuild screen-space overlay when cursor actually moved (never churn when stationary during box-select)
        if MouseState.lDraggingBox or InteractionMode ~= "Select" then
            if cursorMoved then
                RefreshDynamicOverlay()
            end
        elseif cursorMoved then
            local curPort = nil
            local curPortObj = nil
            local curMachine = nil
            local curMachineObj = nil
            if insideMap and not MouseState.rPanning and not uiHovered then
                local wx, wy = CanvasToWorld(mx, my)
                local hitPort = Perf.FindHoveredPortAt(wx, wy)
                if hitPort then
                    curPort = hitPort.idx
                    curPortObj = hitPort
                elseif #RenderedMachines > 0 then
                    local hitMach = Perf.FindHoveredMachineAt(wx, wy)
                    if hitMach then
                        curMachine = hitMach.addr
                        curMachineObj = hitMach
                    end
                end
            end
            if curPort ~= LastHoveredPortIdx or curMachine ~= LastHoveredMachineAddr
                or ((curPort == nil and curMachine == nil) and LastHadDynamicOverlay)
            then
                RefreshDynamicOverlay(curPortObj, curMachineObj, true)
            end
        end

        ExecuteInGameThreadAfterFrames(1, Tick)
    end

    ExecuteInGameThreadAfterFrames(1, Tick)
end

--------------------------------------------------------------------------------
-- Window Open / Close & Toolbar Actions
--------------------------------------------------------------------------------

-- Revalidates session-persisted PendingGhosts and PendingDeletes against live machines on CurrentFloors:
-- - Prunes PendingDeletes whose machines were already disassembled.
-- - Re-evaluates each staged ghost using the exact Smart Replace / overlap rules (EvaluatePasteGhostOverlap):
--   updates isReplace/replaceTargets for valid overwrites, and removes ghosts that now overlap incompatible machines.
-- - Refreshes Modification Cost, Build Validation, and Apply Changes while keeping performance O(1) when empty.
RevalidatePendingChanges = function(forceRefreshUI)
    if #PendingGhosts == 0 and next(PendingDeletes) == nil then
        if forceRefreshUI then
            UpdateActionBar(true)
            UpdateStatusBanner()
        end
        return false
    end

    local liveMachineAddrs = {}
    for _, fl in ipairs(CurrentFloors) do
        if fl and fl.machines then
            for _, me in ipairs(fl.machines) do
                if Core.IsValidObj(me.machine) then
                    liveMachineAddrs[me.machine:GetAddress()] = true
                end
            end
        end
    end

    local changed = false

    -- 1. Prune invalidated PendingDeletes
    for addr, dm in pairs(PendingDeletes) do
        if not dm or not Core.IsValidObj(dm.machine) or not liveMachineAddrs[addr] then
            PendingDeletes[addr] = nil
            changed = true
        end
    end

    -- 2. Revalidate PendingGhosts against live floor machines using Smart Replace rules
    if #PendingGhosts > 0 then
        local keptGhosts = {}
        for _, g in ipairs(PendingGhosts) do
            local fl = CurrentFloors[g.floorIdx] or CurrentFloors[SelectedFloorIdx]
            if fl and Core.IsValidObj(g.buildable) then
                local allowed, isReplace, replaceTargets = EvaluatePasteGhostOverlap(
                    g, g.x, g.y, g.pairX, g.pairY, g.yaw or 0.0, fl
                )
                if not allowed then
                    if g.ghostId then
                        SelectedGhosts[g.ghostId] = nil
                    end
                    changed = true
                else
                    local oldTargetN = g.replaceTargets and #g.replaceTargets or 0
                    local newTargetN = replaceTargets and #replaceTargets or 0
                    if (g.isReplace == true) ~= (isReplace == true) or oldTargetN ~= newTargetN then
                        changed = true
                    elseif oldTargetN > 0 then
                        for i = 1, oldTargetN do
                            local oa = g.replaceTargets[i] and g.replaceTargets[i].addr or nil
                            local na = replaceTargets[i] and replaceTargets[i].addr or nil
                            if oa ~= na then
                                changed = true
                                break
                            end
                        end
                    end
                    g.isReplace = isReplace
                    g.replaceTargets = replaceTargets
                    keptGhosts[#keptGhosts + 1] = g
                end
            else
                keptGhosts[#keptGhosts + 1] = g
            end
        end
        PendingGhosts = keptGhosts
    end

    if changed then
        RefreshSelectionLayer()
        UpdateStatusBanner()
    elseif forceRefreshUI then
        UpdateActionBar(true)
        UpdateStatusBanner()
    end
    return changed
end

local function SetStationMapCursorMode(pc, win, active)
    if not Core.IsValidObj(pc) then return end
    if not active and Core.IsAnyWidgetClassVisible("WBP_MainMenu_C") then
        -- Main Menu Cursor Preservation (learning.md §8): never hide cursor on the title screen
        SavedCharInputEnabled = nil
        return
    end
    pcall(function()
        pc.bShowMouseCursor = active
        if active then
            if SavedCharInputEnabled == nil then
                SavedCharInputEnabled = (pc.CharacterInputEnabled == true)
            end
            if pc.AllowCharacterInput then pc:AllowCharacterInput(false) end
            if pc.SetIgnoreMoveInput then pc:SetIgnoreMoveInput(true) end
            if pc.SetIgnoreLookInput then pc:SetIgnoreLookInput(true) end
        else
            if pc.AllowCharacterInput then
                pc:AllowCharacterInput(SavedCharInputEnabled ~= false)
            end
            SavedCharInputEnabled = nil
            if pc.ResetIgnoreMoveInput then pc:ResetIgnoreMoveInput() end
            if pc.ResetIgnoreLookInput then pc:ResetIgnoreLookInput() end
            if pc.SetIgnoreMoveInput then pc:SetIgnoreMoveInput(false) end
            if pc.SetIgnoreLookInput then pc:SetIgnoreLookInput(false) end
        end
    end)
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) then
        pcall(function() widgetSub:SetCursorVisible(active) end)
    end
    local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    if Core.IsValidObj(wbl) then
        pcall(function()
            if active then
                wbl:SetInputMode_GameAndUIEx(pc, win, 0, false, false)
            else
                wbl:SetInputMode_GameOnly(pc, false)
            end
        end)
    end
end

local function DestroyStationMap()
    local wasVisible = MapWinVisible
    CanvasRenderGen = CanvasRenderGen + 1
    MachineRenderGen = MachineRenderGen + 1
    OnViewportChangedStatic = nil
    OnViewportChangedMachines = nil
    SyncFloorMachinesIncremental = nil
    RefreshSingleMachineVisual = nil
    RefreshPlayerMarkers = nil
    RenderedMachineWidgets = {}
    PlayerMarkerWidgets = {}
    SelectedMachines = {}
    PendingGhosts = {}
    PendingDeletes = {}
    SelectedGhosts = {}
    ApplyInProgress = false
    CurrentStation = nil
    CurrentWalkFrame = nil
    CurrentFloors = {}
    GhostPreviewSig = nil
    MapWinVisible = false
    MapWinInViewport = false
    InteractionMode = "Select"
    PendingBuildable = nil
    WaitingForBuildMenuSelection = false
    Perf.DestroyActiveRT()
    RenderedMachines = {}
    RenderedConveyors = {}
    RenderedPorts = {}
    Perf.MachineGrid = {}
    Perf.PortGrid = {}
    RenderedGridLines = {}
    Perf.LastIconCanvasVisible = nil
    LastGridTier = nil
    LastGridZoomRatio = nil
    LastHoveredPortIdx = nil
    for _, entry in pairs(FloorIconButtons) do
        if type(entry) == "table" and entry.btn then
            Core.UnregisterWBPButtonClick(entry.btn)
        else
            Core.UnregisterWBPButtonClick(entry)
        end
    end
    UnregisterButtonList(FloorRailButtons)
    UnregisterButtonList(TrackedButtons)
    FloorIconButtons = {}
    FloorRailButtons = {}
    TrackedButtons = {}
    if Core.IsValidObj(ActiveMapWin) then
        pcall(function() ActiveMapWin:RemoveFromParent() end)
    end
    ActiveMapWin = nil
    MapUI = nil
    if wasVisible then
        SetStationMapCursorMode(Core.GetLocalPlayerController(), nil, false)
    end
end

CloseStationMap = function()
    local wasVisible = MapWinVisible
    MapWinVisible = false
    InteractionMode = "Select"
    PendingBuildable = nil
    WaitingForBuildMenuSelection = false
    MouseState.lDownInMap = false
    MouseState.lDraggingBox = false
    MouseState.lPanning = false
    MouseState.rDownInMap = false
    MouseState.rPanning = false
    if MapUI and MapUI.CloseBtnWasHovered then
        MapUI.CloseBtnWasHovered = false
        pcall(function()
            if Core.IsValidObj(MapUI.CloseBtnFrame) then
                MapUI.CloseBtnFrame:SetBrushColor({ R = 0.92, G = 0.94, B = 0.96, A = 0.95 })
            end
            if Core.IsValidObj(MapUI.CloseBtnWidget) and MapUI.CloseBtnWidget.SetBackgroundColour then
                MapUI.CloseBtnWidget:SetBackgroundColour({ R = 0.06, G = 0.07, B = 0.09, A = 0.92 })
            end
            if Core.IsValidObj(MapUI.CloseBtnText) and Core.IsValidObj(MapUI.CloseBtnText.TextBlock)
                and MapUI.CloseBtnText.TextBlock.SetColorAndOpacity
            then
                MapUI.CloseBtnText.TextBlock:SetColorAndOpacity({
                    SpecifiedColor = { R = 0.98, G = 0.98, B = 1.00, A = 1.00 },
                    ColorUseRule = 0,
                })
            end
        end)
    end
    if Core.IsValidObj(ActiveMapWin) then
        pcall(function() ActiveMapWin:SetVisibility(1) end) -- Collapsed (keeps UMG tree cached for instant re-open)
    end
    if wasVisible then
        SetStationMapCursorMode(Core.GetLocalPlayerController(), nil, false)
    end
end

local CachedMouseIconTex = {}
local MouseIconSearched = {}

local function FindMouseIconTexture(side)
    if Core.IsValidObj(CachedMouseIconTex[side]) then return CachedMouseIconTex[side] end
    if MouseIconSearched[side] then return nil end

    local isLeft = (side == "LMB")
    local candidatePaths = isLeft and {
        "/Game/Materials/Icons/UI/T_UI_LMB.T_UI_LMB",
        "/Game/Materials/UI_Textures/T_LMB.T_LMB",
        "/Game/Materials/Icons/T_LMB.T_LMB",
    } or {
        "/Game/Materials/Icons/UI/T_UI_RMB.T_UI_RMB",
        "/Game/Materials/UI_Textures/T_RMB.T_RMB",
        "/Game/Materials/Icons/T_RMB.T_RMB",
    }
    for _, p in ipairs(candidatePaths) do
        local tex = Core.FindOrLoadClass(p)
        if Core.IsValidObj(tex) then
            CachedMouseIconTex[side] = tex
            return tex
        end
    end

    -- Never scan FindAllOf("Texture2D") over thousands of engine textures for LMB/RMB icons;
    -- Station Map legend falls back cleanly to crisp "LMB"/"RMB" text badges when absent.
    MouseIconSearched[side] = true
    return nil
end

local function OpenStationMap()
    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return end

    local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
    if not inStation or not Core.IsValidObj(walkFrame) then
        local worldSub = Core.GetWorldSubsystem(pc, Core.PATHS.WorldSubsystemClass)
        if Core.IsValidObj(worldSub) then
            local okW, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
            if okW and Core.IsValidObj(dmsWorld) and dmsWorld.Stations then
                StationData.ForEachArray(dmsWorld.Stations, function(_, elem)
                    if not Core.IsValidObj(station) then
                        station = Core.UnwrapArrayElem(elem)
                    end
                end)
            end
        end
    end

    if not Core.IsValidObj(station) and not Core.IsValidObj(walkFrame) then
        Core.Log("StationMap: no station found for player")
        return
    end

    -- Fast path: reuse hidden Station Map window for the same station (instant <5ms re-open)
    if MapWinInViewport and Core.IsValidObj(ActiveMapWin) and MapUI and Core.IsValidObj(CurrentStation) and Core.IsValidObj(station)
        and CurrentStation:GetAddress() == station:GetAddress()
    then
        local tFast = os.clock()
        MapWinVisible = true
        pcall(function()
            if ActiveMapWin.IsInViewport and not ActiveMapWin:IsInViewport() then
                ActiveMapWin:AddToViewport(200)
            end
            ActiveMapWin:SetVisibility(0)
        end) -- Visible
        SetStationMapCursorMode(pc, ActiveMapWin, true)
        MouseState.wasLDown = false
        MouseState.wasRDown = false
        MouseState.lDownInMap = false
        MouseState.lDraggingBox = false
        MouseState.lPanning = false
        MouseState.rDownInMap = false
        MouseState.rPanning = false
        EnsureInputPoll()
        RefreshDynamicOverlay()
        if RefreshPlayerMarkers then
            RefreshPlayerMarkers()
        end
        RevalidatePendingChanges(true)
        ExecuteInGameThreadAfterFrames(2, function()
            if not IsMapOpen() then return end
            local curFl = CurrentFloors[SelectedFloorIdx]
            if Perf.ActiveRT and curFl and curFl.walls and #curFl.walls > 0 and Perf.ActiveRT.GetTileCount() == 0 then
                RefreshStationMapCanvas(true)
            elseif SyncFloorMachinesIncremental then
                SyncFloorMachinesIncremental()
            end
        end)
        Core.Log(string.format("[StationMap] Reused cached map window in %.1fms", (os.clock() - tFast) * 1000.0))
        return
    end

    if Core.IsValidObj(ActiveMapWin) then
        DestroyStationMap()
    end

    local isPlainRoot = false
    local win = Core.CreateUserWidget("/Script/UMG.UserWidget", pc, pc)
    if Core.IsValidObj(win) and Core.IsValidObj(win.WidgetTree) then
        isPlainRoot = true
    else
        win = Core.CreateUserWidget(PATHS.WindowBaseClass, pc, pc)
    end
    if not Core.IsValidObj(win) then
        Core.Log("StationMap: failed to construct fullscreen root widget")
        return
    end

    ActiveMapWin = win
    MapWinVisible = true
    MapWinInViewport = true
    local outer = Core.GetWidgetOuter(win)

    if not isPlainRoot then
        pcall(function()
            win:SetWindowName(Core.MakeText("Station Map"))
            win:AddToViewport(200)
            win:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            if win.SetAlignmentInViewport then
                win:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
            end
            if Core.IsValidObj(win.WBP_WindowHeader) then
                win.WBP_WindowHeader:SetVisibility(1) -- Collapsed (fullscreen map, no titlebar)
            end
            local cur = win.Content
            for _ = 1, 5 do
                if not Core.IsValidObj(cur) then break end
                if cur.SetPadding then
                    pcall(function() cur:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end)
                end
                if cur.SetBrushColor then
                    pcall(function() cur:SetBrushColor(COLORS.Transparent) end)
                end
                local sl = cur.Slot
                if Core.IsValidObj(sl) and sl.SetPadding then
                    pcall(function() sl:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end)
                end
                local okP, par = pcall(function() return cur:GetParent() end)
                cur = okP and par or nil
            end
        end)
    end
    SetStationMapCursorMode(pc, win, true)

    local mapBg = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local mapOverlay = Core.CreateRawWidget(PATHS.OverlayClass, outer)
    local bgPanZoom = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local mapCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local machineCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local selectionCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local ghostPreviewCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local ghostPreviewSlot = nil
    local mapInvBox = nil
    local machineInvBox = nil
    local wheelScrollBox = Core.CreateRawWidget(PATHS.ScrollBoxClass, outer)
    local wheelSpacer = Core.CreateRawWidget(PATHS.SizeBoxClass, outer)
    local iconPanZoom = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local iconCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)
    local overlayCanvas = Core.CreateRawWidget(PATHS.CanvasPanelClass, outer)

    if not (Core.IsValidObj(mapBg) and Core.IsValidObj(mapOverlay) and Core.IsValidObj(bgPanZoom)
        and Core.IsValidObj(mapCanvas) and Core.IsValidObj(selectionCanvas)
        and Core.IsValidObj(overlayCanvas)) then
        DestroyStationMap()
        return
    end

    TrackedButtons = {}
    CursorDiagLogged = false
    LastHoveredConvAddr = nil
    LastHadDynamicOverlay = false

    pcall(function()
        mapBg:SetBrushColor(COLORS.WindowBg)
        mapBg:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
        mapBg:SetClipping(1)
        mapOverlay:SetClipping(1)
        bgPanZoom:SetClipping(0)
        bgPanZoom:SetVisibility(4) -- SelfHitTestInvisible
        mapCanvas:SetClipping(0)
        selectionCanvas:SetClipping(0)
        selectionCanvas:SetVisibility(4)
        overlayCanvas:SetClipping(1)
        overlayCanvas:SetVisibility(4) -- SelfHitTestInvisible

        mapInvBox = Core.CreateRawWidget("/Script/UMG.InvalidationBox", outer)
        local mapChild = mapCanvas
        if Core.IsValidObj(mapInvBox) then
            pcall(function()
                mapInvBox:SetCanCache(true)
                mapInvBox:SetClipping(0)
                mapInvBox:SetVisibility(4)
                mapInvBox:AddChild(mapCanvas)
            end)
            mapChild = mapInvBox
        end
        local mcSlot = bgPanZoom:AddChildToCanvas(mapChild)
        if Core.IsValidObj(mcSlot) then
            mcSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            mcSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            mcSlot:SetZOrder(0)
        end
        if Core.IsValidObj(machineCanvas) then
            machineCanvas:SetClipping(0)
            machineCanvas:SetVisibility(4)
            machineInvBox = Core.CreateRawWidget("/Script/UMG.InvalidationBox", outer)
            local machChild = machineCanvas
            if Core.IsValidObj(machineInvBox) then
                pcall(function()
                    machineInvBox:SetCanCache(true)
                    machineInvBox:SetClipping(0)
                    machineInvBox:SetVisibility(4)
                    machineInvBox:AddChild(machineCanvas)
                end)
                machChild = machineInvBox
            end
            local machSlot = bgPanZoom:AddChildToCanvas(machChild)
            if Core.IsValidObj(machSlot) then
                machSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                machSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                machSlot:SetZOrder(1)
            end
        end
        local scSlot = bgPanZoom:AddChildToCanvas(selectionCanvas)
        if Core.IsValidObj(scSlot) then
            scSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            scSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            scSlot:SetZOrder(2)
        end
        if Core.IsValidObj(ghostPreviewCanvas) then
            ghostPreviewCanvas:SetClipping(0)
            ghostPreviewCanvas:SetVisibility(1) -- Collapsed until Place/Paste active
            ghostPreviewSlot = bgPanZoom:AddChildToCanvas(ghostPreviewCanvas)
            if Core.IsValidObj(ghostPreviewSlot) then
                ghostPreviewSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                ghostPreviewSlot:SetAlignment({ X = 0.0, Y = 0.0 })
                ghostPreviewSlot:SetSize({ X = 0.0, Y = 0.0 })
                ghostPreviewSlot:SetPosition({ X = 0.0, Y = 0.0 })
                ghostPreviewSlot:SetZOrder(3)
            end
        end
        local bpSlot = mapOverlay:AddChildToOverlay(bgPanZoom)
        if Core.IsValidObj(bpSlot) then
            bpSlot:SetHorizontalAlignment(0)
            bpSlot:SetVerticalAlignment(0)
        end

        if Core.IsValidObj(wheelScrollBox) and Core.IsValidObj(wheelSpacer) then
            wheelSpacer:SetHeightOverride(5000.0)
            wheelSpacer:SetVisibility(4)
            wheelScrollBox:AddChild(wheelSpacer)
            pcall(function()
                wheelScrollBox:SetScrollBarVisibility(1) -- Collapsed
                wheelScrollBox.bAllowRightClickDragScrolling = false
                wheelScrollBox.bAnimateWheelScrolling = false
                wheelScrollBox.ConsumeMouseWheel = 1 -- Always
                wheelScrollBox:SetScrollOffset(2000.0)
            end)
            local wsSlot = mapOverlay:AddChildToOverlay(wheelScrollBox)
            if Core.IsValidObj(wsSlot) then
                wsSlot:SetHorizontalAlignment(0)
                wsSlot:SetVerticalAlignment(0)
            end
        end

        if Core.IsValidObj(iconPanZoom) and Core.IsValidObj(iconCanvas) then
            iconPanZoom:SetClipping(0)
            iconPanZoom:SetVisibility(4)
            iconCanvas:SetClipping(0)
            iconCanvas:SetVisibility(4) -- SelfHitTestInvisible; child icon buttons remain clickable!
            local icChildSlot = iconPanZoom:AddChildToCanvas(iconCanvas)
            if Core.IsValidObj(icChildSlot) then
                icChildSlot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
                icChildSlot:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end
            local icSlot = mapOverlay:AddChildToOverlay(iconPanZoom)
            if Core.IsValidObj(icSlot) then
                icSlot:SetHorizontalAlignment(0)
                icSlot:SetVerticalAlignment(0)
            end
        end
        local ovSlot = mapOverlay:AddChildToOverlay(overlayCanvas)
        if Core.IsValidObj(ovSlot) then
            ovSlot:SetHorizontalAlignment(0)
            ovSlot:SetVerticalAlignment(0)
        end
        mapBg:AddChild(mapOverlay)

        if isPlainRoot then
            win.WidgetTree.RootWidget = mapBg
            win:AddToViewport(200)
            win:SetAnchorsInViewport({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } })
            if win.SetAlignmentInViewport then
                win:SetAlignmentInViewport({ X = 0.0, Y = 0.0 })
            end
        else
            local attached = false
            if Core.IsValidObj(win.Content) then
                local okC = pcall(function() win.Content:AddChild(mapBg) end)
                if okC then attached = true end
            end
            if not attached and Core.IsValidObj(win.ContentBorder) then
                pcall(function() win.ContentBorder:AddChild(mapBg) end)
            end
            win:SetContentForSlot(FName("Content"), mapBg)

            local cur = mapBg
            for _ = 1, 8 do
                if not Core.IsValidObj(cur) then break end
                local curAddr = cur:GetAddress()
                local sl = cur.Slot
                if Core.IsValidObj(sl) then
                    if sl.SetPadding then pcall(function() sl:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end) end
                    if sl.SetHorizontalAlignment then pcall(function() sl:SetHorizontalAlignment(0) end) end
                    if sl.SetVerticalAlignment then pcall(function() sl:SetVerticalAlignment(0) end) end
                    if sl.SetAnchors then pcall(function() sl:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 1.0 } }) end) end
                    if sl.SetOffsets then pcall(function() sl:SetOffsets({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end) end
                end
                local okP, par = pcall(function() return cur:GetParent() end)
                if not okP or not Core.IsValidObj(par) then break end
                if par.SetPadding then pcall(function() par:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 }) end) end
                if par.SetBrushColor then pcall(function() par:SetBrushColor(COLORS.Transparent) end) end
                if par.GetChildrenCount and par.GetChildAt then
                    pcall(function()
                        local cnt = par:GetChildrenCount()
                        for i = 0, cnt - 1 do
                            local ch = par:GetChildAt(i)
                            if Core.IsValidObj(ch) and ch:GetAddress() ~= curAddr then
                                ch:SetVisibility(1)
                            end
                        end
                    end)
                end
                cur = par
            end
        end
    end)

    -- Shared base-game overlay palette (matching World Map & Ship/Station Designer)
    local accentGold   = { R = 0.90, G = 0.62, B = 0.08, A = 0.96 }
    local accentGoldDim= { R = 0.90, G = 0.62, B = 0.08, A = 0.65 }
    local panelBgDark  = { R = 0.055, G = 0.062, B = 0.075, A = 0.90 }
    local btnBgDark    = { R = 0.13, G = 0.15, B = 0.18, A = 0.92 }
    local btnBgDiscard = { R = 0.34, G = 0.11, B = 0.11, A = 0.94 }
    local pillBgMode   = { R = 0.10, G = 0.28, B = 0.18, A = 0.95 }
    local pillBgSel    = { R = 0.38, G = 0.25, B = 0.05, A = 0.95 }
    local pillBgDel    = { R = 0.40, G = 0.11, B = 0.11, A = 0.95 }

    local function makeAccentBar(col, heightPx)
        local sb = CreateRawFast(PATHS.SizeBoxClass, outer)
        local bdr = CreateRawFast(PATHS.BorderClass, outer)
        if Core.IsValidObj(sb) and Core.IsValidObj(bdr) then
            pcall(function()
                sb:SetHeightOverride(heightPx or 3.0)
                bdr:SetBrushColor(col)
                bdr:SetVisibility(3)
                sb:SetVisibility(3)
                sb:AddChild(bdr)
            end)
        end
        return sb
    end

    -- 1. Top-Left Floating Status Pills (temporary pills: Selected, Deleting, Paste/Apply status)
    local function createStatusPill(initText, bgCol, textSize)
        local bdr = CreateRawFast(PATHS.BorderClass, outer)
        local txt = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
        if Core.IsValidObj(bdr) and Core.IsValidObj(txt) then
            pcall(function()
                bdr:SetBrushColor(bgCol)
                bdr:SetPadding({ Left = 12.0, Top = 6.0, Right = 12.0, Bottom = 6.0 })
                bdr:SetVisibility(1) -- Collapsed until active
                txt:SetVisibility(3)
                txt:SetSize(textSize or 11)
                txt:SetText(Core.MakeText(initText or ""))
                bdr:AddChild(txt)
            end)
        end
        return bdr, txt
    end

    local topLeftVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local topLeftPillsHBox = CreateRawFast(PATHS.HorizontalBoxClass, outer)
    local selPillWrap, selPillText = createStatusPill("Selected: 0", pillBgSel, 11)
    local delPillWrap, delPillText = createStatusPill("Deleting: 0", pillBgDel, 11)
    local modePillWrap, modePillText = createStatusPill("", pillBgMode, 11)

    -- Modification Cost panel (Designer-style net material cost overlay beneath status pills)
    local costPanel = CreateRawFast(PATHS.BorderClass, outer)
    local costOuterVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local costScroll = CreateRawFast(PATHS.ScrollBoxClass, outer)
    local costListVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    if Core.IsValidObj(costPanel) and Core.IsValidObj(costOuterVBox) and Core.IsValidObj(costListVBox) then
        pcall(function()
            costPanel:SetBrushColor(panelBgDark)
            costPanel:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            costPanel:SetVisibility(1) -- Collapsed until pending changes exist

            local costHeader = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
            if Core.IsValidObj(costHeader) then
                costHeader:SetVisibility(3)
                costHeader:SetSize(13)
                costHeader:SetText(Core.MakeText("Modification Cost"))
                if Core.IsValidObj(costHeader.TextBlock) and costHeader.TextBlock.SetColorAndOpacity then
                    costHeader.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.PlayerLocal, ColorUseRule = 0 })
                end
                local chSlot = costOuterVBox:AddChildToVerticalBox(costHeader)
                if Core.IsValidObj(chSlot) then
                    chSlot:SetHorizontalAlignment(1)
                    chSlot:SetPadding({ Left = 12.0, Top = 10.0, Right = 14.0, Bottom = 8.0 })
                end
            end

            local listContainer = costListVBox
            if Core.IsValidObj(costScroll) then
                local costScrollSb = CreateRawFast(PATHS.SizeBoxClass, outer)
                costScroll:SetScrollBarVisibility(1)
                costScroll:AddChild(costListVBox)
                if Core.IsValidObj(costScrollSb) then
                    costScrollSb:SetMaxDesiredHeight(300.0)
                    costScrollSb:SetMinDesiredWidth(236.0)
                    costScrollSb:AddChild(costScroll)
                    listContainer = costScrollSb
                else
                    listContainer = costScroll
                end
            end
            local clSlot = costOuterVBox:AddChildToVerticalBox(listContainer)
            if Core.IsValidObj(clSlot) then
                clSlot:SetHorizontalAlignment(0)
                clSlot:SetPadding({ Left = 12.0, Top = 0.0, Right = 14.0, Bottom = 10.0 })
            end

            local costBotBar = makeAccentBar(accentGold, 3.0)
            if Core.IsValidObj(costBotBar) then
                local cbSlot = costOuterVBox:AddChildToVerticalBox(costBotBar)
                if Core.IsValidObj(cbSlot) then cbSlot:SetHorizontalAlignment(0) end
            end

            costPanel:AddChild(costOuterVBox)
        end)
    end

    if Core.IsValidObj(topLeftVBox) and Core.IsValidObj(topLeftPillsHBox) then
        pcall(function()
            topLeftVBox:SetVisibility(4) -- SelfHitTestInvisible
            topLeftPillsHBox:SetVisibility(4) -- SelfHitTestInvisible
        end)
        for idx, pill in ipairs({ selPillWrap, delPillWrap, modePillWrap }) do
            if Core.IsValidObj(pill) then
                local sl = topLeftPillsHBox:AddChildToHorizontalBox(pill)
                if Core.IsValidObj(sl) then
                    pcall(function()
                        sl:SetVerticalAlignment(2)
                        sl:SetPadding({ Left = (idx == 1) and 0.0 or 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end
            end
        end
        local pillsRowSlot = topLeftVBox:AddChildToVerticalBox(topLeftPillsHBox)
        if Core.IsValidObj(pillsRowSlot) then
            pcall(function() pillsRowSlot:SetHorizontalAlignment(1) end)
        end
        if Core.IsValidObj(costPanel) then
            local cpSlot = topLeftVBox:AddChildToVerticalBox(costPanel)
            if Core.IsValidObj(cpSlot) then
                pcall(function()
                    cpSlot:SetHorizontalAlignment(1)
                    cpSlot:SetPadding({ Left = 0.0, Top = 8.0, Right = 0.0, Bottom = 0.0 })
                end)
            end
        end
        local tlSlot = mapOverlay:AddChildToOverlay(topLeftVBox)
        if Core.IsValidObj(tlSlot) then
            pcall(function()
                tlSlot:SetHorizontalAlignment(1) -- Left
                tlSlot:SetVerticalAlignment(1)   -- Top
                tlSlot:SetPadding({ Left = 14.0, Top = 14.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    -- 2. Top-Right Close (X) Button Overlay (matching World Map top-right X, orange hover highlight)
    local closeBtnFrame = CreateRawFast(PATHS.BorderClass, outer)
    local closeWrap, closeBtn, closeBtnText = CreateLabeledButton(
        win, pc, outer, "X", 16, 32.0, 32.0,
        { R = 0.06, G = 0.07, B = 0.09, A = 0.92 },
        { R = 0.98, G = 0.98, B = 1.00, A = 1.00 },
        function()
            ExecuteInGameThreadWithDelay(10, CloseStationMap)
        end
    )
    if Core.IsValidObj(closeBtnFrame) and Core.IsValidObj(closeWrap) then
        pcall(function()
            closeBtnFrame:SetBrushColor({ R = 0.92, G = 0.94, B = 0.96, A = 0.95 })
            closeBtnFrame:SetPadding({ Left = 2.0, Top = 2.0, Right = 2.0, Bottom = 2.0 })
            closeBtnFrame:AddChild(closeWrap)
        end)
        local clSlot = mapOverlay:AddChildToOverlay(closeBtnFrame)
        if Core.IsValidObj(clSlot) then
            pcall(function()
                clSlot:SetHorizontalAlignment(3) -- Right
                clSlot:SetVerticalAlignment(1)   -- Top
                clSlot:SetPadding({ Left = 0.0, Top = 14.0, Right = 14.0, Bottom = 0.0 })
            end)
        end
    end

    -- 3. Bottom-Left Keybind Hints Overlay (matching World Map bottom-left style)
    local keybindsVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local hintSelectLabel, hintCopyRow, hintDeleteRow, hintRotateRow, hintCancelRow = nil, nil, nil, nil, nil
    if Core.IsValidObj(keybindsVBox) then
        pcall(function() keybindsVBox:SetVisibility(4) end) -- SelfHitTestInvisible
        local lmbTex = FindMouseIconTexture("LMB")
        local rmbTex = FindMouseIconTexture("RMB")
        local keybindDefs = {
            { id = "select", key = "LMB",    iconTex = lmbTex, label = "Box Select",      conditional = false },
            { id = "pan",    key = "WASD",   iconTex = nil,    label = "Pan Map",         conditional = false },
            { id = "zoom",   key = "SCROLL", iconTex = nil,    label = "Zoom",            conditional = false },
            { id = "copy",   key = "CTRL+C", iconTex = nil,    label = "Copy Selected",   conditional = true  },
            { id = "delete", key = "X",      iconTex = nil,    label = "Delete Selected", conditional = true  },
            { id = "rotate", key = "R",      iconTex = nil,    label = "Rotate",          conditional = true  },
            { id = "cancel", key = "RMB",    iconTex = rmbTex, label = "Cancel",          conditional = true  },
        }
        local hintLabelCol = { R = 0.86, G = 0.88, B = 0.92, A = 0.96 }
        local capFillCol   = { R = 0.0194, G = 0.0194, B = 0.0194, A = 0.78 } -- ~#262626 in sRGB, slightly translucent

        local function applyRoundedBadgeStyle(bdr, padTbl)
            pcall(function()
                bdr:SetBrushColor(capFillCol)
                bdr:SetPadding(padTbl)
                bdr:SetVisibility(3)
                local bg = bdr.Background
                if bg then
                    bg.DrawAs = 4 -- ESlateBrushDrawType::RoundedBox
                    if bg.OutlineSettings then
                        bg.OutlineSettings.CornerRadii = { X = 3.0, Y = 3.0, Z = 3.0, W = 3.0 }
                        bg.OutlineSettings.RoundingType = 0 -- ESlateBrushRoundingType::FixedRadius (0=FixedRadius, 1=HalfHeightRadius)
                        bg.OutlineSettings.Width = 0.0
                        bg.OutlineSettings.bUseBrushTransparency = true
                    end
                    bdr:SetBrush(bg)
                end
            end)
        end

        for rIdx, def in ipairs(keybindDefs) do
            local rowHBox = CreateRawFast(PATHS.HorizontalBoxClass, outer)
            if Core.IsValidObj(rowHBox) then
                pcall(function() rowHBox:SetVisibility(def.conditional and 1 or 3) end) -- Conditional rows start Collapsed
                local capBg = CreateRawFast(PATHS.BorderClass, outer)
                if Core.IsValidObj(capBg) then
                    local builtBadge = false
                    if Core.IsValidObj(def.iconTex) then
                        local iconSb = CreateRawFast(PATHS.SizeBoxClass, outer)
                        local iconImg = CreateRawFast(PATHS.ImageClass, outer)
                        if Core.IsValidObj(iconSb) and Core.IsValidObj(iconImg) then
                            applyRoundedBadgeStyle(capBg, { Left = 4.0, Top = 3.0, Right = 4.0, Bottom = 3.0 })
                            pcall(function()
                                iconSb:SetWidthOverride(18.0)
                                iconSb:SetHeightOverride(18.0)
                                iconSb:SetVisibility(3)
                                iconImg:SetBrushFromTexture(def.iconTex, false)
                                iconImg:SetVisibility(3)
                                iconSb:AddChild(iconImg)
                                capBg:AddChild(iconSb)
                            end)
                            builtBadge = true
                        end
                    end
                    if not builtBadge then
                        local capTxt = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                        if Core.IsValidObj(capTxt) then
                            applyRoundedBadgeStyle(capBg, { Left = 7.0, Top = 2.0, Right = 7.0, Bottom = 2.0 })
                            pcall(function()
                                capTxt:SetVisibility(3)
                                capTxt:SetSize(10)
                                capTxt:SetText(Core.MakeText(def.key))
                                if Core.IsValidObj(capTxt.TextBlock) and capTxt.TextBlock.SetColorAndOpacity then
                                    capTxt.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.PlayerLocal, ColorUseRule = 0 })
                                end
                                capBg:AddChild(capTxt)
                            end)
                            builtBadge = true
                        end
                    end
                    if builtBadge then
                        local kSlot = rowHBox:AddChildToHorizontalBox(capBg)
                        if Core.IsValidObj(kSlot) then
                            pcall(function() kSlot:SetVerticalAlignment(2) end)
                        end
                    end
                end

                local lbl = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                if Core.IsValidObj(lbl) then
                    pcall(function()
                        lbl:SetVisibility(3)
                        lbl:SetSize(11)
                        lbl:SetText(Core.MakeText(def.label))
                        if Core.IsValidObj(lbl.TextBlock) and lbl.TextBlock.SetColorAndOpacity then
                            lbl.TextBlock:SetColorAndOpacity({ SpecifiedColor = hintLabelCol, ColorUseRule = 0 })
                        end
                    end)
                    local lSlot = rowHBox:AddChildToHorizontalBox(lbl)
                    if Core.IsValidObj(lSlot) then
                        pcall(function()
                            lSlot:SetVerticalAlignment(2)
                            lSlot:SetPadding({ Left = 8.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                        end)
                    end
                end

                local rSlot = keybindsVBox:AddChildToVerticalBox(rowHBox)
                if Core.IsValidObj(rSlot) then
                    pcall(function()
                        rSlot:SetHorizontalAlignment(1) -- Left
                        rSlot:SetPadding({ Left = 0.0, Top = (rIdx == 1) and 0.0 or 5.0, Right = 0.0, Bottom = 0.0 })
                    end)
                end

                if def.id == "select" then hintSelectLabel = lbl
                elseif def.id == "copy" then hintCopyRow = rowHBox
                elseif def.id == "delete" then hintDeleteRow = rowHBox
                elseif def.id == "rotate" then hintRotateRow = rowHBox
                elseif def.id == "cancel" then hintCancelRow = rowHBox
                end
            end
        end

        local blSlot = mapOverlay:AddChildToOverlay(keybindsVBox)
        if Core.IsValidObj(blSlot) then
            pcall(function()
                blSlot:SetHorizontalAlignment(1) -- Left
                blSlot:SetVerticalAlignment(3)   -- Bottom
                blSlot:SetPadding({ Left = 10.0, Top = 0.0, Right = 0.0, Bottom = 14.0 })
            end)
        end
    end

    -- 4. Center-Right Floating Vertical Paginated Floor Selector Overlay
    local floorFrame = Core.CreateRawWidget(PATHS.BorderClass, outer)
    local floorOuterVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local floorInnerVBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local floorSlotsBox = Core.CreateRawWidget(PATHS.VerticalBoxClass, outer)
    local floorUpWrap, floorUpBtn, floorUpText = CreateLabeledButton(win, pc, outer, "↑", 15, 60.0, 30.0, btnBgDark, COLORS.PlayerLocal, function()
        ExecuteInGameThreadWithDelay(10, function()
            local total = #CurrentFloors
            if total > FLOOR_PAGE_SIZE and FloorPageTopIdx and FloorPageTopIdx < total then
                FloorPageTopIdx = math.min(total, FloorPageTopIdx + 1)
                RebuildFloorButtons()
            end
        end)
    end)
    local floorDownWrap, floorDownBtn, floorDownText = CreateLabeledButton(win, pc, outer, "↓", 15, 60.0, 30.0, btnBgDark, COLORS.PlayerLocal, function()
        ExecuteInGameThreadWithDelay(10, function()
            local minTop = math.min(#CurrentFloors, FLOOR_PAGE_SIZE)
            if FloorPageTopIdx and FloorPageTopIdx > minTop then
                FloorPageTopIdx = math.max(minTop, FloorPageTopIdx - 1)
                RebuildFloorButtons()
            end
        end)
    end)

    if Core.IsValidObj(floorFrame) and Core.IsValidObj(floorOuterVBox) and Core.IsValidObj(floorInnerVBox) and Core.IsValidObj(floorSlotsBox) then
        pcall(function()
            floorFrame:SetBrushColor(panelBgDark)
            floorFrame:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })

            local topBar = makeAccentBar(accentGold, 3.0)
            if Core.IsValidObj(topBar) then
                local tbSlot = floorOuterVBox:AddChildToVerticalBox(topBar)
                if Core.IsValidObj(tbSlot) then tbSlot:SetHorizontalAlignment(0) end
            end

            local flHdr = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
            if Core.IsValidObj(flHdr) then
                flHdr:SetVisibility(3)
                flHdr:SetSize(9)
                flHdr:SetText(Core.MakeText("FLOOR"))
                if Core.IsValidObj(flHdr.TextBlock) and flHdr.TextBlock.SetColorAndOpacity then
                    flHdr.TextBlock:SetColorAndOpacity({ SpecifiedColor = accentGold, ColorUseRule = 0 })
                end
                local hSlot = floorOuterVBox:AddChildToVerticalBox(flHdr)
                if Core.IsValidObj(hSlot) then
                    hSlot:SetHorizontalAlignment(2)
                    hSlot:SetPadding({ Left = 0.0, Top = 6.0, Right = 0.0, Bottom = 2.0 })
                end
            end

            if Core.IsValidObj(floorUpWrap) then
                local uSlot = floorInnerVBox:AddChildToVerticalBox(floorUpWrap)
                if Core.IsValidObj(uSlot) then
                    uSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 5.0 })
                    uSlot:SetHorizontalAlignment(2)
                end
            end
            local fsSlot = floorInnerVBox:AddChildToVerticalBox(floorSlotsBox)
            if Core.IsValidObj(fsSlot) then
                fsSlot:SetHorizontalAlignment(2)
                fsSlot:SetVerticalAlignment(2)
            end
            if Core.IsValidObj(floorDownWrap) then
                local dSlot = floorInnerVBox:AddChildToVerticalBox(floorDownWrap)
                if Core.IsValidObj(dSlot) then
                    dSlot:SetPadding({ Left = 0.0, Top = 5.0, Right = 0.0, Bottom = 0.0 })
                    dSlot:SetHorizontalAlignment(2)
                end
            end

            local innerSlot = floorOuterVBox:AddChildToVerticalBox(floorInnerVBox)
            if Core.IsValidObj(innerSlot) then
                innerSlot:SetPadding({ Left = 7.0, Top = 4.0, Right = 7.0, Bottom = 7.0 })
                innerSlot:SetHorizontalAlignment(2)
            end

            local botBar = makeAccentBar(accentGoldDim, 2.0)
            if Core.IsValidObj(botBar) then
                local bbSlot = floorOuterVBox:AddChildToVerticalBox(botBar)
                if Core.IsValidObj(bbSlot) then bbSlot:SetHorizontalAlignment(0) end
            end

            floorFrame:AddChild(floorOuterVBox)
        end)

        local crSlot = mapOverlay:AddChildToOverlay(floorFrame)
        if Core.IsValidObj(crSlot) then
            pcall(function()
                crSlot:SetHorizontalAlignment(3) -- Right
                crSlot:SetVerticalAlignment(2)   -- Center
                crSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    -- 5. Bottom-Right Floating Apply Changes / Discard / Build Validation Overlay (flush bottom-right, Designer style)
    local applyPanel = CreateRawFast(PATHS.BorderClass, outer)
    local applyOuterVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local applyInnerVBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local validationBox = CreateRawFast(PATHS.VerticalBoxClass, outer)
    local applyWrap, applyBtn, applyBtnText = CreateLabeledButton(win, pc, outer, "Apply Changes", 12, 220.0, 38.0, APPLY_BG_DISABLED, APPLY_TXT_DISABLED, function()
        local pendingN = #PendingGhosts + CountTableKeys(PendingDeletes)
        if pendingN == 0 or ApplyInProgress then return end
        Core.Log(string.format("[StationMap] ApplyBtn pressed (pending=%d)", pendingN))
        ExecuteInGameThreadWithDelay(10, CommitPendingGhosts)
    end)
    local discardWrap, discardBtn = CreateLabeledButton(win, pc, outer, "Discard Changes", 11, 220.0, 30.0, btnBgDiscard, COLORS.PlayerLocal, function()
        ExecuteInGameThreadWithDelay(10, function()
            PendingGhosts = {}
            PendingDeletes = {}
            SelectedGhosts = {}
            UpdateActionBar()
            RefreshSelectionLayer()
        end)
    end)

    if Core.IsValidObj(validationBox) then
        pcall(function()
            validationBox:SetVisibility(1) -- Collapsed until missing materials
            local valHdrRow = CreateRawFast(PATHS.HorizontalBoxClass, outer)
            if Core.IsValidObj(valHdrRow) then
                local valTitle = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                if Core.IsValidObj(valTitle) then
                    valTitle:SetVisibility(3)
                    valTitle:SetSize(13)
                    valTitle:SetText(Core.MakeText("Build Validation"))
                    if Core.IsValidObj(valTitle.TextBlock) and valTitle.TextBlock.SetColorAndOpacity then
                        valTitle.TextBlock:SetColorAndOpacity({ SpecifiedColor = COLORS.PlayerLocal, ColorUseRule = 0 })
                    end
                    local vtSlot = valHdrRow:AddChildToHorizontalBox(valTitle)
                    if Core.IsValidObj(vtSlot) then vtSlot:SetVerticalAlignment(2) end
                end
                local valSpacer = CreateRawFast(PATHS.SizeBoxClass, outer)
                if Core.IsValidObj(valSpacer) then
                    valSpacer:SetVisibility(4)
                    local vsSlot = valHdrRow:AddChildToHorizontalBox(valSpacer)
                    if Core.IsValidObj(vsSlot) then vsSlot:SetSize({ Value = 1.0, SizeRule = 1 }) end
                end
                local valX = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
                if Core.IsValidObj(valX) then
                    valX:SetVisibility(3)
                    valX:SetSize(15)
                    valX:SetText(Core.MakeText("X"))
                    SetWBPTextColor(valX, COST_TXT_LACKING)
                    local vxSlot = valHdrRow:AddChildToHorizontalBox(valX)
                    if Core.IsValidObj(vxSlot) then vxSlot:SetVerticalAlignment(2) end
                end
                local vhSlot = validationBox:AddChildToVerticalBox(valHdrRow)
                if Core.IsValidObj(vhSlot) then vhSlot:SetHorizontalAlignment(0) end
            end

            local valMsg = Core.CreateUserWidget(PATHS.WBPTextClass, win, pc)
            if Core.IsValidObj(valMsg) then
                valMsg:SetVisibility(3)
                valMsg:SetSize(11)
                valMsg:SetText(Core.MakeText("Missing Building Materials"))
                SetWBPTextColor(valMsg, COST_TXT_LACKING)
                local vmSlot = validationBox:AddChildToVerticalBox(valMsg)
                if Core.IsValidObj(vmSlot) then
                    vmSlot:SetHorizontalAlignment(3) -- Right-aligned matching Designer Validation
                    vmSlot:SetPadding({ Left = 0.0, Top = 3.0, Right = 0.0, Bottom = 10.0 })
                end
            end
        end)
    end

    if Core.IsValidObj(applyPanel) and Core.IsValidObj(applyOuterVBox) and Core.IsValidObj(applyInnerVBox) then
        pcall(function()
            applyPanel:SetBrushColor(panelBgDark)
            applyPanel:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })

            local aTopBar = makeAccentBar(accentGold, 3.0)
            if Core.IsValidObj(aTopBar) then
                local atSlot = applyOuterVBox:AddChildToVerticalBox(aTopBar)
                if Core.IsValidObj(atSlot) then atSlot:SetHorizontalAlignment(0) end
            end

            if Core.IsValidObj(validationBox) then
                local vbSlot = applyInnerVBox:AddChildToVerticalBox(validationBox)
                if Core.IsValidObj(vbSlot) then vbSlot:SetHorizontalAlignment(0) end
            end
            if Core.IsValidObj(discardWrap) then
                discardWrap:SetVisibility(1) -- Collapsed until pending changes exist
                local dSlot = applyInnerVBox:AddChildToVerticalBox(discardWrap)
                if Core.IsValidObj(dSlot) then
                    dSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 6.0 })
                    dSlot:SetHorizontalAlignment(2)
                end
            end
            if Core.IsValidObj(applyWrap) then
                local aSlot = applyInnerVBox:AddChildToVerticalBox(applyWrap)
                if Core.IsValidObj(aSlot) then
                    aSlot:SetHorizontalAlignment(2)
                end
            end

            local aiSlot = applyOuterVBox:AddChildToVerticalBox(applyInnerVBox)
            if Core.IsValidObj(aiSlot) then
                aiSlot:SetPadding({ Left = 12.0, Top = 10.0, Right = 12.0, Bottom = 12.0 })
                aiSlot:SetHorizontalAlignment(0)
            end

            applyPanel:AddChild(applyOuterVBox)
        end)

        local brSlot = mapOverlay:AddChildToOverlay(applyPanel)
        if Core.IsValidObj(brSlot) then
            pcall(function()
                brSlot:SetHorizontalAlignment(3) -- Right (flush)
                brSlot:SetVerticalAlignment(3)   -- Bottom (flush)
                brSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
            end)
        end
    end

    MapUI = {
        Window = win,
        PC = pc,
        MapBg = mapBg,
        BgPanZoom = bgPanZoom,
        MapCanvas = mapCanvas,
        MapInvBox = mapInvBox,
        MachineCanvas = machineCanvas,
        MachineInvBox = machineInvBox,
        SelectionCanvas = selectionCanvas,
        GhostPreviewCanvas = ghostPreviewCanvas,
        GhostPreviewSlot = ghostPreviewSlot,
        WheelScrollBox = wheelScrollBox,
        IconPanZoom = iconPanZoom,
        IconCanvas = iconCanvas,
        OverlayCanvas = overlayCanvas,
        FloorFrame = floorFrame,
        FloorSlotsBox = floorSlotsBox,
        FloorUpBtn = floorUpWrap,
        FloorUpBtnWidget = floorUpBtn,
        FloorUpBtnText = floorUpText,
        FloorDownBtn = floorDownWrap,
        FloorDownBtnWidget = floorDownBtn,
        FloorDownBtnText = floorDownText,
        ApplyPanel = applyPanel,
        ValidationBox = validationBox,
        ApplyBtn = applyWrap,
        ApplyBtnWidget = applyBtn,
        ApplyBtnText = applyBtnText,
        DiscardBtn = discardWrap,
        CloseBtnFrame = closeBtnFrame,
        CloseBtnWidget = closeBtn,
        CloseBtnText = closeBtnText,
        CloseBtnWasHovered = false,
        CostPanel = costPanel,
        CostListVBox = costListVBox,
        HintSelectLabel = hintSelectLabel,
        HintCopyRow = hintCopyRow,
        HintDeleteRow = hintDeleteRow,
        HintRotateRow = hintRotateRow,
        HintCancelRow = hintCancelRow,
        SelPillWrap = selPillWrap,
        SelPillText = selPillText,
        DelPillWrap = delPillWrap,
        DelPillText = delPillText,
        ModePillWrap = modePillWrap,
        ModePillText = modePillText,
    }

    local px, py, pz = 0.0, 0.0, 0.0
    if Core.IsValidObj(pc.Pawn) then
        local okLoc, loc = pcall(function() return pc.Pawn:K2_GetActorLocation() end)
        if okLoc and loc then
            px = loc.X or 0.0
            py = loc.Y or 0.0
            pz = loc.Z or 0.0
        end
    end

    CurrentStation = station
    CurrentWalkFrame = walkFrame
    local openStationAddr = Core.IsValidObj(station) and station:GetAddress() or nil
    local t0 = os.clock()
    local floors, curIdx, _, gox, goy, xform, isAsyncBuild = StationData.BuildStationFloorMapAsync(station, walkFrame, px, py, pz, function()
        if not IsMapOpen() or not Core.IsValidObj(CurrentStation) then return end
        if openStationAddr and CurrentStation:GetAddress() ~= openStationAddr then return end
        Core.Log(string.format("[StationMap] Async station scan finished in %.0fms; populating floor %d",
            (os.clock() - t0) * 1000.0, SelectedFloorIdx))
        RefreshStationMapCanvas(true)
        UpdateStatusBanner()
    end)
    local t1 = os.clock()
    CurrentFrameXform = xform
    CurrentFloors = floors
    SelectedFloorIdx = curIdx
    FloorPageTopIdx = nil
    ViewTransform.gridOriginX = gox or 0.0
    ViewTransform.gridOriginY = goy or 0.0
    ViewTransform.hasFitted = false
    SelectedMachines = {}
    InteractionMode = "Select"
    MouseState.wasLDown = false
    MouseState.wasRDown = false
    MouseState.lDownInMap = false
    MouseState.lDraggingBox = false
    MouseState.rDownInMap = false
    MouseState.rPanning = false

    RebuildFloorButtons()
    RefreshStationMapCanvas()
    if isAsyncBuild then
        UpdateStatusBanner("Loading station layout...")
    end
    local t2 = os.clock()
    Core.Log(string.format("[StationMap] OpenTiming build=%.0fms canvas=%.0fms total=%.0fms async=%s floor=%d machines=%d walls=%d ports=%d",
        (t1 - t0) * 1000.0, (t2 - t1) * 1000.0, (t2 - t0) * 1000.0, tostring(isAsyncBuild),
        SelectedFloorIdx, #RenderedMachines,
        (CurrentFloors[SelectedFloorIdx] and CurrentFloors[SelectedFloorIdx].walls and #CurrentFloors[SelectedFloorIdx].walls) or 0,
        #RenderedPorts))
    EnsureInputPoll()

    -- Re-fit once after UMG finishes layout pass on frame 2, and pre-inspect BuildMachineCommand signature
    ExecuteInGameThreadAfterFrames(2, function()
        InspectBuildMachineCommandLayout()
        if IsMapOpen() and MeasureMapCanvasSize() then
            FitViewTransformToFloor()
            ApplyViewTransform()
        end
    end)
end

local function ToggleStationMap()
    if not Core.IsFeatureEnabled("StationMap") then
        if IsMapOpen() then CloseStationMap() end
        return
    end
    if IsMapOpen() then
        CloseStationMap()
    else
        OpenStationMap()
    end
end

--------------------------------------------------------------------------------
-- Keybinds inside Station Map (B = Build, R = Rotate, Ctrl+C = Copy, Esc = Cancel)
--------------------------------------------------------------------------------

local function EnsureMapKeybinds()
    if KeyHandlersBound or not Key then return end
    KeyHandlersBound = true

    if Key.X then
        RegisterKeyBind(Key.X, function()
            if IsMapOpen() and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(ProposeDeleteSelected)
            end
        end)
    end

    if Key.R then
        RegisterKeyBind(Key.R, function()
            if IsMapOpen() and (InteractionMode == "Paste" or InteractionMode == "Place") and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    PendingRotationDeg = (PendingRotationDeg + 90) % 360
                    UpdateStatusBanner()
                    RefreshDynamicOverlay()
                end)
            end
        end)
    end

    if Key.C and ModifierKey and ModifierKey.CONTROL then
        RegisterKeyBind(Key.C, { ModifierKey.CONTROL }, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(CopySelectedMachines)
            end
        end)
    elseif Key.C then
        RegisterKeyBind(Key.C, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    local pc = Core.GetLocalPlayerController()
                    local ctrlDown = false
                    if Core.IsValidObj(pc) then
                        pcall(function()
                            ctrlDown = (pc:IsInputKeyDown({ KeyName = FName("LeftControl") }) == true)
                                or (pc:IsInputKeyDown({ KeyName = FName("RightControl") }) == true)
                        end)
                    end
                    if ctrlDown then
                        CopySelectedMachines()
                    end
                end)
            end
        end)
    end

    if Key.ESCAPE then
        RegisterKeyBind(Key.ESCAPE, function()
            if IsMapOpen() and not WaitingForBuildMenuSelection and not Core.IsAnyTextInputFocused() then
                ExecuteInGameThread(function()
                    if InteractionMode ~= "Select" then
                        InteractionMode = "Select"
                        PendingBuildable = nil
                        UpdateStatusBanner()
                        RefreshDynamicOverlay()
                    else
                        CloseStationMap()
                    end
                end)
            end
        end)
    end
end

--------------------------------------------------------------------------------
-- Feature Lifecycle
--------------------------------------------------------------------------------

function Feature.Init()
    LastWorldAddr = GetCurrentWorldAddr()
    Core.RegisterConfigurableKeybind({
        ConfigKey   = "StationMapKey",
        DefaultKey  = "N",
        MappingName = "Eqol_StationMap",
        Label       = "Station Map",
        OnPress     = ToggleStationMap,
        CanTrigger  = function()
            return IsMapOpen() or nil
        end,
    })
    EnsureMapKeybinds()
    StationData.OnIconVisibilityChanged(function()
        if IsMapOpen() then
            pcall(RefreshStationMapCanvas, true)
        end
    end)
end

function Feature.RegisterHooks()
    Core.TryRegisterHook(
        "WindowBase_CloseWindow_StationMap",
        "/Game/Blueprints/Widgets/Basic/WBP_WindowBase.WBP_WindowBase_C:BndEvt__WBP_WindowBase_WBP_WindowHeader_K2Node_ComponentBoundEvent_1_CloseWindow__DelegateSignature",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) and Core.IsValidObj(ActiveMapWin) and w:GetAddress() == ActiveMapWin:GetAddress() then
                CloseStationMap()
            end
        end
    )
end

function Feature.OnToggle(enabled)
    if not enabled and IsMapOpen() then
        CloseStationMap()
    end
end

function Perf.SchedulePrewarm(delayMs, retriesLeft)
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or PrewarmScheduledForWorld == curWorld then return end
    PrewarmScheduledForWorld = curWorld
    local myWorld = curWorld
    local attempts = retriesLeft or 2

    local function tryPrewarm()
        if GetCurrentWorldAddr() ~= myWorld then return end
        if not Core.IsFeatureEnabled("StationMap") or IsMapOpen() then return end
        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then
            if attempts > 0 then
                attempts = attempts - 1
                ExecuteInGameThreadWithDelay(3500, tryPrewarm)
            end
            return
        end
        local inStation, walkFrame, station = StationData.IsPlayerInStation(pc)
        if not Core.IsValidObj(station) then
            if attempts > 0 then
                attempts = attempts - 1
                ExecuteInGameThreadWithDelay(4000, tryPrewarm)
            end
            return
        end
        local px, py, pz = 0.0, 0.0, 0.0
        if Core.IsValidObj(pc.Pawn) then
            local okL, loc = pcall(function() return pc.Pawn:K2_GetActorLocation() end)
            if okL and loc then px, py, pz = loc.X or 0.0, loc.Y or 0.0, loc.Z or 0.0 end
        end
        local tStart = os.clock()
        local _, _, _, _, _, _, isAsync = StationData.BuildStationFloorMapAsync(station, walkFrame, px, py, pz, function()
            Core.Log(string.format("[StationMap] Background station prewarm finished in %.0fms", (os.clock() - tStart) * 1000.0))
        end, 0.0015)
        if isAsync then
            Core.Log("[StationMap] Started quiet background station prewarm (1.5ms/frame)")
        end
    end

    ExecuteInGameThreadWithDelay(delayMs or 3500, tryPrewarm)
end

function Feature.OnClientRestart()
    ApplyInProgress = false
    CachedMouseIconTex = {}
    MouseIconSearched = {}
    local curWorld = GetCurrentWorldAddr()
    if curWorld == nil or curWorld ~= LastWorldAddr then
        LastWorldAddr = curWorld
        PrewarmScheduledForWorld = nil
        if Core.IsValidObj(ActiveMapWin) then DestroyStationMap() end
        ResetSpriteCache()
        CachedUserWidgetClasses = {}
        CachedWblCDO = nil
        PendingGhosts = {}
        Clipboard = {}
    end
    Perf.SchedulePrewarm(3500, 2)
end

function Feature.OnMapLoad()
    ApplyInProgress = false
    CachedMouseIconTex = {}
    MouseIconSearched = {}
    LastWorldAddr = GetCurrentWorldAddr()
    PrewarmScheduledForWorld = nil
    if Core.IsValidObj(ActiveMapWin) then DestroyStationMap() end
    ResetSpriteCache()
    CachedUserWidgetClasses = {}
    CachedWblCDO = nil
    PendingGhosts = {}
    Clipboard = {}
    -- Prewarm is scheduled once in OnClientRestart (avoid duplicate overlapping prewarm timers!)
end

function Feature.PruneCaches()
    for addr, btn in pairs(MapHudInjected) do
        if not Core.IsValidObj(btn) then
            MapHudInjected[addr] = nil
        end
    end
    if ActiveMapWin and not Core.IsValidObj(ActiveMapWin) then
        local wasVisible = MapWinVisible
        for _, entry in pairs(FloorIconButtons) do
            if type(entry) == "table" and entry.btn then
                Core.UnregisterWBPButtonClick(entry.btn)
            else
                Core.UnregisterWBPButtonClick(entry)
            end
        end
        UnregisterButtonList(FloorRailButtons)
        UnregisterButtonList(TrackedButtons)
        FloorIconButtons = {}
        FloorRailButtons = {}
        TrackedButtons = {}
        PlayerMarkerWidgets = {}
        ActiveMapWin = nil
        MapWinVisible = false
        MapWinInViewport = false
        MapUI = nil
        if wasVisible then
            SetStationMapCursorMode(Core.GetLocalPlayerController(), nil, false)
        end
    end
end

return Feature
