-- Eqol Station Map Progressive Mega-Tile RenderTarget2D (UCanvas) Renderer
-- Replaces thousands of UMG widgets with a small grid of GPU UTextureRenderTarget2D mega-tiles
-- (1 UImage per 24x24 cell tile = ~4-16 tiles for an entire floor), drawn progressively with a
-- strict per-frame time budget checked INSIDE each draw loop and merged straight conveyor runs.
-- 100% save-safe, zero cooked assets, automatic fallback to UMG if BeginDrawCanvasToRenderTarget is unavailable.

local Core = require("core")
local StationData = require("station_data")

local RT = {}

RT.TILE_WORLD_CM = 2400.0 -- 24x24 station cells per mega-tile (~4-16 tiles per floor)
RT.TILE_PX       = 1024   -- ~42.67 px/cell (~4 MB VRAM per active mega-tile, crisp sharpness)
RT.PX_PER_CM     = RT.TILE_PX / RT.TILE_WORLD_CM

local UV0          = { X = 0.0, Y = 0.0 }
local UV1          = { X = 1.0, Y = 1.0 }
local PIVOT_CENTER = { X = 0.5, Y = 0.5 }
local TMP_POS      = { X = 0.0, Y = 0.0 }
local TMP_SIZE     = { X = 0.0, Y = 0.0 }
local TMP_P1       = { X = 0.0, Y = 0.0 }
local TMP_P2       = { X = 0.0, Y = 0.0 }
local TMP_SCALE    = { X = 0.62, Y = 0.62 }
local TMP_SHAD_OFF = { X = 1.0, Y = 1.0 }
local COL_WHITE    = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COL_CLEAR    = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 }
local COL_SHADOW   = { R = 0.0, G = 0.0, B = 0.0, A = 0.85 }
local COL_CHIP_BG  = { R = 0.03, G = 0.04, B = 0.06, A = 0.78 }
local COL_PORT_OUT = { R = 0.0, G = 0.0, B = 0.0, A = 0.98 }
local COL_PORT_IN  = { R = 0.08, G = 0.10, B = 0.14, A = 0.90 }
local COL_CHEVRON  = { R = 1.0, G = 0.86, B = 0.14, A = 0.98 }
local COL_RAIL     = { R = 0.05, G = 0.06, B = 0.08, A = 0.98 }
local COL_DEF_BDR  = { R = 0.08, G = 0.10, B = 0.14, A = 1.0 }
local BLEND_TRANSLUCENT = 2 -- EBlendMode::BLEND_Translucent
local RTF_RGBA8 = 6         -- ETextureRenderTargetFormat::RTF_RGBA8

local BELT_BG_BY_TIER = {
    [1] = { R = 0.22,        G = 0.24,        B = 0.27,        A = 0.96 },
    [2] = { R = 0.22 * 0.78, G = 0.24 * 0.78, B = 0.27 * 0.78, A = 0.96 },
    [3] = { R = 0.22 * 0.62, G = 0.24 * 0.62, B = 0.27 * 0.62, A = 0.96 },
}

local CachedKRL = nil
local CachedWhiteTex = nil
local WhiteTexSearched = false
local CachedFont = nil
local FontSearched = false
local CachedImageCls = nil
local ItemTexCache = {} -- itemAddr -> UTexture2D or false
local ProbeDone = false
local ProbeSucceeded = false

local function GetKRL()
    if not Core.IsValidObj(CachedKRL) then
        CachedKRL = Core.GetCDO("/Script/Engine.Default__KismetRenderingLibrary")
    end
    return Core.IsValidObj(CachedKRL) and CachedKRL or nil
end

local function GetWhiteTex()
    if Core.IsValidObj(CachedWhiteTex) then return CachedWhiteTex end
    if WhiteTexSearched then return nil end
    WhiteTexSearched = true
    for _, path in ipairs({
        "/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture",
        "/Engine/ArtTools/RenderToTexture/Textures/127grey.127grey",
    }) do
        local t = Core.FindOrLoadClass(path)
        if Core.IsValidObj(t) then
            CachedWhiteTex = t
            return t
        end
    end
    return nil
end

local function GetDrawFont()
    if Core.IsValidObj(CachedFont) then return CachedFont end
    if FontSearched then return nil end
    FontSearched = true
    for _, path in ipairs({
        "/Engine/EngineFonts/Roboto.Roboto",
        "/Engine/EngineFonts/RobotoTiny.RobotoTiny",
    }) do
        local f = Core.FindOrLoadClass(path)
        if Core.IsValidObj(f) then
            CachedFont = f
            return f
        end
    end
    pcall(function()
        local f = FindFirstOf("Font")
        if Core.IsValidObj(f) then CachedFont = f end
    end)
    return Core.IsValidObj(CachedFont) and CachedFont or nil
end

local function GetItemTexture(item)
    if not Core.IsValidObj(item) then return nil end
    local addr = item:GetAddress()
    local cached = ItemTexCache[addr]
    if cached ~= nil then
        return (cached ~= false and Core.IsValidObj(cached)) and cached or nil
    end
    local tex = StationData.GetBuildableIconTexture(nil, item)
    if Core.IsValidObj(tex) then
        ItemTexCache[addr] = tex
        return tex
    end
    ItemTexCache[addr] = false
    return nil
end

-- Resolves UCanvas and FDrawToRenderTargetContext regardless of UE4SS out-param convention
local function BeginDrawRT(krl, worldCtx, rt)
    local outCanvas = {}
    local outSize = {}
    local outCtx = {}
    local ok, r1, r2, r3 = pcall(function()
        return krl:BeginDrawCanvasToRenderTarget(worldCtx, rt, outCanvas, outSize, outCtx)
    end)
    if not ok then
        return nil, nil, tostring(r1)
    end

    local canvas = nil
    if Core.IsValidObj(outCanvas) then
        canvas = outCanvas
    elseif type(outCanvas) == "table" then
        if Core.IsValidObj(outCanvas.Canvas) then canvas = outCanvas.Canvas
        elseif Core.IsValidObj(outCanvas[1]) then canvas = outCanvas[1] end
    end
    if not Core.IsValidObj(canvas) and Core.IsValidObj(r1) then
        canvas = r1
    end

    local ctx = outCtx
    if type(outCtx) == "table" and outCtx.Context ~= nil then
        ctx = outCtx.Context
    elseif r3 ~= nil and (type(outCtx) ~= "table" or next(outCtx) == nil) then
        ctx = r3
    end

    if not Core.IsValidObj(canvas) then
        return nil, nil, "BeginDrawCanvasToRenderTarget returned nil Canvas"
    end
    return canvas, ctx, nil
end

local function EndDrawRT(krl, worldCtx, ctx)
    pcall(function()
        krl:EndDrawCanvasToRenderTarget(worldCtx, ctx)
    end)
end

local function CreateRT2D(krl, worldCtx, w, h)
    -- UE 5.7 CreateRenderTarget2D takes 7 params (added bSupportUAVs=false); fallback to 6 params for older UE
    local ok, rt = pcall(function()
        return krl:CreateRenderTarget2D(worldCtx, w, h, RTF_RGBA8, COL_CLEAR, false, false)
    end)
    if ok and Core.IsValidObj(rt) then return true, rt end
    local ok6, rt6 = pcall(function()
        return krl:CreateRenderTarget2D(worldCtx, w, h, RTF_RGBA8, COL_CLEAR, false)
    end)
    if ok6 and Core.IsValidObj(rt6) then return true, rt6 end
    return false, rt or rt6
end

-- Probes once whether UE 5.7 BeginDrawCanvasToRenderTarget works cleanly in UE4SS
function RT.IsSupported(worldCtx)
    if ProbeDone then return ProbeSucceeded end
    ProbeDone = true
    ProbeSucceeded = false

    local krl = GetKRL()
    if not Core.IsValidObj(krl) or not Core.IsValidObj(worldCtx)
        or not krl.CreateRenderTarget2D or not krl.BeginDrawCanvasToRenderTarget or not krl.EndDrawCanvasToRenderTarget
    then
        Core.Log("[StationMapRT] Probe failed: KismetRenderingLibrary functions unavailable")
        return false
    end

    local okRT, testRT = CreateRT2D(krl, worldCtx, 64, 64)
    if not okRT or not Core.IsValidObj(testRT) then
        Core.Log("[StationMapRT] Probe failed: CreateRenderTarget2D err=" .. tostring(testRT))
        return false
    end

    local canvas, ctx, err = BeginDrawRT(krl, worldCtx, testRT)
    if not Core.IsValidObj(canvas) then
        Core.Log("[StationMapRT] Probe failed: " .. tostring(err))
        return false
    end

    local okDraw, drawErr = pcall(function()
        TMP_P1.X = 0.0; TMP_P1.Y = 0.0
        TMP_P2.X = 10.0; TMP_P2.Y = 10.0
        canvas:K2_DrawLine(TMP_P1, TMP_P2, 1.0, COL_WHITE)
    end)
    EndDrawRT(krl, worldCtx, ctx)

    if not okDraw then
        Core.Log("[StationMapRT] Probe failed: K2_DrawLine err=" .. tostring(drawErr))
        return false
    end

    ProbeSucceeded = true
    local wt = GetWhiteTex()
    local ft = GetDrawFont()
    Core.Log(string.format("[StationMapRT] Probe succeeded! whiteTex=%s font=%s",
        tostring(Core.IsValidObj(wt)), tostring(Core.IsValidObj(ft))))
    return true
end

function RT.ResetCaches()
    ItemTexCache = {}
    CachedImageCls = nil
end

--------------------------------------------------------------------------------
-- Canvas Drawing Primitives (Tile Pixel Space, Zero Per-Call Table Allocations)
--------------------------------------------------------------------------------

local function DrawFilledRect(canvas, whiteTex, cx, cy, w, h, col, angleDeg)
    if w <= 0.1 or h <= 0.1 then return end
    TMP_POS.X = cx - w * 0.5
    TMP_POS.Y = cy - h * 0.5
    TMP_SIZE.X = w
    TMP_SIZE.Y = h
    canvas:K2_DrawTexture(
        whiteTex,
        TMP_POS,
        TMP_SIZE,
        UV0, UV1,
        col,
        BLEND_TRANSLUCENT,
        angleDeg or 0.0,
        PIVOT_CENTER
    )
end

local function DrawSprite(canvas, tex, cx, cy, w, h, col, angleDeg)
    if not Core.IsValidObj(tex) or w <= 0.1 or h <= 0.1 then return end
    TMP_POS.X = cx - w * 0.5
    TMP_POS.Y = cy - h * 0.5
    TMP_SIZE.X = w
    TMP_SIZE.Y = h
    canvas:K2_DrawTexture(
        tex,
        TMP_POS,
        TMP_SIZE,
        UV0, UV1,
        col or COL_WHITE,
        BLEND_TRANSLUCENT,
        angleDeg or 0.0,
        PIVOT_CENTER
    )
end

local function DrawLine(canvas, x1, y1, x2, y2, thickness, col)
    TMP_P1.X = x1; TMP_P1.Y = y1
    TMP_P2.X = x2; TMP_P2.Y = y2
    canvas:K2_DrawLine(TMP_P1, TMP_P2, thickness, col)
end

local function DrawChevron(canvas, cx, cy, armLen, armThick, yawDeg, col)
    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    local tipX = cx + armLen * 0.35 * cosA
    local tipY = cy + armLen * 0.35 * sinA
    local back = armLen * 0.35
    local wing = armLen * 0.48
    local b1x = cx - back * cosA - wing * sinA
    local b1y = cy - back * sinA + wing * cosA
    local b2x = cx - back * cosA + wing * sinA
    local b2y = cy - back * sinA - wing * cosA
    DrawLine(canvas, b1x, b1y, tipX, tipY, armThick, col)
    DrawLine(canvas, b2x, b2y, tipX, tipY, armThick, col)
end

local function DrawDashedLine(canvas, x1, y1, x2, y2, col, thickness, dashLen, gapLen)
    local dx, dy = x2 - x1, y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 4.0 then return end
    local dLen = dashLen or 10.0
    local gLen = gapLen or 6.0
    local step = dLen + gLen
    local ux, uy = dx / dist, dy / dist
    local t = 4.0
    while t < dist - 4.0 do
        local segLen = math.min(dLen, (dist - 4.0) - t)
        if segLen >= 2.0 then
            DrawLine(canvas, x1 + ux * t, y1 + uy * t, x1 + ux * (t + segLen), y1 + uy * (t + segLen), thickness, col)
        end
        t = t + step
    end
end

local function DrawSplitterOrBalancerChevrons(canvas, mx, my, pxW, pxH, yawDeg, clsLow)
    local isSplitter = clsLow:find("splitter", 1, true) ~= nil
    local isBalancer = clsLow:find("balancer", 1, true) ~= nil
    if not isSplitter and not isBalancer then return end

    local rad = math.rad(yawDeg or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)
    local function toTile(lx, ly)
        return mx + (lx * cosA - ly * sinA), my + (lx * sinA + ly * cosA)
    end

    local norm = (math.floor((yawDeg or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
    local unrotW = (norm == 1 or norm == 3) and pxH or pxW
    local unrotH = (norm == 1 or norm == 3) and pxW or pxH
    local armLen = math.max(5.0, math.min(unrotW, unrotH) * 0.20)
    local armThick = math.max(1.6, math.min(2.4, armLen * 0.26))

    if isSplitter then
        local edgeX = unrotW * 0.38
        local edgeY = unrotH * 0.38
        local bx, by = toTile(-edgeX, 0.0)
        DrawChevron(canvas, bx, by, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        local fx, fy = toTile(edgeX, 0.0)
        DrawChevron(canvas, fx, fy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        local lx, ly = toTile(0.0, -edgeY)
        DrawChevron(canvas, lx, ly, armLen, armThick, (yawDeg or 0.0) - 90.0, COL_CHEVRON)
        local rx, ry = toTile(0.0, edgeY)
        DrawChevron(canvas, rx, ry, armLen, armThick, (yawDeg or 0.0) + 90.0, COL_CHEVRON)
    elseif isBalancer then
        local edgeX = unrotW * 0.36
        local laneY = unrotH * 0.25
        for _, sideSign in ipairs({ -1.0, 1.0 }) do
            local ix, iy = toTile(-edgeX, sideSign * laneY)
            DrawChevron(canvas, ix, iy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
            local ox, oy = toTile(edgeX, sideSign * laneY)
            DrawChevron(canvas, ox, oy, armLen, armThick, yawDeg or 0.0, COL_CHEVRON)
        end
    end
end

-- Merges contiguous straight same-tier, same-direction conveyor belts inside a tile into runs
-- so a 10-cell belt line draws 2 rects instead of 20.
local function BuildMergedBeltRuns(rawBelts, cellCm)
    local runs = {}
    if #rawBelts == 0 then return runs end

    local groups = {} -- key -> { belt1, belt2, ... }
    for i = 1, #rawBelts do
        local m = rawBelts[i]
        local tier = (m.sprite and m.sprite.tier) or 1
        local norm = (math.floor((m.yaw or 0.0) / 90.0 + 0.5) % 4 + 4) % 4
        local isVert = (norm == 1 or norm == 3)
        -- Only merge standard 1x1 belts
        if (m.rx or 1) == 1 and (m.ry or 1) == 1 then
            local laneKey = math.floor((isVert and m.x or m.y) / 25.0 + 0.5)
            local gKey = tier .. ":" .. norm .. ":" .. laneKey
            local g = groups[gKey]
            if not g then
                g = { tier = tier, norm = norm, isVert = isVert, yaw = m.yaw or 0.0, items = {} }
                groups[gKey] = g
            end
            g.items[#g.items + 1] = m
        else
            runs[#runs + 1] = {
                tier = tier, norm = norm, isVert = isVert, yaw = m.yaw or 0.0,
                cx = m.x, cy = m.y, spanX = (m.rx or 1) * cellCm, spanY = (m.ry or 1) * cellCm,
                cells = { { x = m.x, y = m.y } },
            }
        end
    end

    local maxGap = cellCm + 12.0
    for _, g in pairs(groups) do
        local items = g.items
        if g.isVert then
            table.sort(items, function(a, b) return a.y < b.y end)
        else
            table.sort(items, function(a, b) return a.x < b.x end)
        end

        local curStart = items[1]
        local curEnd = items[1]
        local curCells = { { x = curStart.x, y = curStart.y } }
        local function flushRun()
            if g.isVert then
                local minY = curStart.y - cellCm * 0.5
                local maxY = curEnd.y + cellCm * 0.5
                runs[#runs + 1] = {
                    tier = g.tier, norm = g.norm, isVert = true, yaw = g.yaw,
                    cx = curStart.x, cy = (minY + maxY) * 0.5,
                    spanX = cellCm, spanY = math.max(cellCm, maxY - minY),
                    cells = curCells,
                }
            else
                local minX = curStart.x - cellCm * 0.5
                local maxX = curEnd.x + cellCm * 0.5
                runs[#runs + 1] = {
                    tier = g.tier, norm = g.norm, isVert = false, yaw = g.yaw,
                    cx = (minX + maxX) * 0.5, cy = curStart.y,
                    spanX = math.max(cellCm, maxX - minX), spanY = cellCm,
                    cells = curCells,
                }
            end
        end

        for i = 2, #items do
            local m = items[i]
            local gap = g.isVert and (m.y - curEnd.y) or (m.x - curEnd.x)
            if gap <= maxGap and gap >= 1.0 then
                curEnd = m
                curCells[#curCells + 1] = { x = m.x, y = m.y }
            else
                flushRun()
                curStart = m
                curEnd = m
                curCells = { { x = m.x, y = m.y } }
            end
        end
        flushRun()
    end

    return runs
end

--------------------------------------------------------------------------------
-- Progressive Mega-Tile Floor Renderer Instance
--------------------------------------------------------------------------------

function RT.CreateFloorRenderer(opts)
    local worldCtx       = opts.worldCtx
    local outer          = opts.outer
    local parentCanvas   = opts.parentCanvas
    local basePxPerCm    = opts.basePxPerCm
    local cellCm         = opts.cellCm or 100.0
    local colors         = opts.colors
    local getTierArrow   = opts.getTierArrowColor
    local getMachineCol  = opts.getMachineColor

    local krl = GetKRL()
    if not (Core.IsValidObj(krl) and Core.IsValidObj(worldCtx) and Core.IsValidObj(outer) and Core.IsValidObj(parentCanvas)) then
        return nil
    end

    local TILE_CM      = RT.TILE_WORLD_CM
    local TILE_PX      = RT.TILE_PX
    local PX_PER_CM    = RT.PX_PER_CM
    local TILE_BASE_PX = TILE_CM * basePxPerCm
    local CELL_PX      = cellCm * PX_PER_CM
    local PORT_PX      = math.max(14.0, CELL_PX * 0.56)

    local tiles = {}        -- "tx,ty" -> tile
    local machineTiles = {} -- mAddr -> { tile1, ... }
    local dirtyList = {}
    local dirtySet = {}
    local floorVisible = true
    local destroyed = false
    local scratchRT = nil        -- shared offscreen 1024x1024 RT for flicker-free double-buffered redraws
    local scratchOwnerKey = nil  -- tile.key currently rendering into scratchRT

    -- Sub-phase timing stats for diagnostics
    local stats = {
        allocMs = 0.0,
        wallsMs = 0.0,
        beltsMs = 0.0,
        machinesMs = 0.0,
        endMs = 0.0,
        slices = 0,
        maxSliceMs = 0.0,
        rawBelts = 0,
        beltRuns = 0,
    }

    local function tileKey(tx, ty) return tx .. "," .. ty end

    local function getOrCreateTile(tx, ty)
        local key = tileKey(tx, ty)
        local t = tiles[key]
        if t then return t end

        t = {
            tx = tx,
            ty = ty,
            key = key,
            minX = tx * TILE_CM,
            maxX = (tx + 1) * TILE_CM,
            minY = ty * TILE_CM,
            maxY = (ty + 1) * TILE_CM,
            rt = nil,
            img = nil,
            visible = true,
            dirty = false,
            needsClear = true,
            hasRenderedOnce = false,
            drawState = nil, -- progressive draw cursor for multi-frame non-clearing slicing
            addMachines = {}, -- additive queue for brand-new machines on already-rendered tiles
            addLinks = {},
            addPorts = {},
            walls = {},
            machines = {},   -- mAddr -> drawEntry
            links = {},      -- pKey -> linkEntry
            ports = {},      -- mAddr -> { { x, y }, ... }
        }
        tiles[key] = t
        return t
    end

    local function enqueueTileDirty(t)
        if not t then return end
        if not t.dirty then
            t.dirty = true
            if not dirtySet[t.key] then
                dirtySet[t.key] = true
                dirtyList[#dirtyList + 1] = t
            end
        end
    end

    local function markTileDirty(t)
        if not t then return end
        t.needsClear = true
        t.drawState = nil
        t.addMachines = {}
        t.addLinks = {}
        t.addPorts = {}
        enqueueTileDirty(t)
    end

    local function ensureTileWidget(t)
        if Core.IsValidObj(t.rt) and Core.IsValidObj(t.img) then return true, 0.0 end
        local t0 = os.clock()
        local okRT, rt = CreateRT2D(krl, worldCtx, TILE_PX, TILE_PX)
        if not okRT or not Core.IsValidObj(rt) then return false, 0.0 end

        if not Core.IsValidObj(CachedImageCls) then
            CachedImageCls = Core.FindOrLoadClass("/Script/UMG.Image")
        end
        if not Core.IsValidObj(CachedImageCls) then return false, 0.0 end

        local okI, img = pcall(StaticConstructObject, CachedImageCls, outer)
        if not okI or not Core.IsValidObj(img) then return false, 0.0 end

        pcall(function()
            img:SetVisibility((floorVisible and t.visible) and 3 or 1)
            if img.SetBrushResourceObject then
                img:SetBrushResourceObject(rt)
            end
            if img.SetColorAndOpacity then
                img:SetColorAndOpacity(COL_WHITE)
            end
            local slot = parentCanvas:AddChildToCanvas(img)
            if Core.IsValidObj(slot) then
                slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
                slot:SetAlignment({ X = 0.0, Y = 0.0 })
                slot:SetPosition({ X = t.tx * TILE_BASE_PX, Y = t.ty * TILE_BASE_PX })
                slot:SetSize({ X = TILE_BASE_PX + 0.5, Y = TILE_BASE_PX + 0.5 })
                slot:SetZOrder(2)
            end
        end)

        t.rt = rt
        t.img = img
        t.needsClear = true
        local dtMs = (os.clock() - t0) * 1000.0
        stats.allocMs = stats.allocMs + dtMs
        return true, dtMs
    end

    local function forEachOverlappingTile(minX, maxX, minY, maxY, createIfMissing, fn)
        local tMinX = math.floor(minX / TILE_CM)
        local tMaxX = math.floor(maxX / TILE_CM)
        local tMinY = math.floor(minY / TILE_CM)
        local tMaxY = math.floor(maxY / TILE_CM)
        for tx = tMinX, tMaxX do
            for ty = tMinY, tMaxY do
                local t = createIfMissing and getOrCreateTile(tx, ty) or tiles[tileKey(tx, ty)]
                if t then fn(t) end
            end
        end
    end

    local function buildTileDrawState(t)
        local rawBelts = {}
        local otherMachines = {}
        for _, m in pairs(t.machines) do
            if m.cat == "Conveyor" then
                rawBelts[#rawBelts + 1] = m
            else
                otherMachines[#otherMachines + 1] = m
            end
        end
        local beltRuns = BuildMergedBeltRuns(rawBelts, cellCm)
        stats.rawBelts = stats.rawBelts + #rawBelts
        stats.beltRuns = stats.beltRuns + #beltRuns

        local linkList = {}
        for _, lk in pairs(t.links) do linkList[#linkList + 1] = lk end

        local portFlat = {}
        for _, plist in pairs(t.ports) do
            for i = 1, #plist do portFlat[#portFlat + 1] = plist[i] end
        end

        return {
            phase = 1, -- 1=wallBdr, 2=wallFill, 3=belts, 4=machines, 5=links, 6=ports, 7=done
            idx = 1,
            walls = t.walls,
            beltRuns = beltRuns,
            machines = otherMachines,
            links = linkList,
            ports = portFlat,
        }
    end

    -- Progressively draws a strict time-budgeted slice of tile `t` without clearing between slices.
    -- Returns: finished (bool), elapsedMs (number)
    local function drawTileSlice(t, budgetSec)
        if destroyed or not t then return true, 0.0 end
        local sliceStart = os.clock()
        local budgetEnd = sliceStart + (budgetSec or 0.0025)

        local okW, allocMs = ensureTileWidget(t)
        if not okW then return true, (os.clock() - sliceStart) * 1000.0 end
        -- If we just created a brand-new 1024x1024 RT and it took >1.5ms, yield until next frame
        -- so GPU texture allocation and canvas drawing never stack on the same frame.
        if allocMs > 1.5 then
            stats.slices = stats.slices + 1
            if allocMs > stats.maxSliceMs then stats.maxSliceMs = allocMs end
            return false, allocMs
        end

        if t.needsClear then
            -- If this tile is already visible on screen, double-buffer the full redraw into scratchRT
            -- and swap atomically on completion so unrelated machines never disappear or visibly rerender!
            if t.hasRenderedOnce and Core.IsValidObj(t.rt) and Core.IsValidObj(t.img) then
                if not Core.IsValidObj(scratchRT) then
                    local okS, srt = CreateRT2D(krl, worldCtx, TILE_PX, TILE_PX)
                    if okS and Core.IsValidObj(srt) then scratchRT = srt end
                end
                if Core.IsValidObj(scratchRT) and (scratchOwnerKey == nil or scratchOwnerKey == t.key) then
                    scratchOwnerKey = t.key
                    t.useScratch = true
                else
                    t.useScratch = false
                end
            else
                t.useScratch = false
            end
            local clearTarget = (t.useScratch and Core.IsValidObj(scratchRT)) and scratchRT or t.rt
            pcall(function() krl:ClearRenderTarget2D(worldCtx, clearTarget, COL_CLEAR) end)
            t.needsClear = false
            t.addMachines = {}
            t.addLinks = {}
            t.addPorts = {}
            t.drawState = buildTileDrawState(t)
        elseif not t.drawState then
            if #t.addMachines > 0 or #t.addLinks > 0 or #t.addPorts > 0 then
                -- Additive fast path: draw ONLY newly added machines/links/ports on top of the
                -- already-rendered mega-tile without clearing or re-rendering existing machines!
                local rawBelts = {}
                local otherMachines = {}
                for i = 1, #t.addMachines do
                    local m = t.addMachines[i]
                    if m.cat == "Conveyor" then
                        rawBelts[#rawBelts + 1] = m
                    else
                        otherMachines[#otherMachines + 1] = m
                    end
                end
                local beltRuns = BuildMergedBeltRuns(rawBelts, cellCm)
                t.drawState = {
                    phase = 3, -- skip walls (already rendered!)
                    idx = 1,
                    walls = {},
                    beltRuns = beltRuns,
                    machines = otherMachines,
                    links = t.addLinks,
                    ports = t.addPorts,
                }
                t.addMachines = {}
                t.addLinks = {}
                t.addPorts = {}
            else
                t.drawState = buildTileDrawState(t)
            end
        end

        local ds = t.drawState
        if ds.phase >= 7 then
            t.dirty = false
            return true, (os.clock() - sliceStart) * 1000.0
        end

        local drawTarget = (t.useScratch and Core.IsValidObj(scratchRT)) and scratchRT or t.rt
        local canvas, ctx = BeginDrawRT(krl, worldCtx, drawTarget)
        if not Core.IsValidObj(canvas) then
            return true, (os.clock() - sliceStart) * 1000.0
        end

        local whiteTex = GetWhiteTex()
        local fontObj = GetDrawFont()
        local ox, oy = t.minX, t.minY
        local wallPad = 11.0 * (PX_PER_CM / basePxPerCm)
        local innerPortSz = math.max(6.0, PORT_PX - 4.0)

        pcall(function()
            local ops = 0

            -- Phase 1: Wall borders
            if ds.phase == 1 then
                local tw0 = os.clock()
                local walls = ds.walls
                while ds.idx <= #walls do
                    local w = walls[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local wx = (w.cx - ox) * PX_PER_CM
                    local wy = (w.cy - oy) * PX_PER_CM
                    local ww = math.max(2.0, w.w * PX_PER_CM)
                    local wh = math.max(2.0, w.h * PX_PER_CM)
                    DrawFilledRect(canvas, whiteTex, wx, wy, ww + wallPad, wh + wallPad, colors.WallBorder, 0.0)
                    if ops >= 24 and os.clock() >= budgetEnd then break end
                end
                stats.wallsMs = stats.wallsMs + (os.clock() - tw0) * 1000.0
                if ds.idx > #walls then ds.phase = 2; ds.idx = 1 end
            end

            -- Phase 2: Wall fills
            if ds.phase == 2 and (ops == 0 or os.clock() < budgetEnd) then
                local tw0 = os.clock()
                local walls = ds.walls
                while ds.idx <= #walls do
                    local w = walls[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local wx = (w.cx - ox) * PX_PER_CM
                    local wy = (w.cy - oy) * PX_PER_CM
                    local ww = math.max(2.0, w.w * PX_PER_CM)
                    local wh = math.max(2.0, w.h * PX_PER_CM)
                    DrawFilledRect(canvas, whiteTex, wx, wy, ww + 1.0, wh + 1.0, colors.WallFill, 0.0)
                    if ops >= 24 and os.clock() >= budgetEnd then break end
                end
                stats.wallsMs = stats.wallsMs + (os.clock() - tw0) * 1000.0
                if ds.idx > #walls then ds.phase = 3; ds.idx = 1 end
            end

            -- Phase 3: Merged straight conveyor belt runs
            if ds.phase == 3 and (ops == 0 or os.clock() < budgetEnd) then
                local tb0 = os.clock()
                local runs = ds.beltRuns
                local armLen = math.max(6.0, CELL_PX * 0.30)
                local armThick = math.max(1.8, math.min(2.6, CELL_PX * 0.065))
                local railThick = math.max(2.0, CELL_PX * 0.12)
                while ds.idx <= #runs do
                    local r = runs[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local rx = (r.cx - ox) * PX_PER_CM
                    local ry = (r.cy - oy) * PX_PER_CM
                    local rw = math.max(6.0, r.spanX * PX_PER_CM - 2.0)
                    local rh = math.max(6.0, r.spanY * PX_PER_CM - 2.0)
                    local bgCol = BELT_BG_BY_TIER[r.tier] or BELT_BG_BY_TIER[1]
                    local arrowCol = getTierArrow(r.tier)
                    local bedW = r.isVert and math.max(4.0, rw - railThick * 2.0) or rw
                    local bedH = r.isVert and rh or math.max(4.0, rh - railThick * 2.0)
                    DrawFilledRect(canvas, whiteTex, rx, ry, rw, rh, COL_RAIL, 0.0)
                    DrawFilledRect(canvas, whiteTex, rx, ry, bedW, bedH, bgCol, 0.0)
                    local cells = r.cells
                    for ci = 1, #cells do
                        local c = cells[ci]
                        DrawChevron(canvas, (c.x - ox) * PX_PER_CM, (c.y - oy) * PX_PER_CM, armLen, armThick, r.yaw, arrowCol)
                    end
                    if ops >= 8 and os.clock() >= budgetEnd then break end
                end
                stats.beltsMs = stats.beltsMs + (os.clock() - tb0) * 1000.0
                if ds.idx > #runs then ds.phase = 4; ds.idx = 1 end
            end

            -- Phase 4: Non-conveyor machines, sprites, and item/rate chips
            if ds.phase == 4 and (ops == 0 or os.clock() < budgetEnd) then
                local tm0 = os.clock()
                local machines = ds.machines
                while ds.idx <= #machines do
                    local m = machines[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local mx = (m.x - ox) * PX_PER_CM
                    local my = (m.y - oy) * PX_PER_CM
                    local pxW = math.max(8.0, m.rx * CELL_PX)
                    local pxH = math.max(8.0, m.ry * CELL_PX)
                    local fillW = math.max(6.0, pxW - 2.0)
                    local fillH = math.max(6.0, pxH - 2.0)
                    local sp = m.sprite
                    local bgCol = (sp and sp.bgCol) or getMachineCol(m.cat)
                    local bdrCol = (sp and sp.borderCol) or COL_DEF_BDR

                    DrawFilledRect(canvas, whiteTex, mx, my, pxW, pxH, bdrCol, 0.0)
                    DrawFilledRect(canvas, whiteTex, mx, my, fillW, fillH, bgCol, 0.0)

                    local hasChips = m.overlayChips and #m.overlayChips > 0
                    if sp and Core.IsValidObj(sp.tex) then
                        local shiftUp = (hasChips and pxH >= 52.0)
                        local iconDim
                        if sp.fullTileTex then
                            iconDim = math.max(6.0, math.min(fillW, fillH))
                        else
                            local availH = shiftUp and (fillH * 0.56) or (fillH * 0.82)
                            iconDim = math.max(6.0, math.min(fillW * 0.82, availH))
                        end
                        local iconY = shiftUp and (my - fillH * 0.17) or my
                        local rot = (sp.directional and math.abs(m.yaw or 0.0) > 0.1) and m.yaw or 0.0
                        DrawSprite(canvas, sp.tex, mx, iconY, iconDim, iconDim, COL_WHITE, rot)
                    end

                    if m.clsLow and (m.clsLow:find("splitter", 1, true) or m.clsLow:find("balancer", 1, true)) then
                        DrawSplitterOrBalancerChevrons(canvas, mx, my, pxW, pxH, m.yaw or 0.0, m.clsLow)
                    elseif m.isUnderground then
                        local arrowCol = getTierArrow(sp and sp.tier or 1)
                        local armLen = math.max(6.0, math.min(pxW, pxH) * 0.34)
                        DrawChevron(canvas, mx, my, armLen, 2.4, m.yaw or 0.0, arrowCol)
                        if m.drawExitPair and m.pairX and m.pairY then
                            local omx = (m.pairX - ox) * PX_PER_CM
                            local omy = (m.pairY - oy) * PX_PER_CM
                            DrawFilledRect(canvas, whiteTex, omx, omy, pxW, pxH, bdrCol, 0.0)
                            DrawFilledRect(canvas, whiteTex, omx, omy, fillW, fillH, bgCol, 0.0)
                            if sp and Core.IsValidObj(sp.tex) then
                                local rot = (sp.directional and math.abs(m.yaw or 0.0) > 0.1) and m.yaw or 0.0
                                DrawSprite(canvas, sp.tex, omx, omy, math.min(fillW, fillH) * 0.82, math.min(fillW, fillH) * 0.82, COL_WHITE, rot)
                            end
                            DrawChevron(canvas, omx, omy, armLen, 2.4, m.yaw or 0.0, arrowCol)
                        end
                    end

                    if hasChips then
                        local chips = m.overlayChips
                        local nChips = #chips
                        local iconSz = Core.Clamp(math.min(pxW * (nChips > 1 and 0.34 or 0.48), pxH * 0.35), 14.0, 30.0)
                        local colW = m.isProducer and math.max(42.0, iconSz + 18.0) or (iconSz + 8.0)
                        local badgeW = nChips * colW + (nChips > 1 and 4.0 or 0.0)
                        local badgeH = m.isProducer and (iconSz + 16.0) or (iconSz + 6.0)
                        local badgeY = (pxH >= 52.0) and (my + pxH * 0.24) or my
                        DrawFilledRect(canvas, whiteTex, mx, badgeY, badgeW, badgeH, COL_CHIP_BG, 0.0)

                        local startX = mx - badgeW * 0.5 + colW * 0.5
                        for ci = 1, nChips do
                            local chip = chips[ci]
                            local cx = startX + (ci - 1) * (colW + 4.0)
                            local itemTex = GetItemTexture(chip.item)
                            local iconCY = (chip.rate ~= nil) and (badgeY - 6.0) or badgeY
                            if Core.IsValidObj(itemTex) then
                                DrawSprite(canvas, itemTex, cx, iconCY, iconSz, iconSz, COL_WHITE, 0.0)
                            end
                            if chip.rate ~= nil and Core.IsValidObj(fontObj) then
                                local rateStr = (chip.rate >= 10.0) and string.format("%.0f/m", chip.rate) or string.format("%.1f/m", chip.rate)
                                TMP_POS.X = cx
                                TMP_POS.Y = badgeY + badgeH * 0.5 - 7.0
                                -- bOutlined=false avoids expensive UE Canvas font outline baking spikes
                                canvas:K2_DrawText(
                                    fontObj, rateStr,
                                    TMP_POS, TMP_SCALE,
                                    COL_WHITE, 0.0, COL_SHADOW, TMP_SHAD_OFF,
                                    true, true, false, COL_CLEAR
                                )
                            end
                        end
                    end
                    if ops >= 6 and os.clock() >= budgetEnd then break end
                end
                stats.machinesMs = stats.machinesMs + (os.clock() - tm0) * 1000.0
                if ds.idx > #machines then ds.phase = 5; ds.idx = 1 end
            end

            -- Phase 5: Underground belt dashed link lines
            if ds.phase == 5 and (ops == 0 or os.clock() < budgetEnd) then
                local links = ds.links
                while ds.idx <= #links do
                    local lk = links[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local x1 = (lk.x1 - ox) * PX_PER_CM
                    local y1 = (lk.y1 - oy) * PX_PER_CM
                    local x2 = (lk.x2 - ox) * PX_PER_CM
                    local y2 = (lk.y2 - oy) * PX_PER_CM
                    DrawDashedLine(canvas, x1, y1, x2, y2, lk.lineCol, 2.6, 10.0, 6.0)
                    local linkAng = math.deg(math.atan(y2 - y1, x2 - x1))
                    DrawChevron(canvas, (x1 + x2) * 0.5, (y1 + y2) * 0.5, 11.0, 2.4, linkAng, lk.arrowCol)
                    if ops >= 10 and os.clock() >= budgetEnd then break end
                end
                if ds.idx > #links then ds.phase = 6; ds.idx = 1 end
            end

            -- Phase 6: Item port badges
            if ds.phase == 6 and (ops == 0 or os.clock() < budgetEnd) then
                local ports = ds.ports
                while ds.idx <= #ports do
                    local p = ports[ds.idx]
                    ds.idx = ds.idx + 1
                    ops = ops + 1
                    local px = (p.x - ox) * PX_PER_CM
                    local py = (p.y - oy) * PX_PER_CM
                    DrawFilledRect(canvas, whiteTex, px, py, PORT_PX, PORT_PX, COL_PORT_OUT, 0.0)
                    DrawFilledRect(canvas, whiteTex, px, py, innerPortSz, innerPortSz, COL_PORT_IN, 0.0)
                    if ops >= 20 and os.clock() >= budgetEnd then break end
                end
                if ds.idx > #ports then ds.phase = 7 end
            end
        end)

        local te0 = os.clock()
        EndDrawRT(krl, worldCtx, ctx)
        local te1 = os.clock()
        stats.endMs = stats.endMs + (te1 - te0) * 1000.0

        local elapsedMs = (te1 - sliceStart) * 1000.0
        stats.slices = stats.slices + 1
        if elapsedMs > stats.maxSliceMs then stats.maxSliceMs = elapsedMs end

        if ds.phase >= 7 then
            if t.useScratch and Core.IsValidObj(scratchRT) then
                local oldRT = t.rt
                t.rt = scratchRT
                scratchRT = oldRT
                t.useScratch = false
                if scratchOwnerKey == t.key then scratchOwnerKey = nil end
                if Core.IsValidObj(t.img) and t.img.SetBrushResourceObject then
                    pcall(function() t.img:SetBrushResourceObject(t.rt) end)
                end
            end
            t.hasRenderedOnce = true
            t.drawState = nil
            if #t.addMachines > 0 or #t.addLinks > 0 or #t.addPorts > 0 then
                -- More additive items arrived while slicing; keep tile dirty for next frame
                return false, elapsedMs
            end
            t.dirty = false
            return true, elapsedMs
        end
        return false, elapsedMs
    end

    local inst = {}

    function inst.AddPlatform()
        -- Platforms & dynamic zoom-adaptive grid lines render on MapCanvas beneath RT tiles.
    end

    function inst.AddWall(cx, cy, w, h, deferDirty)
        local wObj = { cx = cx, cy = cy, w = w, h = h }
        local hw, hh = w * 0.5 + 30.0, h * 0.5 + 30.0
        forEachOverlappingTile(cx - hw, cx + hw, cy - hh, cy + hh, true, function(t)
            t.walls[#t.walls + 1] = wObj
            if not deferDirty then
                markTileDirty(t)
            end
        end)
    end

    function inst.MarkAllTilesDirtySorted(vcx, vcy)
        local cx = vcx or 0.0
        local cy = vcy or 0.0
        local list = {}
        for _, t in pairs(tiles) do
            if t.needsClear and not t.dirty then
                local hasMach = (next(t.machines) ~= nil)
                local tcx = (t.minX + t.maxX) * 0.5 - cx
                local tcy = (t.minY + t.maxY) * 0.5 - cy
                list[#list + 1] = { t = t, hasMach = hasMach, dist = tcx * tcx + tcy * tcy }
            end
        end
        table.sort(list, function(a, b)
            if a.hasMach ~= b.hasMach then return a.hasMach end
            return a.dist < b.dist
        end)
        for i = 1, #list do
            markTileDirty(list[i].t)
        end
    end

    function inst.UpsertMachine(mAddr, drawEntry, portList, deferDirty, inPlaceAdditive)
        if not inPlaceAdditive then
            inst.RemoveMachine(mAddr, deferDirty)
        end
        local hw = drawEntry.rx * cellCm * 0.5 + 40.0
        local hh = drawEntry.ry * cellCm * 0.5 + 40.0
        local minX, maxX = drawEntry.x - hw, drawEntry.x + hw
        local minY, maxY = drawEntry.y - hh, drawEntry.y + hh
        if drawEntry.drawExitPair and drawEntry.pairX and drawEntry.pairY then
            minX = math.min(minX, drawEntry.pairX - hw)
            maxX = math.max(maxX, drawEntry.pairX + hw)
            minY = math.min(minY, drawEntry.pairY - hh)
            maxY = math.max(maxY, drawEntry.pairY + hh)
        end
        local touched = {}
        forEachOverlappingTile(minX, maxX, minY, maxY, true, function(t)
            t.machines[mAddr] = drawEntry
            if portList and #portList > 0 then
                t.ports[mAddr] = portList
            end
            touched[#touched + 1] = t
            if not deferDirty then
                if t.hasRenderedOnce and not t.needsClear and Core.IsValidObj(t.rt) then
                    t.addMachines[#t.addMachines + 1] = drawEntry
                    if portList and #portList > 0 then
                        for i = 1, #portList do t.addPorts[#t.addPorts + 1] = portList[i] end
                    end
                    enqueueTileDirty(t)
                else
                    markTileDirty(t)
                end
            end
        end)
        drawEntry._rtTiles = touched
        machineTiles[mAddr] = touched
    end

    function inst.AddUndergroundLink(pKey, linkEntry, deferDirty)
        local minX = math.min(linkEntry.x1, linkEntry.x2) - 40.0
        local maxX = math.max(linkEntry.x1, linkEntry.x2) + 40.0
        local minY = math.min(linkEntry.y1, linkEntry.y2) - 40.0
        local maxY = math.max(linkEntry.y1, linkEntry.y2) + 40.0
        local touched = {}
        forEachOverlappingTile(minX, maxX, minY, maxY, true, function(t)
            t.links[pKey] = linkEntry
            touched[#touched + 1] = t
            if not deferDirty then
                if t.hasRenderedOnce and not t.needsClear and Core.IsValidObj(t.rt) then
                    t.addLinks[#t.addLinks + 1] = linkEntry
                    enqueueTileDirty(t)
                else
                    markTileDirty(t)
                end
            end
        end)
        linkEntry._rtTiles = touched
    end

    function inst.RemoveUndergroundLink(pKey, linkEntry)
        if not linkEntry or not linkEntry._rtTiles then return end
        for i = 1, #linkEntry._rtTiles do
            local t = linkEntry._rtTiles[i]
            if t.links[pKey] then
                t.links[pKey] = nil
                markTileDirty(t)
            end
        end
    end

    function inst.RemoveMachine(mAddr, deferDirty)
        local list = machineTiles[mAddr]
        if not list then return end
        for i = 1, #list do
            local t = list[i]
            local changed = false
            if t.machines[mAddr] then t.machines[mAddr] = nil; changed = true end
            if t.ports[mAddr] then t.ports[mAddr] = nil; changed = true end
            if changed and not deferDirty then markTileDirty(t) end
        end
        machineTiles[mAddr] = nil
    end

    function inst.SetFloorVisible(vis)
        floorVisible = (vis == true)
        for _, t in pairs(tiles) do
            if Core.IsValidObj(t.img) then
                pcall(function() t.img:SetVisibility((floorVisible and t.visible) and 3 or 1) end)
            end
        end
    end

    function inst.UpdateViewport(vMinX, vMaxX, vMinY, vMaxY)
        for _, t in pairs(tiles) do
            local inView = (t.maxX >= vMinX and t.minX <= vMaxX and t.maxY >= vMinY and t.minY <= vMaxY)
            if t.visible ~= inView then
                t.visible = inView
                if Core.IsValidObj(t.img) then
                    pcall(function() t.img:SetVisibility((floorVisible and inView) and 3 or 1) end)
                end
            end
        end
    end

    -- Draws ONE time-budgeted slice of the highest-priority dirty mega-tile (visible tiles first).
    -- If a tile is currently double-buffering into scratchRT, finish it first before starting another.
    -- Returns: moreDirty (bool), elapsedMs (number)
    function inst.PumpDirtyTiles(maxSlices, budgetSec)
        if destroyed or #dirtyList == 0 then return false, 0.0 end
        local pickIdx = nil
        if scratchOwnerKey then
            for i = 1, #dirtyList do
                if dirtyList[i].key == scratchOwnerKey and dirtyList[i].dirty then
                    pickIdx = i
                    break
                end
            end
            if not pickIdx then scratchOwnerKey = nil end
        end
        if not pickIdx then
            for i = 1, #dirtyList do
                local t = dirtyList[i]
                if t.dirty and t.visible then
                    pickIdx = i
                    break
                end
            end
        end
        if not pickIdx then
            for i = 1, #dirtyList do
                if dirtyList[i].dirty then
                    pickIdx = i
                    break
                end
            end
        end
        if not pickIdx then
            dirtyList = {}
            dirtySet = {}
            return false, 0.0
        end

        local target = dirtyList[pickIdx]
        local finished, elapsedMs = drawTileSlice(target, budgetSec or 0.0025)
        if finished then
            dirtySet[target.key] = nil
            table.remove(dirtyList, pickIdx)
        end
        return #dirtyList > 0, elapsedMs
    end

    function inst.HasDirtyTiles()
        return #dirtyList > 0
    end

    function inst.GetTileCount()
        local n = 0
        for _ in pairs(tiles) do n = n + 1 end
        return n
    end

    function inst.GetStats()
        return stats
    end

    function inst.Destroy()
        destroyed = true
        for _, t in pairs(tiles) do
            if Core.IsValidObj(t.img) then
                pcall(function() t.img:RemoveFromParent() end)
            end
            t.rt = nil
            t.img = nil
            t.drawState = nil
        end
        tiles = {}
        machineTiles = {}
        dirtyList = {}
        dirtySet = {}
        scratchRT = nil
        scratchOwnerKey = nil
    end

    return inst
end

return RT
