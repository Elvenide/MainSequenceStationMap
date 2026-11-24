-- Eqol Shared Station, Floor, Machine & Icon Visibility Helpers
-- Used by station_minimap.lua, station_map.lua, and logistics.lua.

local Core = require("core")

local StationData = {}

local PATHS = {
    StationObjectClass         = "/Script/MainSequence.StationObject",
    StationPlatformObjectClass = "/Script/MainSequence.StationPlatformObject",
    AssemblerObjectClass       = "/Script/MainSequence.AssemblerObject",
    ContainerObjectClass       = "/Script/MainSequence.ContainerObject",
    ConveyorBeltObjectClass    = "/Script/MainSequence.ConveyorBeltObject",
    MachineObjectClass         = "/Script/MainSequence.MachineObject",
    ItemClass                  = "/Script/MainSequence.Item",
}

-- Shared per-machine icon visibility state (keyed by SaveableObject.ID string or address)
-- Value = true means the item icon is hidden in both Station Map and Station Minimap.
local HiddenMachineIcons = {}
local IconToggleListeners = {}

-- Cached UClasses
local CachedClasses = {}
local function GetClassCached(key, path)
    if Core.IsValidObj(CachedClasses[key]) then
        return CachedClasses[key]
    end
    local cls = Core.FindOrLoadClass(path)
    if Core.IsValidObj(cls) then
        CachedClasses[key] = cls
    end
    return cls
end

--------------------------------------------------------------------------------
-- Array / Struct Helpers
--------------------------------------------------------------------------------

local function safeGetArrayElem(arr, i)
    return arr[i]
end

function StationData.ForEachArray(arr, fn)
    if not arr then return end
    local okLen, len = pcall(function()
        return arr.GetArrayNum and arr:GetArrayNum() or #arr
    end)
    if not okLen or type(len) ~= "number" then
        okLen, len = pcall(function() return #arr end)
    end
    if okLen and type(len) == "number" then
        for i = 1, len do
            local okElem, elem = pcall(safeGetArrayElem, arr, i)
            if okElem and elem ~= nil then
                fn(i, elem)
            end
        end
        return
    end

    pcall(function()
        arr:ForEach(function(idx, elem)
            fn(idx, elem)
        end)
    end)
end

function StationData.GetObjectKey(obj)
    if not Core.IsValidObj(obj) then return nil end
    local okId, idStr = pcall(function()
        if obj.ID ~= nil then
            return tostring(obj.ID)
        end
        return nil
    end)
    if okId and idStr and idStr ~= "" and idStr ~= "nil" then
        return idStr
    end
    return tostring(obj:GetAddress())
end

--------------------------------------------------------------------------------
-- Shared Icon Visibility Toggles
--------------------------------------------------------------------------------

function StationData.IsMachineIconHidden(machine)
    local key = StationData.GetObjectKey(machine)
    if not key then return false end
    return HiddenMachineIcons[key] == true
end

function StationData.ToggleMachineIcon(machine)
    local key = StationData.GetObjectKey(machine)
    if not key then return false end
    local newHidden = not (HiddenMachineIcons[key] == true)
    if newHidden then
        HiddenMachineIcons[key] = true
    else
        HiddenMachineIcons[key] = nil
    end
    for _, cb in ipairs(IconToggleListeners) do
        pcall(cb, machine, newHidden)
    end
    return newHidden
end

function StationData.OnIconVisibilityChanged(cb)
    if type(cb) == "function" then
        table.insert(IconToggleListeners, cb)
    end
end

--------------------------------------------------------------------------------
-- Player & Station Resolution
--------------------------------------------------------------------------------

function StationData.IsPlayerInStation(pc)
    pc = pc or Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then return false, nil, nil end

    local playerObj = pc.PlayerObject
    if not Core.IsValidObj(playerObj) then return false, nil, nil end

    -- Explicitly exclude when piloting a ship
    if Core.IsValidObj(playerObj.PilotedShip) then
        return false, nil, nil
    end

    local okFrame, walkFrame = pcall(function() return playerObj:GetFrame() end)
    if not okFrame or not Core.IsValidObj(walkFrame) then
        return false, nil, nil
    end

    local stationCls = GetClassCached("StationObject", PATHS.StationObjectClass)
    local platCls = GetClassCached("StationPlatformObject", PATHS.StationPlatformObjectClass)

    local isStationFrame = false
    if Core.IsValidObj(stationCls) and walkFrame:IsA(stationCls) then
        isStationFrame = true
    elseif Core.IsValidObj(platCls) and walkFrame:IsA(platCls) then
        isStationFrame = true
    end

    if not isStationFrame then
        return false, nil, nil
    end

    local station = StationData.ResolveStationFromFrame(walkFrame, pc)
    return true, walkFrame, station
end

function StationData.ResolveStationFromFrame(frame, pc)
    if not Core.IsValidObj(frame) then return nil end

    local stationCls = GetClassCached("StationObject", PATHS.StationObjectClass)
    if Core.IsValidObj(stationCls) and frame:IsA(stationCls) then
        return frame
    end

    -- Check direct properties on StationPlatformObject
    for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation" }) do
        local ok, val = pcall(function() return frame[propName] end)
        if ok and Core.IsValidObj(val) then
            return val
        end
    end

    -- Check DMSWorldSubsystem -> GetObject(ParentID)
    local worldSub = Core.GetWorldSubsystem(pc or Core.GetLocalPlayerController(), Core.PATHS.WorldSubsystemClass)
    if Core.IsValidObj(worldSub) then
        local okPid, pid = pcall(function() return frame.ParentID end)
        if okPid and pid ~= nil then
            local okObj, obj = pcall(function() return worldSub:GetObject(pid) end)
            if okObj and Core.IsValidObj(obj) then
                if not Core.IsValidObj(stationCls) or obj:IsA(stationCls) then
                    return obj
                end
            end
        end

        -- Fallback: match against DMSWorld.Stations
        local okWorld, dmsWorld = pcall(function() return worldSub:GetDMSWorld() end)
        if okWorld and Core.IsValidObj(dmsWorld) and dmsWorld.Stations then
            local frameAddr = frame:GetAddress()
            local matchedStation = nil
            StationData.ForEachArray(dmsWorld.Stations, function(_, elem)
                if matchedStation then return end
                local st = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(st) then
                    local plats = StationData.GetStationPlatforms(st)
                    for _, p in ipairs(plats) do
                        if p:GetAddress() == frameAddr then
                            matchedStation = st
                            return
                        end
                    end
                end
            end)
            if matchedStation then
                return matchedStation
            end
        end
    end

    return nil
end

local CachedPlatforms = { key = nil, time = -999, list = {} }
local CachedMachinesByFrame = {} -- frameAddr -> { time = ..., list = {} }
local CachedPlayersSnapshot = { time = -999, list = {} }
local CachedFootprintsByClass = {} -- clsAddr -> { cellsX = n, cellsY = n }
local CachedBlockBoundsByCls = {}  -- clsAddr -> { ex = n, ey = n, ez = n, offLx = n, offLy = n }
local CachedStationWallsByKey = {} -- stationKey -> { count = n, walls = { ... } }
local CachedWallAnchors = {}       -- addr -> { obj, addr, clsPath }
local CachedWallPropNames = {}     -- "clsPath:offset" -> propName
local CachedMachineCatByCls = {}   -- clsAddr -> string
local CachedMachineDispByCls = {}  -- clsAddr -> string
local CachedHideByCls = {}         -- clsAddr -> bool
local CachedIconTexByCls = {}      -- clsAddr -> Texture2D or false
local CachedFloorMap = nil         -- { key = str, time = os.clock(), floors, unitSize, gridOriginX, gridOriginY, xform }

local StationDiagLoggedKey = nil

local function ReadBoundsStruct(boundsObj)
    if not boundsObj then return nil end
    local unwrapped = Core.UnwrapStruct(boundsObj)
    if not unwrapped then return nil end

    -- Case 1: FBox / FFixedBox with Min / Max (float or fixed-point)
    local okMinMax, minV, maxV = pcall(function() return unwrapped.Min, unwrapped.Max end)
    if okMinMax and minV and maxV then
        local x1, y1, z1 = Core.GetFPVector(minV)
        local x2, y2, z2 = Core.GetFPVector(maxV)
        local dx, dy = math.abs(x2 - x1), math.abs(y2 - y1)
        if dx >= 50.0 or dy >= 50.0 then
            return {
                cx = (x1 + x2) * 0.5,
                cy = (y1 + y2) * 0.5,
                cz = (z1 + z2) * 0.5,
                ex = dx * 0.5,
                ey = dy * 0.5,
                ez = math.abs(z2 - z1) * 0.5,
            }
        end
    end

    -- Case 2: FBoxSphereBounds with Origin / BoxExtent
    local okOrig, origV, extV = pcall(function() return unwrapped.Origin, unwrapped.BoxExtent end)
    if okOrig and origV and extV then
        local ox, oy, oz = Core.GetFPVector(origV)
        local ex, ey, ez = Core.GetFPVector(extV)
        if math.abs(ex) >= 50.0 or math.abs(ey) >= 50.0 then
            return { cx = ox, cy = oy, cz = oz, ex = math.abs(ex), ey = math.abs(ey), ez = math.max(50.0, math.abs(ez)) }
        end
    end

    -- Case 3: Center / Extent struct variants
    local okCE, cenV, cenExtV = pcall(function()
        return unwrapped.Center or unwrapped.Location, unwrapped.Extent or unwrapped.Extents or unwrapped.Size
    end)
    if okCE and cenV and cenExtV then
        local ox, oy, oz = Core.GetFPVector(cenV)
        local ex, ey, ez = Core.GetFPVector(cenExtV)
        if math.abs(ex) >= 50.0 or math.abs(ey) >= 50.0 then
            return { cx = ox, cy = oy, cz = oz, ex = math.abs(ex), ey = math.abs(ey), ez = math.max(50.0, math.abs(ez)) }
        end
    end

    return nil
end

local function InspectStructFieldNames(objOrStruct, maxFields)
    local names = {}
    if not objOrStruct then return "nil" end
    local unwrapped = Core.UnwrapStruct(objOrStruct)
    if not unwrapped then return "nil" end
    pcall(function()
        local cls = unwrapped.GetClass and unwrapped:GetClass() or (unwrapped.GetStruct and unwrapped:GetStruct())
        local target = Core.IsValidObj(cls) and cls or unwrapped
        if target and target.ForEachProperty then
            target:ForEachProperty(function(prop)
                if #names < (maxFields or 18) then
                    local pn = nil
                    pcall(function() pn = prop:GetFName():ToString() end)
                    if pn then table.insert(names, pn) end
                end
            end)
        end
    end)
    if #names == 0 then return "?" end
    return table.concat(names, ",")
end

function StationData.GetStationPlatforms(station, fallbackFrame)
    local result = {}
    local refObj = Core.IsValidObj(station) and station or fallbackFrame
    if not Core.IsValidObj(refObj) then return result end

    local now = os.clock()
    local cacheKey = tostring(refObj:GetAddress())
    if CachedPlatforms.key == cacheKey and (now - CachedPlatforms.time) < 3.0 and #CachedPlatforms.list > 0 then
        local validList = {}
        for _, p in ipairs(CachedPlatforms.list) do
            if Core.IsValidObj(p) then table.insert(validList, p) end
        end
        if #validList > 0 then return validList end
    end

    local seen = {}
    local function addPlat(p)
        if Core.IsValidObj(p) then
            local addr = p:GetAddress()
            if not seen[addr] then
                seen[addr] = true
                table.insert(result, p)
            end
        end
    end

    -- Check station arrays for module/block lists (StationBlock, Blocks, Modules, Rooms, etc.)
    if Core.IsValidObj(station) then
        for _, propName in ipairs({ "Platforms", "Modules", "StationPlatforms", "ConnectedFrames", "Children", "Blocks", "StationBlocks", "StructureBlocks", "HullBlocks", "Rooms", "Sections" }) do
            local ok, arr = pcall(function() return station[propName] end)
            if ok and arr then
                StationData.ForEachArray(arr, function(_, elem)
                    local u = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(u) then
                        addPlat(u)
                    else
                        local st = Core.UnwrapStruct(elem)
                        if st then
                            for _, fName in ipairs({ "Platform", "PlatformObject", "Block", "BlockObject", "Module", "Object", "Actor", "Frame" }) do
                                local okF, fObj = pcall(function() return st[fName] end)
                                if okF and Core.IsValidObj(fObj) then
                                    addPlat(fObj)
                                    break
                                end
                            end
                        end
                    end
                end)
            end
        end

        -- Collect station module/block subobjects from station.Subobjects (BPO_Station_02A_C, BPO_LargeConnector_C, etc.)
        pcall(function()
            if station.Subobjects then
                local machCls = GetClassCached("MachineObject", "/Script/MainSequence.MachineObject")
                local invCls = GetClassCached("Inventory", "/Script/MainSequence.Inventory")
                local pgCls = GetClassCached("PowerGrid", "/Script/MainSequence.PowerGrid")
                StationData.ForEachArray(station.Subobjects, function(_, elem)
                    local so = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(so) then
                        local skip = false
                        if Core.IsValidObj(machCls) and so:IsA(machCls) then skip = true end
                        if not skip and Core.IsValidObj(invCls) and so:IsA(invCls) then skip = true end
                        if not skip and Core.IsValidObj(pgCls) and so:IsA(pgCls) then skip = true end
                        if not skip then
                            local cn = so:GetClass():GetFName():ToString()
                            local cl = cn:lower()
                            if cn == "CharacterCollisionEnvironment" or cn == "Inventory" or cn == "PowerGrid"
                                or cl:find("turret", 1, true) or cl:find("solar", 1, true) or cl:find("connector", 1, true)
                            then
                                skip = true
                            end
                        end
                        if not skip then
                            addPlat(so)
                        end
                    end
                end)
            end
        end)

        -- Also inspect ChildActorComponents on the station actor (modules spawned as child actors)
        local stActor = StationData.GetObjectActor(station)
        if Core.IsValidObj(stActor) then
            pcall(function()
                local caCls = Core.FindOrLoadClass("/Script/Engine.ChildActorComponent")
                if Core.IsValidObj(caCls) and stActor.K2_GetComponentsByClass then
                    local rawCac = stActor:K2_GetComponentsByClass(caCls)
                    StationData.ForEachArray(rawCac, function(_, elem)
                        local cac = Core.UnwrapArrayElem(elem)
                        if Core.IsValidObj(cac) then
                            local ca = cac.ChildActor
                            if Core.IsValidObj(ca) then
                                local cn = ""
                                pcall(function() cn = ca:GetClass():GetFName():ToString():lower() end)
                                if cn:find("block", 1, true) or cn:find("module", 1, true) or cn:find("platform", 1, true) or cn:find("room", 1, true) or cn:find("station", 1, true) then
                                    addPlat(ca)
                                end
                            end
                        end
                    end)
                end
            end)
        end

        -- Also resolve station.PlatformIDs through DMSWorldSubsystem:GetObject(id)
        local okPids, pids = pcall(function() return station.PlatformIDs end)
        if okPids and pids then
            local worldSub = Core.GetWorldSubsystem(Core.GetLocalPlayerController(), Core.PATHS.WorldSubsystemClass)
            if Core.IsValidObj(worldSub) and worldSub.GetObject then
                StationData.ForEachArray(pids, function(_, elem)
                    local rawId = elem
                    pcall(function() if type(elem.get) == "function" then rawId = elem:get() end end)
                    if rawId ~= nil then
                        local okObj, obj = pcall(function() return worldSub:GetObject(rawId) end)
                        if okObj and Core.IsValidObj(obj) then
                            addPlat(obj)
                        end
                    end
                end)
            end
        end
    end

    -- Resolve target PowerGrid address for reliable station matching
    local targetGridAddr = nil
    if Core.IsValidObj(fallbackFrame) and fallbackFrame.GetStationPowerGrid then
        local okG, g = pcall(function() return fallbackFrame:GetStationPowerGrid() end)
        if okG and Core.IsValidObj(g) then targetGridAddr = g:GetAddress() end
    end
    if not targetGridAddr and Core.IsValidObj(station) and station.GetPowerGrid then
        local okG, g = pcall(function() return station:GetPowerGrid() end)
        if okG and Core.IsValidObj(g) then targetGridAddr = g:GetAddress() end
    end

    -- Fallback: only scan live StationPlatform / StationPlatformObject instances when container properties yielded nothing
    if #result == 0 then
        local okAllSt, allStations = pcall(FindAllOf, "StationObject")
        local singleStationInWorld = (okAllSt and allStations and #allStations <= 1)

        for _, searchCls in ipairs({ "StationPlatformObject", "StationPlatform" }) do
            local okAll, allPlats = pcall(FindAllOf, searchCls)
            if okAll and allPlats then
                local stAddr = Core.IsValidObj(station) and station:GetAddress() or nil
                local stId = Core.IsValidObj(station) and StationData.GetObjectKey(station) or nil
                for _, p in ipairs(allPlats) do
                    if Core.IsValidObj(p) then
                        local belongs = false
                        if targetGridAddr and p.GetStationPowerGrid then
                            local okPG, pg = pcall(function() return p:GetStationPowerGrid() end)
                            if okPG and Core.IsValidObj(pg) and pg:GetAddress() == targetGridAddr then
                                belongs = true
                            end
                        end
                        if not belongs and stAddr then
                            for _, propName in ipairs({ "Station", "ParentStation", "OwnerStation", "OwningStation", "Parent", "ParentFrame" }) do
                                local okS, sVal = pcall(function() return p[propName] end)
                                if okS and Core.IsValidObj(sVal) and sVal:GetAddress() == stAddr then
                                    belongs = true
                                    break
                                end
                            end
                            if not belongs then
                                for _, fnName in ipairs({ "GetStation", "GetFrame", "GetParentFrame" }) do
                                    if p[fnName] then
                                        local okF, fVal = pcall(function() return p[fnName](p) end)
                                        if okF and Core.IsValidObj(fVal) and fVal:GetAddress() == stAddr then
                                            belongs = true
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        if not belongs and stId then
                            local okPid, pid = pcall(function() return p.ParentID or p.StationID end)
                            if okPid and pid ~= nil and tostring(pid) == stId then
                                belongs = true
                            end
                        end
                        if not belongs and singleStationInWorld then
                            belongs = true
                        end
                        if belongs then
                            addPlat(p)
                        end
                    end
                end
            end
        end
    end

    if #result > 0 then
        CachedPlatforms = { key = cacheKey, time = now, list = result }
    end
    return result
end

--------------------------------------------------------------------------------
-- Spatial, Floor, and Bounds Helpers
--------------------------------------------------------------------------------

function StationData.GetObjectActor(obj)
    if not Core.IsValidObj(obj) then return nil end
    for _, fnName in ipairs({ "GetActor", "GetSpawnedActor" }) do
        local okFn, actor = pcall(function()
            if type(obj[fnName]) == "function" then
                return obj[fnName](obj)
            end
            return nil
        end)
        if okFn and Core.IsValidObj(actor) then
            return actor
        end
    end
    for _, propName in ipairs({ "Actor", "SpawnedActor", "MachineActor", "PlatformActor" }) do
        local okP, actor = pcall(function() return obj[propName] end)
        if okP and Core.IsValidObj(actor) then
            return actor
        end
    end
    return nil
end

function StationData.GetPlatformWorldBounds(platform, station, platIndex1)
    local cx, cy, cz = nil, nil, nil
    local yaw = 0
    local fwdX, fwdY, fwdZ = nil, nil, nil
    local ex, ey, ez = nil, nil, nil
    local hasActor = false

    local platId = nil
    pcall(function()
        if platform and platform.ID ~= nil then
            platId = tonumber(platform.ID)
        end
    end)

    local actor = StationData.GetObjectActor(platform)
    if not Core.IsValidObj(actor) and Core.IsValidObj(platform) then
        -- Check if platform itself is already an AActor
        pcall(function()
            if platform.K2_GetActorLocation then actor = platform end
        end)
    end

    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            cx, cy, cz = loc.X, loc.Y or 0, loc.Z or 0
            hasActor = true
            local okFwd, fwd = pcall(function() return actor:GetActorForwardVector() end)
            if okFwd and fwd and type(fwd.X) == "number" and type(fwd.Y) == "number" then
                fwdX, fwdY, fwdZ = fwd.X, fwd.Y, fwd.Z or 0.0
                yaw = math.deg(math.atan(fwd.Y, fwd.X))
            else
                local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
                if okRot and rot and type(rot.Yaw) == "number" then
                    yaw = rot.Yaw
                end
            end

            local conns = StationData.GetPlatformConnectors(platform)
            if #conns > 0 then
                local rad = math.rad(-yaw)
                local cosA, sinA = math.cos(rad), math.sin(rad)
                local maxLx, maxLy = 0.0, 0.0
                for _, c in ipairs(conns) do
                    local dx, dy = c.x - cx, c.y - cy
                    local lx = math.abs(dx * cosA - dy * sinA)
                    local ly = math.abs(dx * sinA + dy * cosA)
                    if lx > maxLx then maxLx = lx end
                    if ly > maxLy then maxLy = ly end
                end
                if maxLx > 150.0 then ex = maxLx end
                if maxLy > 150.0 then ey = maxLy end
            end

            -- Measure local bounds across non-hidden StaticMeshComponents anchored near this module actor (cached per class)
            if not ex or not ey then
                local blkClsAddr = nil
                pcall(function()
                    local pc = platform and platform:GetClass() or actor:GetClass()
                    if Core.IsValidObj(pc) then blkClsAddr = pc:GetAddress() end
                end)
                local cachedBlk = blkClsAddr and CachedBlockBoundsByCls[blkClsAddr] or nil
                if cachedBlk == nil then
                    cachedBlk = false
                    pcall(function()
                        local smCls = Core.FindOrLoadClass("/Script/Engine.StaticMeshComponent")
                        if Core.IsValidObj(smCls) and actor.K2_GetComponentsByClass then
                            local compsRaw = actor:K2_GetComponentsByClass(smCls)
                            local minLx, maxLx = math.huge, -math.huge
                            local minLy, maxLy = math.huge, -math.huge
                            local maxEz = 0.0
                            local anyMesh = false
                            StationData.ForEachArray(compsRaw, function(_, elem)
                                local c = Core.UnwrapArrayElem(elem)
                                if Core.IsValidObj(c) and c.bHiddenInGame ~= true and c.StaticMesh and c.StaticMesh.ExtendedBounds then
                                    local eb = c.StaticMesh.ExtendedBounds
                                    if eb.BoxExtent and eb.Origin then
                                        local rs = c.RelativeScale3D
                                        local rl = c.RelativeLocation
                                        local sx = math.abs(rs and (tonumber(rs.X) or 1.0) or 1.0)
                                        local sy = math.abs(rs and (tonumber(rs.Y) or 1.0) or 1.0)
                                        local sz = math.abs(rs and (tonumber(rs.Z) or 1.0) or 1.0)
                                        local rx = rl and (tonumber(rl.X) or 0.0) or 0.0
                                        local ry = rl and (tonumber(rl.Y) or 0.0) or 0.0
                                        local ox = (tonumber(eb.Origin.X) or 0.0) * sx + rx
                                        local oy = (tonumber(eb.Origin.Y) or 0.0) * sy + ry
                                        local bx = math.abs((tonumber(eb.BoxExtent.X) or 0.0) * sx)
                                        local by = math.abs((tonumber(eb.BoxExtent.Y) or 0.0) * sy)
                                        local bz = math.abs((tonumber(eb.BoxExtent.Z) or 0.0) * sz)
                                        if bx >= 50.0 and by >= 50.0 and bx <= 2000.0 and by <= 2000.0
                                            and math.abs(rx) <= 850.0 and math.abs(ry) <= 850.0
                                            and math.abs(ox) <= 850.0 and math.abs(oy) <= 850.0
                                        then
                                            anyMesh = true
                                            if ox - bx < minLx then minLx = ox - bx end
                                            if ox + bx > maxLx then maxLx = ox + bx end
                                            if oy - by < minLy then minLy = oy - by end
                                            if oy + by > maxLy then maxLy = oy + by end
                                            if bz > maxEz then maxEz = bz end
                                        end
                                    end
                                end
                            end)
                            if anyMesh then
                                local halfW = math.max(100.0, (maxLx - minLx) * 0.5)
                                local halfH = math.max(100.0, (maxLy - minLy) * 0.5)
                                cachedBlk = {
                                    ex = math.floor(halfW / 50.0 + 0.5) * 50.0,
                                    ey = math.floor(halfH / 50.0 + 0.5) * 50.0,
                                    ez = (maxEz > 50.0) and maxEz or nil,
                                    offLx = (minLx + maxLx) * 0.5,
                                    offLy = (minLy + maxLy) * 0.5,
                                }
                            end
                        end
                    end)
                    if blkClsAddr then
                        CachedBlockBoundsByCls[blkClsAddr] = cachedBlk
                    end
                end
                if cachedBlk then
                    ex = cachedBlk.ex
                    ey = cachedBlk.ey
                    if cachedBlk.ez then ez = cachedBlk.ez end
                    local offLx = cachedBlk.offLx or 0.0
                    local offLy = cachedBlk.offLy or 0.0
                    if math.abs(offLx) >= 25.0 or math.abs(offLy) >= 25.0 then
                        local cosY, sinY
                        if fwdX and fwdY then
                            local fLen = math.sqrt(fwdX * fwdX + fwdY * fwdY)
                            if fLen > 0.001 then
                                cosY, sinY = fwdX / fLen, fwdY / fLen
                            end
                        end
                        if not cosY then
                            local rY = math.rad(yaw or 0.0)
                            cosY, sinY = math.cos(rY), math.sin(rY)
                        end
                        cx = cx + offLx * cosY - offLy * sinY
                        cy = cy + offLx * sinY + offLy * cosY
                    end
                end
            end
        end
    end

    -- Check direct Bounds struct on platform or station.PlatformBounds[platIndex1]
    local boundsInfo = nil
    pcall(function()
        if platform and platform.Bounds then
            boundsInfo = ReadBoundsStruct(platform.Bounds)
        end
    end)
    if not boundsInfo and Core.IsValidObj(station) and type(platIndex1) == "number" then
        pcall(function()
            local pbArr = station.PlatformBounds
            if pbArr and pbArr[platIndex1] then
                boundsInfo = ReadBoundsStruct(pbArr[platIndex1])
            end
        end)
    end
    if boundsInfo then
        if not cx then cx, cy, cz = boundsInfo.cx, boundsInfo.cy, boundsInfo.cz end
        if (not ex or ex < 200.0) and boundsInfo.ex >= 200.0 then ex = boundsInfo.ex end
        if (not ey or ey < 200.0) and boundsInfo.ey >= 200.0 then ey = boundsInfo.ey end
        if not ez and boundsInfo.ez > 50.0 then ez = boundsInfo.ez end
    end

    -- Check platform.Location (fixed-point vector or 100cm grid cell vector for subobject blocks)
    if not cx and Core.IsValidObj(platform) then
        local okL, loc = pcall(function() return platform.Location end)
        if okL and loc then
            local x, y, z = Core.GetFPVector(loc)
            local xformSt = StationData.GetStationFrameTransform(station)
            if math.abs(x) <= 500.0 and math.abs(y) <= 500.0 and math.abs(z) <= 500.0 and Core.IsValidObj(station) and station:GetAddress() ~= platform:GetAddress() then
                -- Convert 100cm grid-cell FIntVector into world coordinates via station transform
                local wx, wy, wz = StationData.StationLocalToWorld(xformSt, x * 100.0, y * 100.0, z * 100.0)
                cx, cy, cz = wx, wy, wz
            else
                if Core.IsValidObj(station) and station:GetAddress() ~= platform:GetAddress() then
                    local stActor = StationData.GetObjectActor(station)
                    if Core.IsValidObj(stActor) then
                        local okSL, sl = pcall(function() return stActor:K2_GetActorLocation() end)
                        if okSL and sl and type(sl.X) == "number" then
                            if math.abs(x - sl.X) > 200000.0 or math.abs(y - sl.Y) > 200000.0 then
                                x = sl.X + x
                                y = sl.Y + y
                                z = (sl.Z or 0) + z
                            end
                        end
                    end
                end
                cx, cy, cz = x, y, z
            end
        end
    end

    -- Check platform.Dimensions / MachineDimensions / Size (e.g. grid size or cm)
    if (not ex or not ey) and Core.IsValidObj(platform) then
        pcall(function()
            for _, dimProp in ipairs({ "Dimensions", "Size", "PlatformDimensions", "GridSize", "MachineDimensions" }) do
                local d = platform[dimProp]
                if d and d.X and d.Y then
                    local dx, dy = math.abs(tonumber(d.X) or 0), math.abs(tonumber(d.Y) or 0)
                    if dx > 0 and dy > 0 then
                        if dx < 100 then dx = dx * 100.0 end
                        if dy < 100 then dy = dy * 100.0 end
                        if not ex then ex = dx * 0.5 end
                        if not ey then ey = dy * 0.5 end
                        break
                    end
                end
            end
        end)
    end

    return {
        cx = cx or 0.0,
        cy = cy or 0.0,
        cz = cz or 0.0,
        ex = ex or 600.0,
        ey = ey or 600.0,
        ez = ez or 300.0,
        yaw = yaw,
        fwdX = fwdX,
        fwdY = fwdY,
        fwdZ = fwdZ,
        id = platId,
        hasActor = hasActor,
    }
end

function StationData.GetPlatformConnectors(platform)
    local connectors = {}
    if not Core.IsValidObj(platform) then return connectors end

    local actor = StationData.GetObjectActor(platform)
    if Core.IsValidObj(actor) then
        local ox, oy, oz = 0.0, 0.0, 0.0
        local fx, fy, fz = 1.0, 0.0, 0.0
        local rx, ry, rz = 0.0, 1.0, 0.0
        local ux, uy, uz = 0.0, 0.0, 1.0
        local hasBasis = false
        pcall(function()
            local loc = actor:K2_GetActorLocation()
            if loc and type(loc.X) == "number" then
                ox, oy, oz = loc.X, loc.Y or 0.0, loc.Z or 0.0
                hasBasis = true
            end
            local fw = actor:GetActorForwardVector()
            local up = actor:GetActorUpVector()
            if fw and type(fw.X) == "number" then fx, fy, fz = fw.X, fw.Y or 0.0, fw.Z or 0.0 end
            if up and type(up.X) == "number" then ux, uy, uz = up.X, up.Y or 0.0, up.Z or 1.0 end
            -- UE left-handed +Y = +Z x +X (avoids GetActorRightVector / K2_GetComponentLocation 0x18 crashes per learning.md §6)
            local crx = uy * fz - uz * fy
            local cry = uz * fx - ux * fz
            local crz = ux * fy - uy * fx
            local rLen = math.sqrt(crx * crx + cry * cry + crz * crz)
            if rLen > 0.001 then
                rx, ry, rz = crx / rLen, cry / rLen, crz / rLen
            end
        end)

        local okComps, comps = pcall(function() return actor.ConnectorComponents end)
        if hasBasis and okComps and comps then
            StationData.ForEachArray(comps, function(_, elem)
                local comp = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(comp) then
                    local okRL, rl = pcall(function() return comp.RelativeLocation end)
                    if okRL and rl and type(rl.X) == "number" then
                        local lx = tonumber(rl.X) or 0.0
                        local ly = tonumber(rl.Y) or 0.0
                        local lz = tonumber(rl.Z) or 0.0
                        local wx = ox + lx * fx + ly * rx + lz * ux
                        local wy = oy + lx * fy + ly * ry + lz * uy
                        local occupied = false
                        pcall(function() occupied = comp.bOccupied == true end)
                        table.insert(connectors, { x = wx, y = wy, occupied = occupied })
                    end
                end
            end)
        end
    end
    return connectors
end

function StationData.GetStationFrameTransform(station)
    local act = Core.IsValidObj(station) and StationData.GetObjectActor(station) or nil
    if not Core.IsValidObj(act) and Core.IsValidObj(station) then
        pcall(function() if station.K2_GetActorLocation then act = station end end)
    end
    if not Core.IsValidObj(act) then
        return {
            ox = 0.0, oy = 0.0, oz = 0.0,
            fx = 1.0, fy = 0.0, fz = 0.0,
            rx = 0.0, ry = 1.0, rz = 0.0,
            ux = 0.0, uy = 0.0, uz = 1.0,
            hasActor = false,
            actor = nil,
        }
    end
    local ox, oy, oz = 0.0, 0.0, 0.0
    local fx, fy, fz = 1.0, 0.0, 0.0
    local rx, ry, rz = 0.0, 1.0, 0.0
    local ux, uy, uz = 0.0, 0.0, 1.0
    pcall(function()
        local loc = act:K2_GetActorLocation()
        if loc and type(loc.X) == "number" then ox, oy, oz = loc.X, loc.Y or 0.0, loc.Z or 0.0 end
        local fw = act:GetActorForwardVector()
        if fw and type(fw.X) == "number" then fx, fy, fz = fw.X, fw.Y or 0.0, fw.Z or 0.0 end
        local up = act:GetActorUpVector()
        if up and type(up.X) == "number" then ux, uy, uz = up.X, up.Y or 0.0, up.Z or 1.0 end
        -- Compute Right = Up x Forward (UE left-handed +Y = +Z x +X); avoids act:GetActorRightVector() 0x18 crash (learning.md §6)
        local crx = uy * fz - uz * fy
        local cry = uz * fx - ux * fz
        local crz = ux * fy - uy * fx
        local rLen = math.sqrt(crx * crx + cry * cry + crz * crz)
        if rLen > 0.001 then
            rx, ry, rz = crx / rLen, cry / rLen, crz / rLen
        end
    end)
    return {
        ox = ox, oy = oy, oz = oz,
        fx = fx, fy = fy, fz = fz,
        rx = rx, ry = ry, rz = rz,
        ux = ux, uy = uy, uz = uz,
        hasActor = true,
        actor = act,
    }
end

function StationData.WorldToStationLocal(xform, wx, wy, wz, fwdX, fwdY, fwdZ)
    if not xform or not xform.hasActor then
        local yaw = (fwdX and fwdY) and math.deg(math.atan(fwdY, fwdX)) or 0.0
        return wx or 0.0, wy or 0.0, wz or 0.0, yaw
    end
    local dx = (wx or 0.0) - xform.ox
    local dy = (wy or 0.0) - xform.oy
    local dz = (wz or 0.0) - xform.oz
    local lx = dx * xform.fx + dy * xform.fy + dz * xform.fz
    local ly = dx * xform.rx + dy * xform.ry + dz * xform.rz
    local lz = dx * xform.ux + dy * xform.uy + dz * xform.uz
    local yaw = 0.0
    if fwdX and fwdY then
        local fz = fwdZ or 0.0
        local lfx = fwdX * xform.fx + fwdY * xform.fy + fz * xform.fz
        local lfy = fwdX * xform.rx + fwdY * xform.ry + fz * xform.rz
        yaw = math.deg(math.atan(lfy, lfx))
    end
    return lx, ly, lz, yaw
end

function StationData.StationLocalToWorld(xform, lx, ly, lz)
    if not xform or not xform.hasActor then
        return lx or 0.0, ly or 0.0, lz or 0.0
    end
    local wx = xform.ox + lx * xform.fx + ly * xform.rx + lz * xform.ux
    local wy = xform.oy + lx * xform.fy + ly * xform.ry + lz * xform.uy
    local wz = xform.oz + lx * xform.fz + ly * xform.rz + lz * xform.uz
    return wx, wy, wz
end

function StationData.GetMachineWorldPosAndYaw(machine, fallbackBounds, xform)
    local actor = StationData.GetObjectActor(machine)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        local okRot, rot = pcall(function() return actor:K2_GetActorRotation() end)
        if okLoc and loc and type(loc.X) == "number" then
            return loc.X, loc.Y or 0, loc.Z or 0, (okRot and rot and type(rot.Yaw) == "number") and rot.Yaw or 0
        end
    end

    local okL, loc = pcall(function() return machine.Location end)
    if okL and loc then
        -- machine.Location is station-local PVector in meters (learning.md §1) -> convert to cm
        local lx, ly, lz = Core.GetFPVector(loc)
        lx, ly, lz = lx * 100.0, ly * 100.0, lz * 100.0
        if xform and xform.hasActor then
            local wx, wy, wz = StationData.StationLocalToWorld(xform, lx, ly, lz)
            return wx, wy, wz, 0
        end
        return lx, ly, lz, 0
    end

    if fallbackBounds then
        return tonumber(fallbackBounds.cx) or 0, tonumber(fallbackBounds.cy) or 0, tonumber(fallbackBounds.cz) or 0, 0
    end
    return 0, 0, 0, 0
end

local function GetMachineLocalPosAndYaw(machine, xform)
    local actor = StationData.GetObjectActor(machine)
    if Core.IsValidObj(actor) then
        local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
        if okLoc and loc and type(loc.X) == "number" then
            local fx, fy, fz = nil, nil, nil
            local okF, fwd = pcall(function() return actor:GetActorForwardVector() end)
            if okF and fwd and type(fwd.X) == "number" then
                fx, fy, fz = fwd.X, fwd.Y or 0.0, fwd.Z or 0.0
            end
            return StationData.WorldToStationLocal(xform, loc.X, loc.Y or 0.0, loc.Z or 0.0, fx, fy, fz)
        end
    end

    local okL, loc = pcall(function() return machine.Location end)
    if okL and loc then
        -- machine.Location is station-local PVector in meters (learning.md §1) -> convert to cm
        local x, y, z = Core.GetFPVector(loc)
        return x * 100.0, y * 100.0, z * 100.0, 0.0
    end
    return 0.0, 0.0, 0.0, 0.0
end

local function CollectElevatorStopLocalZs(station, allMachines, xform)
    local stopLists = {}
    local seenElev = {}
    local elevCls = GetClassCached("ElevatorObject", "/Script/MainSequence.ElevatorObject")

    local function inspectElev(el)
        if not Core.IsValidObj(el) then return end
        local addr = el:GetAddress()
        if seenElev[addr] then return end
        seenElev[addr] = true
        pcall(function()
            local stack = el.ElevatorStack
            if not stack then return end
            local list = {}
            StationData.ForEachArray(stack, function(_, elem)
                local stopObj = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(stopObj) and stopObj.bIsElevatorStop == true then
                    local _, _, lz = GetMachineLocalPosAndYaw(stopObj, xform)
                    table.insert(list, lz)
                end
            end)
            if #list >= 2 then
                table.insert(stopLists, list)
            end
        end)
    end

    if Core.IsValidObj(station) then
        pcall(function()
            if station.Elevators then
                StationData.ForEachArray(station.Elevators, function(_, elem)
                    inspectElev(Core.UnwrapArrayElem(elem))
                end)
            end
        end)
    end
    if allMachines and Core.IsValidObj(elevCls) then
        for _, m in ipairs(allMachines) do
            if Core.IsValidObj(m) and m:IsA(elevCls) then
                inspectElev(m)
            end
        end
    end
    return stopLists
end

local MachineCacheVersion = 0
local AsyncFloorBuildGen = 0

local function MergeWallList(list)
    if not list or #list <= 1 then return end
    local eps = 8.0
    local function mergeAxis(items, axis)
        if #items <= 1 then return items end
        local out = {}
        local function bandKey(v) return math.floor(v / eps + 0.5) end
        if axis == "X" then
            table.sort(items, function(a, b)
                local ay1, by1 = bandKey(a.minY), bandKey(b.minY)
                if ay1 ~= by1 then return ay1 < by1 end
                local ay2, by2 = bandKey(a.maxY), bandKey(b.maxY)
                if ay2 ~= by2 then return ay2 < by2 end
                if a.minZ ~= b.minZ then return a.minZ < b.minZ end
                return a.minX < b.minX
            end)
        else
            table.sort(items, function(a, b)
                local ax1, bx1 = bandKey(a.minX), bandKey(b.minX)
                if ax1 ~= bx1 then return ax1 < bx1 end
                local ax2, bx2 = bandKey(a.maxX), bandKey(b.maxX)
                if ax2 ~= bx2 then return ax2 < bx2 end
                if a.minZ ~= b.minZ then return a.minZ < b.minZ end
                return a.minY < b.minY
            end)
        end
        for i = 1, #items do
            local b = items[i]
            local mergedInto = nil
            for k = #out, math.max(1, #out - 8), -1 do
                local a = out[k]
                local zOverlap = (a.minZ <= b.maxZ - 40.0 and b.minZ <= a.maxZ - 40.0)
                if zOverlap then
                    if axis == "X" then
                        if math.abs(a.minY - b.minY) <= eps and math.abs(a.maxY - b.maxY) <= eps
                            and a.minX <= b.maxX + eps and b.minX <= a.maxX + eps
                        then
                            mergedInto = a
                            break
                        end
                    else
                        if math.abs(a.minX - b.minX) <= eps and math.abs(a.maxX - b.maxX) <= eps
                            and a.minY <= b.maxY + eps and b.minY <= a.maxY + eps
                        then
                            mergedInto = a
                            break
                        end
                    end
                end
            end
            if mergedInto then
                mergedInto.minX = math.min(mergedInto.minX, b.minX)
                mergedInto.maxX = math.max(mergedInto.maxX, b.maxX)
                mergedInto.minY = math.min(mergedInto.minY, b.minY)
                mergedInto.maxY = math.max(mergedInto.maxY, b.maxY)
                mergedInto.minZ = math.min(mergedInto.minZ, b.minZ)
                mergedInto.maxZ = math.max(mergedInto.maxZ, b.maxZ)
                mergedInto.cx = (mergedInto.minX + mergedInto.maxX) * 0.5
                mergedInto.cy = (mergedInto.minY + mergedInto.maxY) * 0.5
                mergedInto.ex = (mergedInto.maxX - mergedInto.minX) * 0.5
                mergedInto.ey = (mergedInto.maxY - mergedInto.minY) * 0.5
            else
                out[#out + 1] = b
            end
        end
        return out
    end
    local res = mergeAxis(mergeAxis(list, "X"), "Y")
    for i = 1, #list do list[i] = nil end
    for i = 1, #res do list[i] = res[i] end
end

function StationData.BuildStationFloorMap(station, walkFrame, playerX, playerY, playerZ)
    local cacheKey = Core.IsValidObj(station) and tostring(station:GetAddress()) or nil
    local now = os.clock()
    -- 30s TTL ensures remote multiplayer Station Designer structural edits appear promptly
    if cacheKey and CachedFloorMap and CachedFloorMap.key == cacheKey and (now - CachedFloorMap.time) < 30.0 then
        local cFloors = CachedFloorMap.floors
        local cXform = CachedFloorMap.xform
        -- Re-bin only fl.machines when InvalidateMachineCache() bumped MachineCacheVersion
        -- (avoids rebuilding static platforms and 853+ wall colliders!)
        if CachedFloorMap.machineVersion ~= MachineCacheVersion then
            local freshMachines = StationData.GetAllStationMachines(station, nil, walkFrame)
            for _, fl in ipairs(cFloors) do
                fl.machines = {}
            end
            for _, m in ipairs(freshMachines) do
                if not StationData.ShouldHideMachineOnMap(m) then
                    local lx, ly, lz, lyaw = GetMachineLocalPosAndYaw(m, cXform)
                    local skipZero = math.abs(lx) < 0.5 and math.abs(ly) < 0.5 and math.abs(lz) < 0.5 and (not Core.IsValidObj(StationData.GetObjectActor(m)))
                    if not skipZero then
                        local bestFl = nil
                        local bestDz = math.huge
                        for _, fl in ipairs(cFloors) do
                            local dz = math.abs(lz - fl.z)
                            if dz < bestDz then
                                bestDz = dz
                                bestFl = fl
                            end
                        end
                        if bestFl then
                            bestFl.machines[#bestFl.machines + 1] = {
                                machine = m,
                                x = lx,
                                y = ly,
                                z = lz,
                                yaw = lyaw,
                            }
                        end
                    end
                end
            end
            CachedFloorMap.machineVersion = MachineCacheVersion
        end
        local curIdx = 1
        if type(playerX) == "number" and type(playerY) == "number" and type(playerZ) == "number" and #cFloors > 0 then
            local _, _, plz = StationData.WorldToStationLocal(cXform, playerX, playerY, playerZ, nil, nil, nil)
            local bestD = math.huge
            for _, fl in ipairs(cFloors) do
                local d = math.abs(plz - fl.z)
                if d < bestD then bestD = d; curIdx = fl.index end
            end
        end
        return cFloors, curIdx, CachedFloorMap.unitSize, CachedFloorMap.gridOriginX, CachedFloorMap.gridOriginY, cXform
    end

    local xform = StationData.GetStationFrameTransform(station)
    local plats = StationData.GetStationPlatforms(station, walkFrame)
    if #plats == 0 and Core.IsValidObj(walkFrame) then
        plats = { walkFrame }
    end

    -- Collect all station machines first so we can orient Up axis via ElevatorStack stops
    local allMachines = StationData.GetAllStationMachines(station, plats, walkFrame)

    -- Check ElevatorStack order (stop 1 -> stop N) to ensure local +Z runs Floor 1 (bottom) -> Floor N (top)
    local elevStopLists = CollectElevatorStopLocalZs(station, allMachines, xform)
    local bestElevStops = nil
    for _, sl in ipairs(elevStopLists) do
        if not bestElevStops or #sl > #bestElevStops then bestElevStops = sl end
    end
    local stationInverted = false
    if bestElevStops and #bestElevStops >= 2 and bestElevStops[#bestElevStops] < bestElevStops[1] then
        -- Station actor is upside-down (Roll ~ 180 deg): invert Up and Right axes so Floor 1..N ascends and XY isn't mirrored
        stationInverted = true
        xform.ux, xform.uy, xform.uz = -xform.ux, -xform.uy, -xform.uz
        xform.rx, xform.ry, xform.rz = -xform.rx, -xform.ry, -xform.rz
        for _, sl in ipairs(elevStopLists) do
            for k = 1, #sl do sl[k] = -sl[k] end
        end
    end

    local zTolerance = 190.0
    local floors = {}
    local function ensureFloorForZ(lz)
        if type(lz) ~= "number" then return nil end
        for _, fl in ipairs(floors) do
            if math.abs(lz - fl.z) <= zTolerance then
                return fl
            end
        end
        local nf = {
            index = #floors + 1,
            z = lz,
            platforms = {},
            machines = {},
            walls = {},
        }
        table.insert(floors, nf)
        return nf
    end

    -- Seed floors from the union of ALL station elevator column stops (authoritative floor count!)
    local hasElevators = (#elevStopLists > 0)
    if hasElevators then
        for _, sl in ipairs(elevStopLists) do
            for _, sz in ipairs(sl) do
                ensureFloorForZ(sz)
            end
        end
    end

    -- Ingest station platforms in station-local coordinates
    local entries = {}
    local minHalf = nil
    local platDiagParts = {}
    for idx1, p in ipairs(plats) do
        local b = StationData.GetPlatformWorldBounds(p, station, idx1)
        local lcx, lcy, lcz, lyaw = StationData.WorldToStationLocal(xform, b.cx, b.cy, b.cz, b.fwdX, b.fwdY, b.fwdZ)
        local lex, ley = b.ex, b.ey
        if b.fwdX and b.fwdY then
            local normRot = (math.floor((lyaw or 0) / 90.0 + 0.5) % 4 + 4) % 4
            if normRot == 1 or normRot == 3 then
                lex, ley = b.ey, b.ex
            end
        end
        local localB = {
            cx = lcx, cy = lcy, cz = lcz,
            ex = lex, ey = ley, ez = b.ez,
            yaw = lyaw or 0.0,
            id = b.id,
            hasActor = b.hasActor,
        }
        table.insert(entries, { platform = p, bounds = localB })
        local pClsName = Core.IsValidObj(p) and (pcall(function() return p:GetClass():GetFName():ToString() end) and p:GetClass():GetFName():ToString() or "?") or "nil"
        if #platDiagParts < 12 then
            table.insert(platDiagParts, string.format("%s(c=(%.0f,%.0f,%.0f),e=(%.0f,%.0f,%.0f),y=%.0f,act=%s)",
                pClsName, lcx, lcy, lcz, lex, ley, b.ez, lyaw or 0, tostring(b.hasActor)))
        end
        local smaller = math.min(lex, ley)
        if not minHalf or smaller < minHalf then minHalf = smaller end
        if #floors == 0 or (not hasElevators and b.hasActor) then
            local fl = ensureFloorForZ(lcz)
            if fl then table.insert(fl.platforms, { platform = p, bounds = localB }) end
        elseif hasElevators and (b.hasActor or lex >= 150.0) then
            -- Assign this module to existing elevator-defined floor(s) without creating extra floors
            local spanLo = lcz - math.max(350.0, localB.ez - 150.0)
            local spanHi = lcz + math.max(350.0, localB.ez - 150.0)
            local matchedAny = false
            for _, fl in ipairs(floors) do
                if fl.z >= spanLo and fl.z <= spanHi then
                    table.insert(fl.platforms, { platform = p, bounds = localB })
                    matchedAny = true
                end
            end
            if not matchedAny then
                local bestFl, bestDz = nil, math.huge
                for _, fl in ipairs(floors) do
                    local dz = math.abs(lcz - fl.z)
                    if dz < bestDz then bestDz = dz; bestFl = fl end
                end
                if bestFl and bestDz <= math.max(600.0, localB.ez + 200.0) then
                    table.insert(bestFl.platforms, { platform = p, bounds = localB })
                end
            end
        end
    end

    -- Compute local positions of all machines (filtering out irrelevant map clutter like solar panels & turrets)
    local localMachines = {}
    for _, m in ipairs(allMachines) do
        if not StationData.ShouldHideMachineOnMap(m) then
            local lx, ly, lz, lyaw = GetMachineLocalPosAndYaw(m, xform)
            local skipZero = math.abs(lx) < 0.5 and math.abs(ly) < 0.5 and math.abs(lz) < 0.5 and (not Core.IsValidObj(StationData.GetObjectActor(m)))
            if not skipZero then
                table.insert(localMachines, { machine = m, x = lx, y = ly, z = lz, yaw = lyaw })
                if not hasElevators and #floors == 0 then
                    ensureFloorForZ(lz)
                end
            end
        end
    end

    if #floors == 0 then
        table.insert(floors, { index = 1, z = 0.0, platforms = entries, machines = {}, walls = {} })
    end

    -- Sort floors bottom-to-top (1 = bottom, N = top)
    table.sort(floors, function(a, b) return a.z < b.z end)
    for i, fl in ipairs(floors) do
        fl.index = i
    end

    -- Bin machines onto their nearest floor by local Z
    for _, lm in ipairs(localMachines) do
        local bestFl, bestDz = nil, math.huge
        for _, fl in ipairs(floors) do
            local dz = math.abs(lm.z - fl.z)
            if dz < bestDz then
                bestDz = dz
                bestFl = fl
            end
        end
        if bestFl then
            table.insert(bestFl.machines, lm)
        end
    end

    -- Ensure each floor has module outlines covering its deck bounds cleanly
    local fallbackPlat = entries[1] and entries[1].platform or walkFrame or station
    for _, fl in ipairs(floors) do
        if #fl.platforms == 0 and #fl.machines > 0 then
            local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
            for _, me in ipairs(fl.machines) do
                if me.x < minX then minX = me.x end
                if me.x > maxX then maxX = me.x end
                if me.y < minY then minY = me.y end
                if me.y > maxY then maxY = me.y end
            end
            local cx = math.floor(((minX + maxX) * 0.5) / 100.0 + 0.5) * 100.0
            local cy = math.floor(((minY + maxY) * 0.5) / 100.0 + 0.5) * 100.0
            local ex = math.max(600.0, math.ceil(((maxX - minX) * 0.5 + 300.0) / 100.0) * 100.0)
            local ey = math.max(600.0, math.ceil(((maxY - minY) * 0.5 + 300.0) / 100.0) * 100.0)
            table.insert(fl.platforms, {
                platform = fallbackPlat,
                bounds = { cx = cx, cy = cy, cz = fl.z, ex = ex, ey = ey, ez = 200.0, yaw = 0.0, synthetic = true },
            })
        elseif #fl.platforms == 0 then
            table.insert(fl.platforms, {
                platform = fallbackPlat,
                bounds = { cx = 0.0, cy = 0.0, cz = fl.z, ex = 600.0, ey = 600.0, ez = 200.0, yaw = 0.0, synthetic = true },
            })
        end
    end

    -- Extract structural module walls (including interior walls with doorways) from station CollisionEnv
    -- FCharacterCollider layout (28 bytes): +0x00 Min(3xi32), +0x0C Max(3xi32), +0x18 ColliderID(i32)
    local wallDiagTotal, wallDiagKept, wallDiagScale = 0, 0, 1.0
    local wallDiagStatus = "none"
    local wallSamples = {}
    if Core.IsValidObj(station) and #floors > 0 then
        local stWallKey = tostring(station:GetAddress())
        local cachedWalls = CachedStationWallsByKey[stWallKey]
        if cachedWalls and cachedWalls.time and (now - cachedWalls.time) >= 300.0 then
            cachedWalls = nil
            CachedStationWallsByKey[stWallKey] = nil
        end

        if not cachedWalls then
            local machineIdSet = {}
            for _, m in ipairs(allMachines) do
                if Core.IsValidObj(m) then
                    pcall(function()
                        local mid = tonumber(m.ID)
                        if mid and mid > 0 then machineIdSet[mid] = true end
                    end)
                end
            end

            local extractedWalls = {}
            pcall(function()
                local env = nil
                if station.GetCollisionEnv then env = station:GetCollisionEnv() end
                if not Core.IsValidObj(env) then env = station.CollisionEnv end
                if not Core.IsValidObj(env) or not env.Colliders then
                    wallDiagStatus = "no_env"
                    return
                end
                local cols = env.Colliders
                local num = cols.GetArrayNum and (tonumber(cols:GetArrayNum()) or 0) or 0
                wallDiagTotal = num
                if num <= 0 then
                    wallDiagStatus = "empty"
                    return
                end

                local dataAddr = cols.GetArrayDataAddress and cols:GetArrayDataAddress() or nil
                if type(dataAddr) ~= "number" or dataAddr == 0 then
                    wallDiagStatus = "no_data_addr"
                    return
                end
                if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then
                    wallDiagStatus = "no_custom_prop"
                    return
                end

                local COLLIDER_STRIDE = 28
                local maxByteAddr = dataAddr + num * COLLIDER_STRIDE
                local function getClsPath(obj)
                    local okC, cls = pcall(function() return obj:GetClass() end)
                    if not okC or not Core.IsValidObj(cls) then return nil end
                    local okF, full = pcall(function() return cls:GetFullName() end)
                    if not okF or type(full) ~= "string" then return nil end
                    return full:match("^%S+ (.+)$") or full
                end
                local DISALLOWED_WALL_ANCHOR_CLASSES = {
                    ["/Script/CoreUObject.Object"] = true,
                    ["/Script/Engine.Actor"] = true,
                    ["/Script/Engine.ActorComponent"] = true,
                }
                local function recordAnchor(obj)
                    if not Core.IsValidObj(obj) then return nil end
                    local addr = obj:GetAddress()
                    if type(addr) ~= "number" then return nil end
                    if CachedWallAnchors[addr] then return CachedWallAnchors[addr] end
                    local cp = getClsPath(obj)
                    if cp and not DISALLOWED_WALL_ANCHOR_CLASSES[cp] then
                        CachedWallAnchors[addr] = { obj = obj, addr = addr, clsPath = cp }
                        return CachedWallAnchors[addr]
                    end
                    return nil
                end
                local function fitsRange(entry)
                    if not entry or not Core.IsValidObj(entry.obj) then return false end
                    local dMin = dataAddr - entry.addr
                    local dMax = maxByteAddr - entry.addr
                    return dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF
                end

                local anchor = nil
                for _, cand in ipairs({ env, station }) do
                    local e = recordAnchor(cand)
                    if fitsRange(e) then anchor = e break end
                end
                if not anchor then
                    for _, e in pairs(CachedWallAnchors) do
                        if fitsRange(e) then anchor = e break end
                    end
                end
                if not anchor then
                    -- Never fall back to FindAllOf("Object") or FindAllOf("Actor"): enumerating all engine
                    -- UObjects freezes the game thread and risks polluting core engine UClasses with custom properties.
                    for _, searchCls in ipairs({
                        "GameInstance", "LocalPlayer", "GameViewportClient", "PlayerController",
                        "World", "Level", "DMSObject", "StationObject", "MachineObject", "UserWidget",
                    }) do
                        local okA, list = pcall(FindAllOf, searchCls)
                        if okA and list then
                            for _, obj in ipairs(list) do
                                if Core.IsValidObj(obj) then
                                    local a = obj:GetAddress()
                                    if type(a) == "number" and (dataAddr - a) >= 0 and (maxByteAddr - a) <= 0x7FFFFFFF then
                                        local e = recordAnchor(obj)
                                        if fitsRange(e) then anchor = e break end
                                    end
                                end
                            end
                        end
                        if anchor then break end
                    end
                end
                if not anchor then
                    wallDiagStatus = "no_anchor"
                    return
                end

                local function readIntAt(absAddr)
                    local off = absAddr - anchor.addr
                    local key = anchor.clsPath .. ":" .. tostring(off)
                    local pName = CachedWallPropNames[key]
                    if not pName then
                        pName = string.format("EqolW_%X_%X", anchor.addr, off)
                        local okReg = pcall(RegisterCustomProperty, {
                            Name = pName,
                            Type = PropertyTypes.IntProperty,
                            BelongsToClass = anchor.clsPath,
                            OffsetInternal = off,
                        })
                        if not okReg then return nil end
                        CachedWallPropNames[key] = pName
                    end
                    local okV, v = pcall(function() return anchor.obj[pName] end)
                    return (okV and type(v) == "number") and v or nil
                end

                -- Verify stride/offset alignment on element 1 against reflected ColliderID
                local refCid1 = nil
                pcall(function() refCid1 = tonumber(cols[1].ColliderID) end)
                local rawCid1 = readIntAt(dataAddr + 0x18)
                if refCid1 ~= nil and rawCid1 ~= refCid1 then
                    wallDiagStatus = string.format("cid_mismatch(%s!=%s)", tostring(rawCid1), tostring(refCid1))
                    return
                end

                local rawBoxes = {}
                local maxAbs = 0.0
                for i = 1, num do
                    local c = cols[i]
                    local cid = nil
                    if c then pcall(function() cid = tonumber(c.ColliderID) end) end
                    if not (cid and machineIdSet[cid]) then
                        local elemAddr = dataAddr + (i - 1) * COLLIDER_STRIDE
                        local z1 = readIntAt(elemAddr + 0x08)
                        local z2 = readIntAt(elemAddr + 0x14)
                        if z1 and z2 and z2 > z1 then
                            local x1 = readIntAt(elemAddr + 0x00)
                            local y1 = readIntAt(elemAddr + 0x04)
                            local x2 = readIntAt(elemAddr + 0x0C)
                            local y2 = readIntAt(elemAddr + 0x10)
                            if x1 and y1 and x2 and y2 and x1 < 999000000 and x2 > -999000000 and x2 > x1 and y2 > y1 then
                                local aMax = math.max(math.abs(x1), math.abs(x2), math.abs(y1), math.abs(y2))
                                if aMax > maxAbs then maxAbs = aMax end
                                table.insert(rawBoxes, { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 })
                            end
                        end
                    end
                end

                local scale = 1.0
                if maxAbs > 1000000.0 then
                    scale = 1.0 / 65536.0
                    if (maxAbs * scale) < 260.0 then
                        scale = scale * 100.0
                    end
                elseif maxAbs > 100000.0 then
                    scale = 0.1
                elseif maxAbs > 0.0 and maxAbs < 260.0 then
                    scale = 50.0
                end
                wallDiagScale = scale
                wallDiagStatus = "ok"

                for _, rb in ipairs(rawBoxes) do
                    local minX, maxX = rb.x1 * scale, rb.x2 * scale
                    local minY, maxY = rb.y1 * scale, rb.y2 * scale
                    local minZ, maxZ = rb.z1 * scale, rb.z2 * scale
                    if stationInverted then
                        minY, maxY = -maxY, -minY
                        minZ, maxZ = -maxZ, -minZ
                    end
                    local dx = maxX - minX
                    local dy = maxY - minY
                    local dz = maxZ - minZ
                    if dz >= 70.0 and math.max(dx, dy) >= 20.0 and not (dx >= 1200.0 and dy >= 1200.0) then
                        table.insert(extractedWalls, {
                            minX = minX, maxX = maxX,
                            minY = minY, maxY = maxY,
                            minZ = minZ, maxZ = maxZ,
                            cx = (minX + maxX) * 0.5,
                            cy = (minY + maxY) * 0.5,
                            ex = dx * 0.5,
                            ey = dy * 0.5,
                        })
                    end
                end
            end)

            -- Merge collinear touching/overlapping wall segments on the same Z-band in O(N log N)
            local function mergeWallList(list)
                local eps = 8.0
                local function mergeAxis(items, axis)
                    if #items <= 1 then return items end
                    local out = {}
                    local function bandKey(v) return math.floor(v / eps + 0.5) end
                    if axis == "X" then
                        table.sort(items, function(a, b)
                            local ay1, by1 = bandKey(a.minY), bandKey(b.minY)
                            if ay1 ~= by1 then return ay1 < by1 end
                            local ay2, by2 = bandKey(a.maxY), bandKey(b.maxY)
                            if ay2 ~= by2 then return ay2 < by2 end
                            if a.minZ ~= b.minZ then return a.minZ < b.minZ end
                            return a.minX < b.minX
                        end)
                    else
                        table.sort(items, function(a, b)
                            local ax1, bx1 = bandKey(a.minX), bandKey(b.minX)
                            if ax1 ~= bx1 then return ax1 < bx1 end
                            local ax2, bx2 = bandKey(a.maxX), bandKey(b.maxX)
                            if ax2 ~= bx2 then return ax2 < bx2 end
                            if a.minZ ~= b.minZ then return a.minZ < b.minZ end
                            return a.minY < b.minY
                        end)
                    end
                    -- Keep a small active tail of recent segments in the same band (handles multi-Z floors)
                    for i = 1, #items do
                        local b = items[i]
                        local mergedInto = nil
                        for k = #out, math.max(1, #out - 8), -1 do
                            local a = out[k]
                            local zOverlap = (a.minZ <= b.maxZ - 40.0 and b.minZ <= a.maxZ - 40.0)
                            if zOverlap then
                                if axis == "X" then
                                    if math.abs(a.minY - b.minY) <= eps and math.abs(a.maxY - b.maxY) <= eps
                                        and a.minX <= b.maxX + eps and b.minX <= a.maxX + eps
                                    then
                                        mergedInto = a
                                        break
                                    end
                                else
                                    if math.abs(a.minX - b.minX) <= eps and math.abs(a.maxX - b.maxX) <= eps
                                        and a.minY <= b.maxY + eps and b.minY <= a.maxY + eps
                                    then
                                        mergedInto = a
                                        break
                                    end
                                end
                            end
                        end
                        if mergedInto then
                            mergedInto.minX = math.min(mergedInto.minX, b.minX)
                            mergedInto.maxX = math.max(mergedInto.maxX, b.maxX)
                            mergedInto.minY = math.min(mergedInto.minY, b.minY)
                            mergedInto.maxY = math.max(mergedInto.maxY, b.maxY)
                            mergedInto.minZ = math.min(mergedInto.minZ, b.minZ)
                            mergedInto.maxZ = math.max(mergedInto.maxZ, b.maxZ)
                            mergedInto.cx = (mergedInto.minX + mergedInto.maxX) * 0.5
                            mergedInto.cy = (mergedInto.minY + mergedInto.maxY) * 0.5
                            mergedInto.ex = (mergedInto.maxX - mergedInto.minX) * 0.5
                            mergedInto.ey = (mergedInto.maxY - mergedInto.minY) * 0.5
                        else
                            out[#out + 1] = b
                        end
                    end
                    return out
                end
                local res = mergeAxis(mergeAxis(list, "X"), "Y")
                for i = 1, #list do list[i] = nil end
                for i = 1, #res do list[i] = res[i] end
            end
            if #extractedWalls > 1 then
                mergeWallList(extractedWalls)
            end

            cachedWalls = { total = wallDiagTotal, scale = wallDiagScale, status = wallDiagStatus, walls = extractedWalls, time = now }
            CachedStationWallsByKey[stWallKey] = cachedWalls
        else
            wallDiagTotal = cachedWalls.total or 0
            wallDiagScale = cachedWalls.scale or 1.0
            wallDiagStatus = "cached"
        end

        for _, wb in ipairs(cachedWalls.walls) do
            local matchedAny = false
            for _, fl in ipairs(floors) do
                if wb.minZ <= (fl.z + 200.0) and wb.maxZ >= (fl.z + 50.0) then
                    table.insert(fl.walls, wb)
                    matchedAny = true
                end
            end
            if matchedAny then
                wallDiagKept = wallDiagKept + 1
                if #wallSamples < 6 then
                    table.insert(wallSamples, string.format("(%.0f..%.0f,%.0f..%.0f,z=%.0f..%.0f)",
                        wb.minX, wb.maxX, wb.minY, wb.maxY, wb.minZ, wb.maxZ))
                end
            end
        end
    end

    local unitSize = (minHalf and minHalf > 100) and (minHalf * 2.0) or 1200.0
    local gridOriginX, gridOriginY = 0.0, 0.0
    local firstB = floors[1] and floors[1].platforms[1] and floors[1].platforms[1].bounds
    if firstB then
        gridOriginX = firstB.cx - firstB.ex
        gridOriginY = firstB.cy - firstB.ey
    end

    -- Select current floor using station-local player Z
    local playerLx, playerLy, playerLz = 0.0, 0.0, 0.0
    if type(playerX) == "number" and type(playerY) == "number" and type(playerZ) == "number" then
        playerLx, playerLy, playerLz = StationData.WorldToStationLocal(xform, playerX, playerY, playerZ, nil, nil, nil)
    end
    local currentFloorIndex = 1
    if #floors > 0 then
        local bestDist = math.huge
        for _, fl in ipairs(floors) do
            local d = math.abs(playerLz - fl.z)
            if d < bestDist then
                bestDist = d
                currentFloorIndex = fl.index
            end
        end
    end

    -- One-shot runtime diagnostic: dump local floors, elevator stops, and non-empty station/actor properties
    local diagKey = Core.IsValidObj(station) and tostring(station:GetAddress()) or "none"
    if StationDiagLoggedKey ~= diagKey then
        StationDiagLoggedKey = diagKey
        local elevStr = bestElevStops and (function()
            local t = {}
            for i, z in ipairs(bestElevStops) do t[i] = string.format("%.0f", z) end
            return table.concat(t, ",")
        end)() or "none"
        local flParts = {}
        for _, fl in ipairs(floors) do
            local sample = fl.machines[1] and Core.IsValidObj(fl.machines[1].machine) and fl.machines[1].machine:GetClass():GetFName():ToString() or "-"
            table.insert(flParts, string.format("#%d(lz=%.0f,m=%d,%s)", fl.index, fl.z, #fl.machines, sample))
        end
        Core.Log(string.format("[StationData] LocalMap playerL=(%.0f,%.0f,%.0f) curFl=%d elevCols=%d elevStops=[%s] floors(%d): %s",
            playerLx, playerLy, playerLz, currentFloorIndex, #elevStopLists, elevStr, #floors, table.concat(flParts, ", ")))
        Core.Log(string.format("[StationData] PlatsDiag count=%d items=[%s]", #platDiagParts, table.concat(platDiagParts, "; ")))
        Core.Log(string.format("[StationData] WallColliders total=%d status=%s walls=%d scale=%.6f fl1Walls=%d fl6Walls=%d sample=[%s]",
            wallDiagTotal, wallDiagStatus, wallDiagKept, wallDiagScale,
            floors[1] and #floors[1].walls or 0, floors[6] and #floors[6].walls or 0, table.concat(wallSamples, "; ")))

        local clsCounts = {}
        for _, m in ipairs(allMachines) do
            local cn = Core.IsValidObj(m) and m:GetClass():GetFName():ToString() or "?"
            clsCounts[cn] = (clsCounts[cn] or 0) + 1
        end
        local ccList = {}
        for k, v in pairs(clsCounts) do table.insert(ccList, { k = k, v = v }) end
        table.sort(ccList, function(a, b) return a.v > b.v end)
        local topParts = {}
        for i = 1, math.min(10, #ccList) do
            table.insert(topParts, ccList[i].k .. "=" .. ccList[i].v)
        end
        Core.Log("[StationData] TopClasses: " .. table.concat(topParts, ", "))
    end

    if cacheKey then
        CachedFloorMap = {
            key = cacheKey,
            time = os.clock(),
            machineVersion = MachineCacheVersion,
            floors = floors,
            unitSize = unitSize,
            gridOriginX = gridOriginX,
            gridOriginY = gridOriginY,
            xform = xform,
        }
    end

    return floors, currentFloorIndex, unitSize, gridOriginX, gridOriginY, xform
end

-- Non-blocking time-sliced variant of BuildStationFloorMap for Station Map open.
-- Returns platforms & floor list immediately (<10ms) and streams machine binning + wall extraction
-- across subsequent frames (3ms/frame) before invoking onComplete(floors).
function StationData.BuildStationFloorMapAsync(station, walkFrame, playerX, playerY, playerZ, onComplete, budgetSecOpt)
    AsyncFloorBuildGen = AsyncFloorBuildGen + 1
    local myGen = AsyncFloorBuildGen
    local frameBudget = budgetSecOpt or 0.0030
    local cacheKey = Core.IsValidObj(station) and tostring(station:GetAddress()) or nil
    local now = os.clock()

    if cacheKey and CachedFloorMap and CachedFloorMap.key == cacheKey and (now - CachedFloorMap.time) < 300.0 then
        local cFloors = CachedFloorMap.floors
        local cXform = CachedFloorMap.xform
        local curIdx = 1
        if type(playerX) == "number" and type(playerY) == "number" and type(playerZ) == "number" and #cFloors > 0 then
            local _, _, plz = StationData.WorldToStationLocal(cXform, playerX, playerY, playerZ, nil, nil, nil)
            local bestD = math.huge
            for _, fl in ipairs(cFloors) do
                local d = math.abs(plz - fl.z)
                if d < bestD then bestD = d; curIdx = fl.index end
            end
        end
        if CachedFloorMap.machineVersion == MachineCacheVersion then
            return cFloors, curIdx, CachedFloorMap.unitSize, CachedFloorMap.gridOriginX, CachedFloorMap.gridOriginY, cXform, false
        end

        local freshMachines = StationData.GetAllStationMachines(station, nil, walkFrame)
        for _, fl in ipairs(cFloors) do fl.machines = {} end
        local mIdx = 1
        local totalM = #freshMachines
        local function pumpRebin()
            if myGen ~= AsyncFloorBuildGen then return end
            local budgetEnd = os.clock() + 0.0030
            local step = 0
            while mIdx <= totalM and (step < 15 or os.clock() < budgetEnd) and step < 120 do
                local m = freshMachines[mIdx]
                mIdx = mIdx + 1
                step = step + 1
                if Core.IsValidObj(m) and not StationData.ShouldHideMachineOnMap(m) then
                    local lx, ly, lz, lyaw = GetMachineLocalPosAndYaw(m, cXform)
                    local skipZero = math.abs(lx) < 0.5 and math.abs(ly) < 0.5 and math.abs(lz) < 0.5 and (not Core.IsValidObj(StationData.GetObjectActor(m)))
                    if not skipZero then
                        local bestFl, bestDz = nil, math.huge
                        for _, fl in ipairs(cFloors) do
                            local dz = math.abs(lz - fl.z)
                            if dz < bestDz then bestDz = dz; bestFl = fl end
                        end
                        if bestFl then
                            bestFl.machines[#bestFl.machines + 1] = { machine = m, x = lx, y = ly, z = lz, yaw = lyaw }
                        end
                    end
                end
            end
            if mIdx <= totalM then
                ExecuteInGameThreadAfterFrames(1, pumpRebin)
            else
                if CachedFloorMap and CachedFloorMap.key == cacheKey then
                    CachedFloorMap.machineVersion = MachineCacheVersion
                end
                if type(onComplete) == "function" then onComplete(cFloors) end
            end
        end
        ExecuteInGameThreadAfterFrames(1, pumpRebin)
        return cFloors, curIdx, CachedFloorMap.unitSize, CachedFloorMap.gridOriginX, CachedFloorMap.gridOriginY, cXform, true
    end

    -- Cold build:
    -- When called for quiet background prewarm (frameBudget <= 0.0020), run even platform/elevator
    -- discovery inside the time-sliced state machine so there is ZERO synchronous post-load hitch!
    local isQuietBg = (frameBudget <= 0.0020)
    local frameStride = isQuietBg and 2 or 1
    local minMachStep = isQuietBg and 1 or 15
    local minWallStep = isQuietBg and 1 or 10

    local xform = nil
    local plats = {}
    local allMachines = {}
    local elevStopLists = {}
    local stationInverted = false
    local zTolerance = 190.0
    local floors = {}
    local entries = {}
    local minHalf = nil
    local unitSize = 1200.0
    local gridOriginX, gridOriginY = 0.0, 0.0
    local currentFloorIndex = 1

    local function ensureFloorForZ(lz)
        if type(lz) ~= "number" then return nil end
        for _, fl in ipairs(floors) do
            if math.abs(lz - fl.z) <= zTolerance then return fl end
        end
        local nf = { index = #floors + 1, z = lz, platforms = {}, machines = {}, walls = {} }
        floors[#floors + 1] = nf
        return nf
    end

    local function processSinglePlatform(idx1, p, hasElevators)
        local b = StationData.GetPlatformWorldBounds(p, station, idx1)
        local lcx, lcy, lcz, lyaw = StationData.WorldToStationLocal(xform, b.cx, b.cy, b.cz, b.fwdX, b.fwdY, b.fwdZ)
        local lex, ley = b.ex, b.ey
        if b.fwdX and b.fwdY then
            local normRot = (math.floor((lyaw or 0) / 90.0 + 0.5) % 4 + 4) % 4
            if normRot == 1 or normRot == 3 then lex, ley = b.ey, b.ex end
        end
        local localB = { cx = lcx, cy = lcy, cz = lcz, ex = lex, ey = ley, ez = b.ez, yaw = lyaw or 0.0, id = b.id, hasActor = b.hasActor }
        entries[#entries + 1] = { platform = p, bounds = localB }
        local smaller = math.min(lex, ley)
        if not minHalf or smaller < minHalf then minHalf = smaller end
        if #floors == 0 or (not hasElevators and b.hasActor) then
            local fl = ensureFloorForZ(lcz)
            if fl then fl.platforms[#fl.platforms + 1] = { platform = p, bounds = localB } end
        elseif hasElevators and (b.hasActor or lex >= 150.0) then
            local spanLo = lcz - math.max(350.0, localB.ez - 150.0)
            local spanHi = lcz + math.max(350.0, localB.ez - 150.0)
            local matchedAny = false
            for _, fl in ipairs(floors) do
                if fl.z >= spanLo and fl.z <= spanHi then
                    fl.platforms[#fl.platforms + 1] = { platform = p, bounds = localB }
                    matchedAny = true
                end
            end
            if not matchedAny then
                local bestFl, bestDz = nil, math.huge
                for _, fl in ipairs(floors) do
                    local dz = math.abs(lcz - fl.z)
                    if dz < bestDz then bestDz = dz; bestFl = fl end
                end
                if bestFl and bestDz <= math.max(600.0, localB.ez + 200.0) then
                    bestFl.platforms[#bestFl.platforms + 1] = { platform = p, bounds = localB }
                end
            end
        end
    end

    local function finalizeFloorsAndOrigin()
        if #floors == 0 then
            floors[1] = { index = 1, z = 0.0, platforms = entries, machines = {}, walls = {} }
        end
        table.sort(floors, function(a, b) return a.z < b.z end)
        for i, fl in ipairs(floors) do fl.index = i end

        local fallbackPlat = entries[1] and entries[1].platform or walkFrame or station
        for _, fl in ipairs(floors) do
            if #fl.platforms == 0 then
                fl.platforms[1] = {
                    platform = fallbackPlat,
                    bounds = { cx = 0.0, cy = 0.0, cz = fl.z, ex = 600.0, ey = 600.0, ez = 200.0, yaw = 0.0, synthetic = true },
                }
            end
        end

        unitSize = (minHalf and minHalf > 100) and (minHalf * 2.0) or 1200.0
        gridOriginX, gridOriginY = 0.0, 0.0
        local firstB = floors[1] and floors[1].platforms[1] and floors[1].platforms[1].bounds
        if firstB then
            gridOriginX = firstB.cx - firstB.ex
            gridOriginY = firstB.cy - firstB.ey
        end

        currentFloorIndex = 1
        if type(playerX) == "number" and type(playerY) == "number" and type(playerZ) == "number" and #floors > 0 then
            local _, _, playerLz = StationData.WorldToStationLocal(xform, playerX, playerY, playerZ, nil, nil, nil)
            local bestDist = math.huge
            for _, fl in ipairs(floors) do
                local d = math.abs(playerLz - fl.z)
                if d < bestDist then bestDist = d; currentFloorIndex = fl.index end
            end
        end
    end

    local mIdx = 1
    local totalM = 0
    local machineIdSet = {}
    local phase = isQuietBg and "bg_plats" or "machines"
    local wallState = nil
    local bgElevIdx = 1
    local bgElevCls = nil
    local bgSeenElev = {}
    local bgPlatIdx = 1
    local bgHasElevators = false

    if not isQuietBg then
        xform = StationData.GetStationFrameTransform(station)
        plats = StationData.GetStationPlatforms(station, walkFrame)
        if #plats == 0 and Core.IsValidObj(walkFrame) then
            plats = { walkFrame }
        end
        allMachines = StationData.GetAllStationMachines(station, plats, walkFrame)
        totalM = #allMachines
        elevStopLists = CollectElevatorStopLocalZs(station, allMachines, xform)
        local bestElevStops = nil
        for _, sl in ipairs(elevStopLists) do
            if not bestElevStops or #sl > #bestElevStops then bestElevStops = sl end
        end
        if bestElevStops and #bestElevStops >= 2 and bestElevStops[#bestElevStops] < bestElevStops[1] then
            stationInverted = true
            xform.ux, xform.uy, xform.uz = -xform.ux, -xform.uy, -xform.uz
            xform.rx, xform.ry, xform.rz = -xform.rx, -xform.ry, -xform.rz
            for _, sl in ipairs(elevStopLists) do
                for k = 1, #sl do sl[k] = -sl[k] end
            end
        end
        local hasElevators = (#elevStopLists > 0)
        if hasElevators then
            for _, sl in ipairs(elevStopLists) do
                for _, sz in ipairs(sl) do ensureFloorForZ(sz) end
            end
        end
        for idx1, p in ipairs(plats) do
            processSinglePlatform(idx1, p, hasElevators)
        end
        finalizeFloorsAndOrigin()
    end

    local function initWallExtraction()
        if not Core.IsValidObj(station) or #floors == 0 then return nil end
        local stWallKey = tostring(station:GetAddress())
        local cachedWalls = CachedStationWallsByKey[stWallKey]
        if cachedWalls and cachedWalls.time and (os.clock() - cachedWalls.time) < 300.0 then
            for _, wb in ipairs(cachedWalls.walls) do
                for _, fl in ipairs(floors) do
                    if wb.minZ <= (fl.z + 200.0) and wb.maxZ >= (fl.z + 50.0) then
                        fl.walls[#fl.walls + 1] = wb
                    end
                end
            end
            return nil
        end

        local env = nil
        pcall(function()
            if station.GetCollisionEnv then env = station:GetCollisionEnv() end
            if not Core.IsValidObj(env) then env = station.CollisionEnv end
        end)
        if not Core.IsValidObj(env) or not env.Colliders then return nil end
        local cols = env.Colliders
        local num = cols.GetArrayNum and (tonumber(cols:GetArrayNum()) or 0) or 0
        if num <= 0 then return nil end
        local dataAddr = cols.GetArrayDataAddress and cols:GetArrayDataAddress() or nil
        if type(dataAddr) ~= "number" or dataAddr == 0 then return nil end
        if type(RegisterCustomProperty) ~= "function" or type(PropertyTypes) ~= "table" then return nil end

        local COLLIDER_STRIDE = 28
        local maxByteAddr = dataAddr + num * COLLIDER_STRIDE
        local DISALLOWED = {
            ["/Script/CoreUObject.Object"] = true,
            ["/Script/Engine.Actor"] = true,
            ["/Script/Engine.ActorComponent"] = true,
        }
        local function recordAnchor(obj)
            if not Core.IsValidObj(obj) then return nil end
            local addr = obj:GetAddress()
            if type(addr) ~= "number" then return nil end
            if CachedWallAnchors[addr] then return CachedWallAnchors[addr] end
            local okC, cls = pcall(function() return obj:GetClass() end)
            if not okC or not Core.IsValidObj(cls) then return nil end
            local okF, full = pcall(function() return cls:GetFullName() end)
            if not okF or type(full) ~= "string" then return nil end
            local cp = full:match("^%S+ (.+)$") or full
            if cp and not DISALLOWED[cp] then
                CachedWallAnchors[addr] = { obj = obj, addr = addr, clsPath = cp }
                return CachedWallAnchors[addr]
            end
            return nil
        end
        local function fitsRange(e)
            if not e or not Core.IsValidObj(e.obj) then return false end
            local dMin = dataAddr - e.addr
            local dMax = maxByteAddr - e.addr
            return dMin >= 0 and dMax >= 0 and dMax <= 0x7FFFFFFF
        end
        local anchor = nil
        for _, cand in ipairs({ env, station }) do
            local e = recordAnchor(cand)
            if fitsRange(e) then anchor = e break end
        end
        if not anchor then
            for _, e in pairs(CachedWallAnchors) do
                if fitsRange(e) then anchor = e break end
            end
        end
        if not anchor then
            for _, searchCls in ipairs({
                "GameInstance", "LocalPlayer", "GameViewportClient", "PlayerController",
                "World", "Level", "DMSObject", "StationObject", "MachineObject", "UserWidget",
            }) do
                local okA, list = pcall(FindAllOf, searchCls)
                if okA and list then
                    for _, obj in ipairs(list) do
                        if Core.IsValidObj(obj) then
                            local a = obj:GetAddress()
                            if type(a) == "number" and (dataAddr - a) >= 0 and (maxByteAddr - a) <= 0x7FFFFFFF then
                                local e = recordAnchor(obj)
                                if fitsRange(e) then anchor = e break end
                            end
                        end
                    end
                end
                if anchor then break end
            end
        end
        if not anchor then return nil end

        local function readIntAt(absAddr)
            local off = absAddr - anchor.addr
            local key = anchor.clsPath .. ":" .. tostring(off)
            local pName = CachedWallPropNames[key]
            if not pName then
                pName = string.format("EqolW_%X_%X", anchor.addr, off)
                local okReg = pcall(RegisterCustomProperty, {
                    Name = pName,
                    Type = PropertyTypes.IntProperty,
                    BelongsToClass = anchor.clsPath,
                    OffsetInternal = off,
                })
                if not okReg then return nil end
                CachedWallPropNames[key] = pName
            end
            local okV, v = pcall(function() return anchor.obj[pName] end)
            return (okV and type(v) == "number") and v or nil
        end

        local refCid1 = nil
        pcall(function() refCid1 = tonumber(cols[1].ColliderID) end)
        local rawCid1 = readIntAt(dataAddr + 0x18)
        if refCid1 ~= nil and rawCid1 ~= refCid1 then return nil end

        return {
            stWallKey = stWallKey,
            cols = cols,
            num = num,
            idx = 1,
            dataAddr = dataAddr,
            stride = COLLIDER_STRIDE,
            readIntAt = readIntAt,
            rawBoxes = {},
            maxAbs = 0.0,
        }
    end

    local function finishAsyncBuild()
        if cacheKey then
            CachedFloorMap = {
                key = cacheKey,
                time = os.clock(),
                machineVersion = MachineCacheVersion,
                floors = floors,
                unitSize = unitSize,
                gridOriginX = gridOriginX,
                gridOriginY = gridOriginY,
                xform = xform,
            }
        end
        if type(onComplete) == "function" then
            onComplete(floors, currentFloorIndex, unitSize, gridOriginX, gridOriginY, xform)
        end
    end

    local function pumpAsyncBuild()
        if myGen ~= AsyncFloorBuildGen then return end
        local tTick0 = os.clock()
        local phaseAtStart = phase
        local budgetEnd = tTick0 + frameBudget
        local function logSlowTick()
            local ms = (os.clock() - tTick0) * 1000.0
            if ms > 15.0 then
                Core.Log(string.format("[Perf] StationData.pumpAsyncBuild phase=%s took %.1fms", tostring(phaseAtStart), ms))
            end
        end

        if phase == "bg_plats" then
            if not Core.IsValidObj(station) then return end
            xform = StationData.GetStationFrameTransform(station)
            plats = StationData.GetStationPlatforms(station, walkFrame)
            if #plats == 0 and Core.IsValidObj(walkFrame) then
                plats = { walkFrame }
            end
            phase = "bg_machines_list"
            logSlowTick()
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "bg_machines_list" then
            if not Core.IsValidObj(station) then return end
            allMachines = StationData.GetAllStationMachines(station, plats, walkFrame)
            totalM = #allMachines
            bgElevCls = GetClassCached("ElevatorObject", "/Script/MainSequence.ElevatorObject")
            if Core.IsValidObj(station) then
                pcall(function()
                    if station.Elevators then
                        StationData.ForEachArray(station.Elevators, function(_, elem)
                            local el = Core.UnwrapArrayElem(elem)
                            if Core.IsValidObj(el) then
                                local addr = el:GetAddress()
                                if not bgSeenElev[addr] then
                                    bgSeenElev[addr] = true
                                    local stack = el.ElevatorStack
                                    if stack then
                                        local list = {}
                                        StationData.ForEachArray(stack, function(_, se)
                                            local stopObj = Core.UnwrapArrayElem(se)
                                            if Core.IsValidObj(stopObj) and stopObj.bIsElevatorStop == true then
                                                local _, _, lz = GetMachineLocalPosAndYaw(stopObj, xform)
                                                list[#list + 1] = lz
                                            end
                                        end)
                                        if #list >= 2 then elevStopLists[#elevStopLists + 1] = list end
                                    end
                                end
                            end
                        end)
                    end
                end)
            end
            bgElevIdx = 1
            phase = "bg_elevators"
            logSlowTick()
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "bg_elevators" then
            local step = 0
            while bgElevIdx <= totalM and Core.IsValidObj(bgElevCls) and (step < 1 or os.clock() < budgetEnd) and step < 120 do
                local m = allMachines[bgElevIdx]
                bgElevIdx = bgElevIdx + 1
                step = step + 1
                if Core.IsValidObj(m) and m:IsA(bgElevCls) then
                    local addr = m:GetAddress()
                    if not bgSeenElev[addr] then
                        bgSeenElev[addr] = true
                        pcall(function()
                            local stack = m.ElevatorStack
                            if stack then
                                local list = {}
                                StationData.ForEachArray(stack, function(_, se)
                                    local stopObj = Core.UnwrapArrayElem(se)
                                    if Core.IsValidObj(stopObj) and stopObj.bIsElevatorStop == true then
                                        local _, _, lz = GetMachineLocalPosAndYaw(stopObj, xform)
                                        list[#list + 1] = lz
                                    end
                                end)
                                if #list >= 2 then elevStopLists[#elevStopLists + 1] = list end
                            end
                        end)
                    end
                end
            end
            if bgElevIdx <= totalM and Core.IsValidObj(bgElevCls) then
                ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
                return
            end
            local bestElevStops = nil
            for _, sl in ipairs(elevStopLists) do
                if not bestElevStops or #sl > #bestElevStops then bestElevStops = sl end
            end
            if bestElevStops and #bestElevStops >= 2 and bestElevStops[#bestElevStops] < bestElevStops[1] then
                stationInverted = true
                xform.ux, xform.uy, xform.uz = -xform.ux, -xform.uy, -xform.uz
                xform.rx, xform.ry, xform.rz = -xform.rx, -xform.ry, -xform.rz
                for _, sl in ipairs(elevStopLists) do
                    for k = 1, #sl do sl[k] = -sl[k] end
                end
            end
            bgHasElevators = (#elevStopLists > 0)
            if bgHasElevators then
                for _, sl in ipairs(elevStopLists) do
                    for _, sz in ipairs(sl) do ensureFloorForZ(sz) end
                end
            end
            bgPlatIdx = 1
            phase = "bg_plat_bounds"
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "bg_plat_bounds" then
            local step = 0
            local totalP = #plats
            while bgPlatIdx <= totalP and (step < 1 or os.clock() < budgetEnd) and step < 8 do
                local p = plats[bgPlatIdx]
                processSinglePlatform(bgPlatIdx, p, bgHasElevators)
                bgPlatIdx = bgPlatIdx + 1
                step = step + 1
            end
            if bgPlatIdx <= totalP then
                ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
                return
            end
            finalizeFloorsAndOrigin()
            phase = "machines"
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "machines" then
            local step = 0
            while mIdx <= totalM and (step < minMachStep or os.clock() < budgetEnd) and step < 120 do
                local m = allMachines[mIdx]
                mIdx = mIdx + 1
                step = step + 1
                if Core.IsValidObj(m) then
                    pcall(function()
                        local mid = tonumber(m.ID)
                        if mid and mid > 0 then machineIdSet[mid] = true end
                    end)
                    if not StationData.ShouldHideMachineOnMap(m) then
                        local lx, ly, lz, lyaw = GetMachineLocalPosAndYaw(m, xform)
                        local skipZero = math.abs(lx) < 0.5 and math.abs(ly) < 0.5 and math.abs(lz) < 0.5 and (not Core.IsValidObj(StationData.GetObjectActor(m)))
                        if not skipZero then
                            local bestFl, bestDz = nil, math.huge
                            for _, fl in ipairs(floors) do
                                local dz = math.abs(lz - fl.z)
                                if dz < bestDz then bestDz = dz; bestFl = fl end
                            end
                            if bestFl then
                                bestFl.machines[#bestFl.machines + 1] = { machine = m, x = lx, y = ly, z = lz, yaw = lyaw }
                            end
                        end
                    end
                end
            end
            if mIdx <= totalM then
                ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
                return
            end
            phase = "walls_init"
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "walls_init" then
            wallState = initWallExtraction()
            logSlowTick()
            if not wallState then
                finishAsyncBuild()
                return
            end
            phase = "walls_scan"
            ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
            return
        end

        if phase == "walls_scan" and wallState then
            local ws = wallState
            local step = 0
            while ws.idx <= ws.num and (step < minWallStep or os.clock() < budgetEnd) and step < 80 do
                local i = ws.idx
                ws.idx = i + 1
                step = step + 1
                local c = ws.cols[i]
                local cid = nil
                if c then pcall(function() cid = tonumber(c.ColliderID) end) end
                if not (cid and machineIdSet[cid]) then
                    local elemAddr = ws.dataAddr + (i - 1) * ws.stride
                    local z1 = ws.readIntAt(elemAddr + 0x08)
                    local z2 = ws.readIntAt(elemAddr + 0x14)
                    if z1 and z2 and z2 > z1 then
                        local x1 = ws.readIntAt(elemAddr + 0x00)
                        local y1 = ws.readIntAt(elemAddr + 0x04)
                        local x2 = ws.readIntAt(elemAddr + 0x0C)
                        local y2 = ws.readIntAt(elemAddr + 0x10)
                        if x1 and y1 and x2 and y2 and x1 < 999000000 and x2 > -999000000 and x2 > x1 and y2 > y1 then
                            local aMax = math.max(math.abs(x1), math.abs(x2), math.abs(y1), math.abs(y2))
                            if aMax > ws.maxAbs then ws.maxAbs = aMax end
                            ws.rawBoxes[#ws.rawBoxes + 1] = { x1 = x1, y1 = y1, z1 = z1, x2 = x2, y2 = y2, z2 = z2 }
                        end
                    end
                end
            end
            if ws.idx <= ws.num then
                ExecuteInGameThreadAfterFrames(frameStride, pumpAsyncBuild)
                return
            end

            local scale = 1.0
            if ws.maxAbs > 1000000.0 then
                scale = 1.0 / 65536.0
                if (ws.maxAbs * scale) < 260.0 then scale = scale * 100.0 end
            elseif ws.maxAbs > 100000.0 then
                scale = 0.1
            elseif ws.maxAbs > 0.0 and ws.maxAbs < 260.0 then
                scale = 50.0
            end

            local extractedWalls = {}
            for _, rb in ipairs(ws.rawBoxes) do
                local minX, maxX = rb.x1 * scale, rb.x2 * scale
                local minY, maxY = rb.y1 * scale, rb.y2 * scale
                local minZ, maxZ = rb.z1 * scale, rb.z2 * scale
                if stationInverted then
                    minY, maxY = -maxY, -minY
                    minZ, maxZ = -maxZ, -minZ
                end
                local dx, dy, dz = maxX - minX, maxY - minY, maxZ - minZ
                if dz >= 70.0 and math.max(dx, dy) >= 20.0 and not (dx >= 1200.0 and dy >= 1200.0) then
                    extractedWalls[#extractedWalls + 1] = {
                        minX = minX, maxX = maxX, minY = minY, maxY = maxY, minZ = minZ, maxZ = maxZ,
                        cx = (minX + maxX) * 0.5, cy = (minY + maxY) * 0.5, ex = dx * 0.5, ey = dy * 0.5,
                    }
                end
            end
            MergeWallList(extractedWalls)
            CachedStationWallsByKey[ws.stWallKey] = {
                total = ws.num, scale = scale, status = "ok", walls = extractedWalls, time = os.clock(),
            }
            for _, wb in ipairs(extractedWalls) do
                for _, fl in ipairs(floors) do
                    if wb.minZ <= (fl.z + 200.0) and wb.maxZ >= (fl.z + 50.0) then
                        fl.walls[#fl.walls + 1] = wb
                    end
                end
            end
            finishAsyncBuild()
        end
    end

    ExecuteInGameThreadAfterFrames(1, pumpAsyncBuild)
    return floors, currentFloorIndex, unitSize, gridOriginX, gridOriginY, xform, true
end

--------------------------------------------------------------------------------
-- Machine Classification & Item Icon Extraction
--------------------------------------------------------------------------------

local function CollectMachinesFromContainer(container, out, seen)
    if not Core.IsValidObj(container) then return end
    local okFind, arr = pcall(function() return container:FindMachines() end)
    if okFind and arr then
        StationData.ForEachArray(arr, function(_, elem)
            local m = Core.UnwrapArrayElem(elem)
            if Core.IsValidObj(m) then
                local addr = m:GetAddress()
                if not seen[addr] then
                    seen[addr] = true
                    table.insert(out, m)
                end
            end
        end)
    end
    for _, propName in ipairs({ "Machines", "Elevators", "MultiblockMachines" }) do
        local okProp, propArr = pcall(function() return container[propName] end)
        if okProp and propArr then
            StationData.ForEachArray(propArr, function(_, elem)
                local m = Core.UnwrapArrayElem(elem)
                if Core.IsValidObj(m) then
                    local addr = m:GetAddress()
                    if not seen[addr] then
                        seen[addr] = true
                        table.insert(out, m)
                    end
                end
            end)
        end
    end
end

function StationData.GetAllStationMachines(station, platforms, walkFrame)
    local out = {}
    local seen = {}
    local matchFrames = {}

    if Core.IsValidObj(station) then
        matchFrames[station:GetAddress()] = true
        CollectMachinesFromContainer(station, out, seen)
    end
    if Core.IsValidObj(walkFrame) then
        matchFrames[walkFrame:GetAddress()] = true
        CollectMachinesFromContainer(walkFrame, out, seen)
    end
    if platforms then
        for _, p in ipairs(platforms) do
            if Core.IsValidObj(p) then
                matchFrames[p:GetAddress()] = true
                CollectMachinesFromContainer(p, out, seen)
            end
        end
    end

    if #out == 0 and next(matchFrames) ~= nil then
        local okAll, allMachines = pcall(FindAllOf, "MachineObject")
        if okAll and allMachines then
            for _, m in ipairs(allMachines) do
                if Core.IsValidObj(m) and m.GetFrame then
                    local okF, mf = pcall(function() return m:GetFrame() end)
                    if okF and Core.IsValidObj(mf) and matchFrames[mf:GetAddress()] then
                        local addr = m:GetAddress()
                        if not seen[addr] then
                            seen[addr] = true
                            table.insert(out, m)
                        end
                    end
                end
            end
        end
    end

    return out
end

function StationData.GetFrameMachines(frame)
    local out = {}
    if not Core.IsValidObj(frame) then return out end

    local frameAddr = frame:GetAddress()
    local now = os.clock()
    local cached = CachedMachinesByFrame[frameAddr]
    if cached and (now - cached.time) < 2.0 then
        local validList = {}
        for _, m in ipairs(cached.list) do
            if Core.IsValidObj(m) then table.insert(validList, m) end
        end
        return validList
    end

    local seen = {}
    CollectMachinesFromContainer(frame, out, seen)
    if #out > 0 then
        CachedMachinesByFrame[frameAddr] = { time = now, list = out }
        return out
    end

    local okAll, allMachines = pcall(FindAllOf, "MachineObject")
    if okAll and allMachines then
        for _, m in ipairs(allMachines) do
            if Core.IsValidObj(m) and m.GetFrame then
                local okF, mf = pcall(function() return m:GetFrame() end)
                if okF and Core.IsValidObj(mf) and mf:GetAddress() == frameAddr then
                    local addr = m:GetAddress()
                    if not seen[addr] then
                        seen[addr] = true
                        table.insert(out, m)
                    end
                end
            end
        end
    end
    CachedMachinesByFrame[frameAddr] = { time = now, list = out }
    return out
end

local CachedStationMachines = { key = nil, time = 0, list = {} }

function StationData.GetStationMachines(station, fallbackFrame)
    local refObj = Core.IsValidObj(station) and station or fallbackFrame
    if not Core.IsValidObj(refObj) then return {} end

    local now = os.clock()
    local cacheKey = tostring(refObj:GetAddress())
    if CachedStationMachines.key == cacheKey and (now - CachedStationMachines.time) < 1.5 then
        local validList = {}
        for _, m in ipairs(CachedStationMachines.list) do
            if Core.IsValidObj(m) then
                validList[#validList + 1] = m
            end
        end
        return validList
    end

    local out = {}
    local seen = {}
    if Core.IsValidObj(station) then
        CollectMachinesFromContainer(station, out, seen)
    end
    if Core.IsValidObj(fallbackFrame) and (not Core.IsValidObj(station) or fallbackFrame:GetAddress() ~= station:GetAddress()) then
        CollectMachinesFromContainer(fallbackFrame, out, seen)
    end

    -- Fallback: single FindAllOf("MachineObject") scan if direct container collection returned nothing
    if #out == 0 then
        local targetAddrs = {}
        if Core.IsValidObj(station) then targetAddrs[station:GetAddress()] = true end
        if Core.IsValidObj(fallbackFrame) then targetAddrs[fallbackFrame:GetAddress()] = true end
        local okAll, allMachines = pcall(FindAllOf, "MachineObject")
        if okAll and allMachines then
            for _, m in ipairs(allMachines) do
                if Core.IsValidObj(m) and m.GetFrame then
                    local okF, mf = pcall(function() return m:GetFrame() end)
                    if okF and Core.IsValidObj(mf) and targetAddrs[mf:GetAddress()] then
                        local addr = m:GetAddress()
                        if not seen[addr] then
                            seen[addr] = true
                            out[#out + 1] = m
                        end
                    end
                end
            end
        end
    end

    CachedStationMachines = { key = cacheKey, time = now, list = out }
    return out
end

function StationData.GetItemIconTexture(item)
    if not Core.IsValidObj(item) then return nil end
    for _, prop in ipairs({ "Icon", "Texture", "IconTexture" }) do
        local ok, tex = pcall(function() return item[prop] end)
        if ok and Core.IsValidObj(tex) then
            return tex
        end
    end
    return nil
end

local BeltMatDiagLogged = false
local UndergroundDiagLogged = false
local PortDiagLoggedByCls = {}
local CachedBeltTexByCls = {}
local CachedBuildablesByCls = nil
local CachedBuildablesByName = nil
local CachedGameTexList = nil
local MissingIconDiagLogged = {}

local function ResolveTextureValue(val)
    if val == nil then return nil end
    if Core.IsValidObj(val) then return val end
    local res = nil
    pcall(function()
        if val.ResourceObject and Core.IsValidObj(val.ResourceObject) then
            res = val.ResourceObject
            return
        end
        if type(val.Get) == "function" then
            local g = val:Get()
            if Core.IsValidObj(g) then res = g return end
        end
        if type(val.ToString) == "function" then
            local p = val:ToString()
            if type(p) == "string" and p ~= "" and p ~= "None" then
                local loaded = Core.FindOrLoadClass(p)
                if Core.IsValidObj(loaded) then res = loaded return end
            end
        end
    end)
    return res
end

local function NormLookupKey(s)
    if type(s) ~= "string" or s == "" then return nil end
    local k = s:lower()
    k = k:gsub("^bpo_", ""):gsub("^bp_", ""):gsub("^da_", ""):gsub("^b_", "")
    k = k:gsub("object_c$", ""):gsub("_c$", "")
    k = k:gsub("[^a-z0-9]+", "")
    return (k ~= "" and k or nil)
end

local function CollectGameTextures()
    -- Never run FindAllOf("Texture2D") over thousands of engine textures;
    -- machine icons resolve directly from Buildable.Icon / GetIcon properties.
    if not CachedGameTexList then CachedGameTexList = {} end
    return CachedGameTexList
end

local function FindBuildableForMachineClass(machine)
    if not Core.IsValidObj(machine) then return nil end
    if not CachedBuildablesByCls then
        CachedBuildablesByCls = {}
        CachedBuildablesByName = {}
        pcall(function()
            local all = FindAllOf("Buildable")
            local clsPropNames = {
                "ObjectClass", "MachineClass", "ActorClass", "ConstructionClass",
                "BuilderClass", "BlockClass", "StationObjectClass", "SpawnClass",
                "PlaceableClass", "PreviewClass", "DockedClass", "DockClass",
                "Blueprint", "Class", "ShipClass",
            }
            local discoveredExtra = false
            if all then
                for _, b in ipairs(all) do
                    if Core.IsValidObj(b) then
                        if not discoveredExtra then
                            discoveredExtra = true
                            local bCls = b:GetClass()
                            if Core.IsValidObj(bCls) and bCls.ForEachProperty then
                                pcall(function()
                                    bCls:ForEachProperty(function(prop)
                                        local pn = prop:GetFName():ToString()
                                        local low = pn:lower()
                                        if low:find("class", 1, true) or low:find("object", 1, true)
                                            or low:find("actor", 1, true) or low:find("block", 1, true)
                                            or low:find("machine", 1, true)
                                        then
                                            table.insert(clsPropNames, pn)
                                        end
                                    end)
                                end)
                            end
                        end
                        for _, cProp in ipairs(clsPropNames) do
                            local okC, val = pcall(function() return b[cProp] end)
                            if okC and val ~= nil then
                                if Core.IsValidObj(val) then
                                    CachedBuildablesByCls[val:GetAddress()] = b
                                    local okN, fn = pcall(function() return val:GetFName():ToString() end)
                                    if okN and fn then
                                        CachedBuildablesByCls["fn:" .. fn:lower()] = b
                                        local nk = NormLookupKey(fn)
                                        if nk then CachedBuildablesByName[nk] = b end
                                    end
                                else
                                    pcall(function()
                                        if type(val.Get) == "function" then
                                            local g = val:Get()
                                            if Core.IsValidObj(g) then
                                                CachedBuildablesByCls[g:GetAddress()] = b
                                            end
                                        end
                                        if type(val.ToString) == "function" then
                                            local p = val:ToString()
                                            if type(p) == "string" and p ~= "" and p ~= "None" then
                                                CachedBuildablesByCls["path:" .. p:lower()] = b
                                                local short = p:match("([^./]+)$")
                                                if short then
                                                    local nk = NormLookupKey(short)
                                                    if nk then CachedBuildablesByName[nk] = b end
                                                end
                                            end
                                        end
                                    end)
                                end
                            end
                        end
                        pcall(function()
                            local nkF = NormLookupKey(b:GetFName():ToString())
                            if nkF and not CachedBuildablesByName[nkF] then CachedBuildablesByName[nkF] = b end
                            if b.DisplayName then
                                local nkD = NormLookupKey(b.DisplayName:ToString())
                                if nkD and not CachedBuildablesByName[nkD] then CachedBuildablesByName[nkD] = b end
                            end
                        end)
                    end
                end
            end
        end)
    end
    local res = nil
    local function matchClassObj(cls)
        if not Core.IsValidObj(cls) then return nil end
        local byAddr = CachedBuildablesByCls[cls:GetAddress()]
        if byAddr then return byAddr end
        local okF, fn = pcall(function() return cls:GetFName():ToString() end)
        if okF and fn then
            if CachedBuildablesByCls["fn:" .. fn:lower()] then return CachedBuildablesByCls["fn:" .. fn:lower()] end
            local nk = NormLookupKey(fn)
            if nk and CachedBuildablesByName[nk] then return CachedBuildablesByName[nk] end
        end
        local okFull, full = pcall(function() return cls:GetFullName() end)
        if okFull and type(full) == "string" then
            local cp = full:match("^%S+ (.+)$") or full
            if CachedBuildablesByCls["path:" .. cp:lower()] then return CachedBuildablesByCls["path:" .. cp:lower()] end
        end
        return nil
    end

    pcall(function()
        res = matchClassObj(machine:GetClass())
        if not res then
            local actor = StationData.GetObjectActor(machine)
            if Core.IsValidObj(actor) and actor.GetClass then
                res = matchClassObj(actor:GetClass())
            end
        end
    end)
    return res
end

StationData.FindBuildableForMachineClass = FindBuildableForMachineClass
StationData.GetMachineBuildable = FindBuildableForMachineClass

function StationData.GetConveyorBeltTexture(machine)
    if not Core.IsValidObj(machine) then return nil end
    local clsAddr = nil
    pcall(function() clsAddr = machine:GetClass():GetAddress() end)
    if clsAddr and CachedBeltTexByCls[clsAddr] ~= nil then
        return CachedBeltTexByCls[clsAddr] or nil
    end

    local actor = StationData.GetObjectActor(machine)
    if not Core.IsValidObj(actor) then
        pcall(function()
            local okAll, list = pcall(FindAllOf, "ConveyorBeltObject")
            if okAll and list then
                for _, other in ipairs(list) do
                    if Core.IsValidObj(other) and other:GetClass():GetAddress() == clsAddr then
                        local oa = StationData.GetObjectActor(other)
                        if Core.IsValidObj(oa) then actor = oa break end
                    end
                end
            end
        end)
    end

    local bestTex = nil
    local bestScore = -999
    local diagParts = {}
    local matDiag = {}
    local compCount = 0

    local function considerTex(sourceTag, pName, tex)
        if not Core.IsValidObj(tex) then return end
        local tName = ""
        local tFull = ""
        pcall(function() tName = tex:GetFName():ToString() end)
        pcall(function() tFull = tex:GetFullName() end)
        local low = (pName .. " " .. tName .. " " .. tFull):lower()
        if not BeltMatDiagLogged then
            table.insert(diagParts, string.format("%s:%s=%s", sourceTag, pName, tName))
        end
        local score = 0
        if low:find("normal", 1, true) or low:find("_n.", 1, true) or low:find("_n_", 1, true) or tName:lower():match("_n$")
            or low:find("rough", 1, true) or low:find("metal", 1, true) or low:find("_orm", 1, true)
            or low:find("_m.", 1, true) or low:find("_r.", 1, true) or low:find("opacity", 1, true)
            or low:find("mask", 1, true) or low:find("noise", 1, true)
        then
            score = -200
        else
            if low:find("conveyor", 1, true) then score = score + 30 end
            if low:find("belt", 1, true) then score = score + 30 end
            if low:find("arrow", 1, true) or low:find("chevron", 1, true) or low:find("tread", 1, true) or low:find("track", 1, true) then
                score = score + 50
            end
            if low:find("albedo", 1, true) or low:find("diffuse", 1, true) or low:find("basecolor", 1, true)
                or low:find("color", 1, true) or low:find("_bc", 1, true) or low:find("_d", 1, true)
            then
                score = score + 25
            end
            if score == 0 then score = 5 end
        end
        if score > bestScore then
            bestScore = score
            bestTex = tex
        end
    end

    local visitedMats = {}
    local function inspectMat(mat, depth)
        if not Core.IsValidObj(mat) or depth > 4 then return end
        local ma = mat:GetAddress()
        if visitedMats[ma] then return end
        visitedMats[ma] = true

        if not BeltMatDiagLogged then
            local mName, mCls = "?", "?"
            pcall(function() mName = mat:GetFName():ToString() end)
            pcall(function() mCls = mat:GetClass():GetFName():ToString() end)
            table.insert(matDiag, string.format("%s(%s)", mName, mCls))
        end

        pcall(function()
            local tpvs = mat.TextureParameterValues
            if tpvs then
                StationData.ForEachArray(tpvs, function(_, elem)
                    local st = Core.UnwrapStruct(elem)
                    if st then
                        local pName = "?"
                        pcall(function()
                            if st.ParameterInfo and st.ParameterInfo.Name then
                                pName = st.ParameterInfo.Name:ToString()
                            end
                        end)
                        considerTex("TPV", pName, ResolveTextureValue(st.ParameterValue))
                    end
                end)
            end
            for _, refArrName in ipairs({ "ReferencedTextures" }) do
                local okR, refs = pcall(function() return mat[refArrName] end)
                if okR and refs then
                    StationData.ForEachArray(refs, function(_, elem)
                        considerTex("Ref", "ref", ResolveTextureValue(Core.UnwrapArrayElem(elem)))
                    end)
                end
            end
            local okCed, ced = pcall(function() return mat.CachedExpressionData end)
            if okCed and ced and ced.ReferencedTextures then
                StationData.ForEachArray(ced.ReferencedTextures, function(_, elem)
                    considerTex("CED", "ref", ResolveTextureValue(Core.UnwrapArrayElem(elem)))
                end)
            end
            local okExp, exps = pcall(function() return mat.Expressions end)
            if okExp and exps then
                StationData.ForEachArray(exps, function(_, elem)
                    local e = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(e) then
                        local okT, t = pcall(function() return e.Texture end)
                        if okT and t then considerTex("Expr", "expr", ResolveTextureValue(t)) end
                    end
                end)
            end
            if Core.IsValidObj(mat.Parent) then
                inspectMat(mat.Parent, depth + 1)
            end
        end)
    end

    if Core.IsValidObj(actor) then
        pcall(function()
            local meshCls = Core.FindOrLoadClass("/Script/Engine.MeshComponent")
            if Core.IsValidObj(meshCls) and actor.K2_GetComponentsByClass then
                local rawComps = actor:K2_GetComponentsByClass(meshCls)
                StationData.ForEachArray(rawComps, function(_, elem)
                    local c = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(c) then
                        compCount = compCount + 1
                        if c.GetNumMaterials and c.GetMaterial then
                            local nm = math.min(tonumber(c:GetNumMaterials()) or 0, 8)
                            for mi = 0, nm - 1 do
                                inspectMat(c:GetMaterial(mi), 1)
                            end
                        end
                        if c.StaticMesh and c.StaticMesh.StaticMaterials then
                            StationData.ForEachArray(c.StaticMesh.StaticMaterials, function(_, smElem)
                                local smSt = Core.UnwrapStruct(smElem)
                                if smSt and Core.IsValidObj(smSt.MaterialInterface) then
                                    inspectMat(smSt.MaterialInterface, 1)
                                end
                            end)
                        end
                    end
                end)
            end
        end)
    end

    -- Fallback: scan loaded Texture2D assets for conveyor / belt tread textures
    if bestScore <= 5 then
        local allGameTex = CollectGameTextures()
        for _, ti in ipairs(allGameTex) do
            local low = ti.lowFull
            if (low:find("conveyor", 1, true) or low:find("belt", 1, true))
                and not low:find("/ui", 1, true) and not low:find("icon", 1, true)
                and not low:find("thumbnail", 1, true) and not low:find("splitter", 1, true)
                and not low:find("balancer", 1, true) and not low:find("underground", 1, true)
            then
                considerTex("Scan", ti.name, ti.tex)
            end
        end
    end

    if not BeltMatDiagLogged then
        BeltMatDiagLogged = true
        local aName = Core.IsValidObj(actor) and (pcall(function() return actor:GetFName():ToString() end) and actor:GetFName():ToString() or "?") or "nil"
        Core.Log(string.format("[StationData] BeltMatDiag actor=%s comps=%d mats=[%s] bestScore=%d tex=%s params=[%s]",
            aName, compCount, table.concat(matDiag, ", "), bestScore,
            Core.IsValidObj(bestTex) and bestTex:GetFName():ToString() or "nil",
            table.concat(diagParts, ", ")))
    end

    if bestScore <= 0 then bestTex = nil end
    if clsAddr then
        CachedBeltTexByCls[clsAddr] = bestTex or false
    end
    return bestTex
end

function StationData.GetBuildableIconTexture(machine, buildableOpt)
    local iconClsAddr = nil
    if not Core.IsValidObj(buildableOpt) and Core.IsValidObj(machine) then
        pcall(function()
            local mc = machine:GetClass()
            if Core.IsValidObj(mc) then iconClsAddr = mc:GetAddress() end
        end)
        if iconClsAddr and CachedIconTexByCls[iconClsAddr] ~= nil then
            local cached = CachedIconTexByCls[iconClsAddr]
            return (cached ~= false and Core.IsValidObj(cached)) and cached or nil
        end
    end

    local function cacheAndReturn(tex)
        if iconClsAddr then
            CachedIconTexByCls[iconClsAddr] = Core.IsValidObj(tex) and tex or false
        end
        return Core.IsValidObj(tex) and tex or nil
    end

    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
        if not Core.IsValidObj(bld) then
            local actor = StationData.GetObjectActor(machine)
            if Core.IsValidObj(actor) then
                pcall(function() bld = actor.Buildable or actor.BuildableData end)
            end
        end
        if not Core.IsValidObj(bld) then
            bld = FindBuildableForMachineClass(machine)
        end
    end
    if Core.IsValidObj(bld) then
        for _, prop in ipairs({ "Icon", "Texture", "IconTexture", "Image", "Thumbnail" }) do
            local ok, v = pcall(function() return bld[prop] end)
            if ok and v ~= nil then
                local tex = ResolveTextureValue(v)
                if Core.IsValidObj(tex) then return cacheAndReturn(tex) end
            end
        end
        local okD, det = pcall(function() return bld.ItemDetails end)
        if okD and det then
            for _, prop in ipairs({ "Icon", "Texture", "Image" }) do
                local ok, v = pcall(function() return det[prop] end)
                if ok and v ~= nil then
                    local tex = ResolveTextureValue(v)
                    if Core.IsValidObj(tex) then return cacheAndReturn(tex) end
                end
            end
        end
    end
    if Core.IsValidObj(machine) then
        for _, prop in ipairs({ "Icon", "Texture", "IconTexture", "Image", "Thumbnail" }) do
            local ok, v = pcall(function() return machine[prop] end)
            if ok and v ~= nil then
                local tex = ResolveTextureValue(v)
                if Core.IsValidObj(tex) then return cacheAndReturn(tex) end
            end
        end
        -- Fallback: check machine/actor properties referencing another data asset (Dock/Block/Data)
        local candidates = { machine }
        local actor = StationData.GetObjectActor(machine)
        if Core.IsValidObj(actor) then table.insert(candidates, actor) end
        for _, owner in ipairs(candidates) do
            for _, subProp in ipairs({ "Dock", "Block", "DockData", "BlockData", "Definition", "Data", "Config" }) do
                local okS, sub = pcall(function() return owner[subProp] end)
                if okS and Core.IsValidObj(sub) then
                    for _, ip in ipairs({ "Icon", "Texture", "IconTexture", "Image" }) do
                        local okI, v = pcall(function() return sub[ip] end)
                        if okI and v ~= nil then
                            local tex = ResolveTextureValue(v)
                            if Core.IsValidObj(tex) then return cacheAndReturn(tex) end
                        end
                    end
                end
            end
        end

        -- Fallback 2: search loaded Texture2D UI/Icon assets matching normalized class/name tokens
        local clsKey = ""
        pcall(function() clsKey = machine:GetClass():GetFName():ToString() end)
        local mNorm = NormLookupKey(clsKey) or ""
        local dispNorm = NormLookupKey(StationData.GetMachineDisplayName(machine)) or ""
        local allTex = CollectGameTextures()
        local bestTex, bestScore = nil, 0
        for _, ti in ipairs(allTex) do
            local lf = ti.lowFull
            if not lf:find("_n.", 1, true) and not lf:find("_orm", 1, true) and not lf:find("normal", 1, true) then
                local sc = 0
                if mNorm ~= "" and ti.normName:find(mNorm, 1, true) then sc = sc + 80 end
                if dispNorm ~= "" and ti.normName:find(dispNorm, 1, true) then sc = sc + 70 end
                -- Token matching (e.g. shipyard + dock, station + dock)
                if mNorm:find("shipyard", 1, true) or dispNorm:find("shipyard", 1, true) then
                    if lf:find("shipyard", 1, true) then
                        sc = sc + 45
                        if lf:find("core", 1, true) or lf:find("dock", 1, true) then sc = sc + 20 end
                    end
                elseif mNorm:find("dock", 1, true) or dispNorm:find("dock", 1, true) then
                    if ti.lowName:find("industrialdock", 1, true) or ti.lowName:find("dock_0", 1, true) or ti.lowName:find("dockingcollar", 1, true) then
                        sc = sc + 45
                    elseif lf:find("dock", 1, true) then
                        sc = sc + 30
                    end
                end
                if sc > 0 then
                    if lf:find("/ui", 1, true) or lf:find("icon", 1, true) or ti.lowName:match("^t_") then sc = sc + 20 end
                    if sc > bestScore then bestScore = sc; bestTex = ti.tex end
                end
            end
        end
        if Core.IsValidObj(bestTex) and bestScore >= 45 then
            return cacheAndReturn(bestTex)
        end
    end
    return cacheAndReturn(nil)
end

function StationData.GetMachineTypeAndTier(machine, buildableOpt)
    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
    end

    local dispName = ""
    if Core.IsValidObj(bld) then
        pcall(function()
            if bld.DisplayName then dispName = bld.DisplayName:ToString() end
        end)
    end
    if dispName == "" and Core.IsValidObj(machine) then
        dispName = StationData.GetMachineDisplayName(machine)
    end

    local clsName = ""
    if Core.IsValidObj(machine) then
        pcall(function() clsName = machine:GetClass():GetFName():ToString() end)
    elseif Core.IsValidObj(bld) then
        pcall(function() clsName = bld:GetFName():ToString() end)
    end

    -- Detect tier from Buildable.Tier, DisplayName (Mk. 2 / Mk 3 / II / III), or class suffix (_02 / _2)
    local tier = nil
    if Core.IsValidObj(bld) then
        pcall(function()
            local bt = tonumber(bld.Tier)
            if bt and bt >= 1 then tier = math.floor(bt) end
        end)
    end
    if not tier then
        local dn = dispName
        local mk = dn:match("[Mm][Kk]%.?%s*(%d+)") or dn:match("[Tt]ier%s*(%d+)") or dn:match("%s+(%d+)$")
        if mk then
            tier = tonumber(mk)
        elseif dn:match("%s+IV$") then tier = 4
        elseif dn:match("%s+III$") then tier = 3
        elseif dn:match("%s+II$") then tier = 2
        elseif dn:match("%s+I$") then tier = 1
        end
    end
    if not tier then
        local cnMk = clsName:match("_[Mm][Kk](%d+)") or clsName:match("_0?(%d+)[A-Za-z]?_C$")
        if cnMk then
            tier = tonumber(cnMk)
        end
    end
    tier = Core.Clamp(tier or 1, 1, 6)

    -- Normalize type key by stripping tier suffix and prefixes
    local base = (dispName ~= "" and dispName or clsName):lower()
    base = base:gsub("^bpo_", ""):gsub("^bp_", ""):gsub("object_c$", ""):gsub("_c$", "")
    base = base:gsub("%s*[Tt]ier%s*%d+", ""):gsub("%s*[Mm][Kk]%.?%s*%d+", "")
    base = base:gsub("%s+iv$", ""):gsub("%s+iii$", ""):gsub("%s+ii$", ""):gsub("%s+i$", "")
    base = base:gsub("_[%d]+[a-z]?$", ""):gsub("%s+%d+$", "")
    base = base:gsub("[^a-z0-9]+", " "):match("^%s*(.-)%s*$") or "machine"
    if base == "" then base = "machine" end

    return base, tier, (dispName ~= "" and dispName or "Machine")
end

local function GetItemIdentityKey(item)
    if not Core.IsValidObj(item) then return nil end
    local parts = {}
    pcall(function()
        if item.DisplayName then
            local dn = item.DisplayName:ToString()
            if dn and dn ~= "" then table.insert(parts, dn) end
        end
    end)
    pcall(function()
        local fn = item:GetFName():ToString()
        if fn and fn ~= "" then
            -- Strip trailing instance number (_2147...) if items are instanced
            fn = fn:gsub("_%d+$", "")
            table.insert(parts, fn)
        end
    end)
    if #parts > 0 then
        return table.concat(parts, "|")
    end
    return tostring(item:GetAddress())
end

function StationData.GetContainerTopItems(container, maxCount)
    local items = {}
    local inv = StationData.GetContainerInventory(container)
    if not Core.IsValidObj(inv) then return items end

    local byKey = {}
    local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
    if okSlots and slots then
        StationData.ForEachArray(slots, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = tonumber(st.Amount) or 0
                if amt > 0 then
                    local k = GetItemIdentityKey(st.Item)
                    if not byKey[k] then
                        byKey[k] = { Item = st.Item, Amount = 0 }
                    end
                    byKey[k].Amount = byKey[k].Amount + amt
                end
            end
        end)
    end
    for _, e in pairs(byKey) do
        table.insert(items, e)
    end
    table.sort(items, function(a, b) return a.Amount > b.Amount end)
    if maxCount and #items > maxCount then
        while #items > maxCount do table.remove(items) end
    end
    return items
end

function StationData.ShouldHideMachineOnMap(machine, buildableOpt)
    local clsAddr = nil
    if not Core.IsValidObj(buildableOpt) and Core.IsValidObj(machine) then
        pcall(function()
            local c = machine:GetClass()
            if Core.IsValidObj(c) then clsAddr = c:GetAddress() end
        end)
        if clsAddr and CachedHideByCls[clsAddr] ~= nil then
            return CachedHideByCls[clsAddr]
        end
    end
    local parts = {}
    if Core.IsValidObj(machine) then
        pcall(function() table.insert(parts, machine:GetClass():GetFName():ToString()) end)
        pcall(function()
            local b = machine.Buildable
            if Core.IsValidObj(b) and b.DisplayName then table.insert(parts, b.DisplayName:ToString()) end
        end)
    end
    if Core.IsValidObj(buildableOpt) then
        pcall(function()
            if buildableOpt.DisplayName then table.insert(parts, buildableOpt.DisplayName:ToString()) end
        end)
    end
    local combined = table.concat(parts, " "):lower()
    local hide = (combined:find("solar", 1, true) ~= nil) or (combined:find("turret", 1, true) ~= nil)
    if clsAddr then CachedHideByCls[clsAddr] = hide end
    return hide
end

function StationData.GetUndergroundBeltPairInfo(machine, xform)
    if not Core.IsValidObj(machine) then return nil end
    local cName = ""
    pcall(function() cName = machine:GetClass():GetFName():ToString():lower() end)
    if not cName:find("underground", 1, true) then return nil end

    local mx, my, mz, myaw = GetMachineLocalPosAndYaw(machine, xform)
    local info = {
        isUnderground = true,
        isInput = nil,
        pairX = nil,
        pairY = nil,
        pairZ = nil,
        pairAddr = nil,
    }

    local okIn, bIn = pcall(function()
        if machine.bIsInput ~= nil then return machine.bIsInput end
        if machine.bIsEntrance ~= nil then return machine.bIsEntrance end
        if machine.bInput ~= nil then return machine.bInput end
        return nil
    end)
    if okIn and type(bIn) == "boolean" then info.isInput = bIn end

    local okOut, bOut = pcall(function()
        if machine.bIsOutput ~= nil then return machine.bIsOutput end
        if machine.bIsExit ~= nil then return machine.bIsExit end
        if machine.bOutput ~= nil then return machine.bOutput end
        return nil
    end)
    if info.isInput == nil and okOut and type(bOut) == "boolean" then info.isInput = not bOut end

    -- 1. Check linked simulation belt object properties
    for _, prop in ipairs({ "OtherBelt", "ConnectedBelt", "OutputBelt", "TargetBelt", "LinkedBelt", "Partner", "ExitBelt", "Pair", "OtherEnd", "LinkedObject", "ConnectedObject" }) do
        local okP, other = pcall(function() return machine[prop] end)
        if okP and Core.IsValidObj(other) and other:GetAddress() ~= machine:GetAddress() then
            local ox, oy, oz = GetMachineLocalPosAndYaw(other, xform)
            info.pairX, info.pairY, info.pairZ = ox, oy, oz
            info.pairAddr = other:GetAddress()
            break
        end
    end

    -- 2. Check vector / endpoint location properties on machine or actor
    local actor = StationData.GetObjectActor(machine)
    if not info.pairX then
        for _, owner in ipairs({ machine, actor }) do
            if Core.IsValidObj(owner) then
                for _, vProp in ipairs({ "EndLocation", "TargetLocation", "OutputLocation", "ExitLocation", "OtherLocation", "PairLocation", "SecondLocation" }) do
                    local okV, v = pcall(function() return owner[vProp] end)
                    if okV and v then
                        local vx, vy, vz = Core.GetFPVector(v)
                        if (vx ~= 0 or vy ~= 0) and xform then
                            local lox, loy, loz = StationData.WorldToStationLocal(xform, vx, vy, vz, nil, nil, nil)
                            if (math.abs(lox - mx) + math.abs(loy - my)) > 60.0 then
                                info.pairX, info.pairY, info.pairZ = lox, loy, loz
                                break
                            end
                        end
                    end
                end
            end
            if info.pairX then break end
        end
    end

    -- 3. Check if the underground actor contains a distinct second mesh / child actor >= 80cm from actor root
    local compDiag = {}
    if not info.pairX and Core.IsValidObj(actor) then
        pcall(function()
            local smCls = GetClassCached("StaticMeshComponent", "/Script/Engine.StaticMeshComponent")
            if Core.IsValidObj(smCls) and actor.K2_GetComponentsByClass then
                local rawComps = actor:K2_GetComponentsByClass(smCls)
                local bestDist = 80.0
                StationData.ForEachArray(rawComps, function(_, elem)
                    local c = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(c) and c.K2_GetComponentToWorld then
                        local xf = c:K2_GetComponentToWorld()
                        local loc = xf and xf.Translation or nil
                        if loc and type(loc.X) == "number" then
                            local lox, loy, loz = StationData.WorldToStationLocal(xform, loc.X, loc.Y or 0, loc.Z or 0, nil, nil, nil)
                            local d = math.sqrt((lox - mx) ^ 2 + (loy - my) ^ 2)
                            if not UndergroundDiagLogged then
                                table.insert(compDiag, string.format("%s@(%.0f,%.0f)", c:GetFName():ToString(), lox - mx, loy - my))
                            end
                            if d > bestDist then
                                bestDist = d
                                info.pairX, info.pairY, info.pairZ = lox, loy, loz
                            end
                        end
                    end
                end)
            end
        end)
    end

    if not UndergroundDiagLogged then
        UndergroundDiagLogged = true
        local mProps, aProps = {}, {}
        pcall(function()
            machine:GetClass():ForEachProperty(function(p) table.insert(mProps, p:GetFName():ToString()) end)
        end)
        if Core.IsValidObj(actor) then
            pcall(function()
                actor:GetClass():ForEachProperty(function(p) table.insert(aProps, p:GetFName():ToString()) end)
            end)
        end
        Core.Log(string.format("[StationData] UndergroundDiag cls=%s pair=(%s,%s) isIn=%s mProps=[%s] aProps=[%s] comps=[%s]",
            cName, tostring(info.pairX), tostring(info.pairY), tostring(info.isInput),
            table.concat(mProps, ","), table.concat(aProps, ","), table.concat(compDiag, ",")))
    end

    return info
end

function StationData.GetMachineItemPorts(machine, mwx, mwy, myaw, cellsX, cellsY, xform)
    local ports = {}
    if not Core.IsValidObj(machine) then return ports end

    local function tryExtractVec(elem)
        local st = Core.UnwrapStruct(elem) or elem
        if not st then return nil end
        local vx, vy, vz = nil, nil, 0
        pcall(function()
            local xVal = st.X
            local yVal = st.Y
            if xVal ~= nil and yVal ~= nil then
                vx = tonumber(xVal)
                vy = tonumber(yVal)
                return
            end
            if st.x ~= nil and st.y ~= nil then
                vx = tonumber(st.x)
                vy = tonumber(st.y)
                return
            end
            local sub = st.Location or st.Position or st.Offset or st.Cell
            if sub and sub.X ~= nil and sub.Y ~= nil then
                vx = tonumber(sub.X)
                vy = tonumber(sub.Y)
            end
        end)
        if vx and vy then
            pcall(function()
                local zVal = st.Z
                if zVal ~= nil then vz = tonumber(zVal) or 0 end
            end)
            return { x = vx, y = vy, z = vz or 0 }
        end
        return nil
    end

    local rawInputs, rawOutputs = {}, {}
    pcall(function()
        if machine.Inputs then
            StationData.ForEachArray(machine.Inputs, function(_, elem)
                local v = tryExtractVec(elem)
                if v then table.insert(rawInputs, v) end
            end)
        end
        if machine.Outputs then
            StationData.ForEachArray(machine.Outputs, function(_, elem)
                local v = tryExtractVec(elem)
                if v then table.insert(rawOutputs, v) end
            end)
        end
    end)

    -- Log element schema if Inputs/Outputs array is non-empty yet couldn't decode to XYZ
    if #rawInputs == 0 and #rawOutputs == 0 then
        local inLen = 0
        pcall(function()
            if machine.Inputs and machine.Inputs.GetArrayNum then inLen = tonumber(machine.Inputs:GetArrayNum()) or 0 end
        end)
        local outLen = 0
        pcall(function()
            if machine.Outputs and machine.Outputs.GetArrayNum then outLen = tonumber(machine.Outputs:GetArrayNum()) or 0 end
        end)
        if (inLen > 0 or outLen > 0) and not PortDiagLoggedByCls["elemSchema"] then
            PortDiagLoggedByCls["elemSchema"] = true
            local firstElem = nil
            pcall(function()
                if inLen > 0 then firstElem = machine.Inputs[1]
                elseif outLen > 0 then firstElem = machine.Outputs[1] end
            end)
            local innerInfo = "?"
            pcall(function()
                local c = machine:GetClass()
                local d = 0
                while Core.IsValidObj(c) and d < 6 do
                    d = d + 1
                    if c.ForEachProperty then
                        c:ForEachProperty(function(p)
                            local pn = p:GetFName():ToString()
                            if pn == "Inputs" or pn == "Outputs" then
                                local inn = p.GetInner and p:GetInner() or nil
                                local iCls = inn and inn:GetClass():GetFName():ToString() or "?"
                                local sName = ""
                                if inn and inn.GetStruct then
                                    local stObj = inn:GetStruct()
                                    if Core.IsValidObj(stObj) then
                                        sName = stObj:GetFName():ToString() .. "(" .. InspectStructFieldNames(stObj, 10) .. ")"
                                    end
                                end
                                innerInfo = string.format("%s inner=%s struct=%s", pn, iCls, sName)
                            end
                        end)
                    end
                    c = c.GetSuperStruct and c:GetSuperStruct() or nil
                end
            end)
            Core.Log(string.format("[StationData] PortElemTypeDiag cls=%s in=%d out=%d type=%s str=%s schema=[%s]",
                machine:GetClass():GetFName():ToString(), inLen, outLen,
                type(firstElem), tostring(firstElem), innerInfo))
        end
    end

    -- Fallback A: Read actual Port / BPC_MachinePortInteraction SceneComponents directly from the spawned machine actor
    if #rawInputs == 0 and #rawOutputs == 0 and xform then
        local actor = StationData.GetObjectActor(machine)
        if Core.IsValidObj(actor) then
            local cxCells = math.max(1, tonumber(cellsX) or 1)
            local cyCells = math.max(1, tonumber(cellsY) or 1)
            local halfCmX = cxCells * 50.0
            local halfCmY = cyCells * 50.0
            local rad = math.rad(myaw or 0.0)
            local cosA, sinA = math.cos(rad), math.sin(rad)
            local mergedActorPorts = {}

            pcall(function()
                local scCls = Core.FindOrLoadClass("/Script/Engine.SceneComponent")
                if Core.IsValidObj(scCls) and actor.K2_GetComponentsByClass then
                    local rawComps = actor:K2_GetComponentsByClass(scCls)
                    StationData.ForEachArray(rawComps, function(_, elem)
                        local cmp = Core.UnwrapArrayElem(elem)
                        if Core.IsValidObj(cmp) and cmp.K2_GetComponentToWorld then
                            local cn = cmp:GetFName():ToString()
                            if cn:match("^Port%d+$") or cn:find("MachinePort", 1, true) then
                                local xf = cmp:K2_GetComponentToWorld()
                                local loc = xf and xf.Translation or nil
                                if loc and type(loc.X) == "number" then
                                    local lpx, lpy = StationData.WorldToStationLocal(xform, loc.X, loc.Y or 0, loc.Z or 0, nil, nil, nil)
                                    -- Transform into unrotated machine-local space to snap to exact side & adjacent conveyor cell
                                    local dx, dy = lpx - (mwx or 0), lpy - (mwy or 0)
                                    local ux = dx * cosA + dy * sinA
                                    local uy = -dx * sinA + dy * cosA
                                    local nx, ny = 0.0, 0.0
                                    if math.abs(ux) / math.max(1.0, halfCmX) >= math.abs(uy) / math.max(1.0, halfCmY) then
                                        nx = (ux >= 0) and 1.0 or -1.0
                                    else
                                        ny = (uy >= 0) and 1.0 or -1.0
                                    end
                                    -- Snap tangential offset onto 100cm machine grid cell centers
                                    local function snapTangent(val, spanCells)
                                        if (spanCells % 2) == 1 then
                                            return math.floor(val / 100.0 + 0.5) * 100.0
                                        else
                                            return (math.floor(val / 100.0) + 0.5) * 100.0
                                        end
                                    end
                                    local tangX = snapTangent(ux, cxCells)
                                    local tangY = snapTangent(uy, cyCells)
                                    local portUx = (nx ~= 0) and (nx * math.max(12.0, halfCmX - 22.0)) or tangX
                                    local portUy = (ny ~= 0) and (ny * math.max(12.0, halfCmY - 22.0)) or tangY
                                    local adjUx = (nx ~= 0) and (nx * (halfCmX + 50.0)) or tangX
                                    local adjUy = (ny ~= 0) and (ny * (halfCmY + 50.0)) or tangY

                                    local wx = (mwx or 0) + portUx * cosA - portUy * sinA
                                    local wy = (mwy or 0) + portUx * sinA + portUy * cosA
                                    local ax = (mwx or 0) + adjUx * cosA - adjUy * sinA
                                    local ay = (mwy or 0) + adjUx * sinA + adjUy * cosA

                                    local dedupKey = string.format("%.0f,%.0f", wx / 20.0, wy / 20.0)
                                    if not mergedActorPorts[dedupKey] then
                                        mergedActorPorts[dedupKey] = {
                                            px = wx, py = wy,
                                            adjX = ax, adjY = ay,
                                            isInput = true,
                                            isOutput = true,
                                        }
                                    end
                                end
                            end
                        end
                    end)
                end
            end)

            for _, mp in pairs(mergedActorPorts) do
                table.insert(ports, mp)
            end
            if #ports > 0 then
                return ports
            end
        end
    end

    if #rawInputs == 0 and #rawOutputs == 0 then
        -- Fallback 1: check alternate property names on machine
        for _, pIn in ipairs({ "InputPorts", "InputLocations", "InputPositions", "InputOffsets", "ConveyorInputs", "ItemInputs" }) do
            local ok, arr = pcall(function() return machine[pIn] end)
            if ok and arr then
                StationData.ForEachArray(arr, function(_, elem)
                    local v = tryExtractVec(elem)
                    if v then
                        table.insert(rawInputs, v)
                    end
                end)
            end
            if #rawInputs > 0 then break end
        end
        for _, pOut in ipairs({ "OutputPorts", "OutputLocations", "OutputPositions", "OutputOffsets", "ConveyorOutputs", "ItemOutputs" }) do
            local ok, arr = pcall(function() return machine[pOut] end)
            if ok and arr then
                StationData.ForEachArray(arr, function(_, elem)
                    local v = tryExtractVec(elem)
                    if v then
                        table.insert(rawOutputs, v)
                    end
                end)
            end
            if #rawOutputs > 0 then break end
        end
    end

    if #rawInputs == 0 and #rawOutputs == 0 then
        return ports
    end

    local cxCells = math.max(1, tonumber(cellsX) or 1)
    local cyCells = math.max(1, tonumber(cellsY) or 1)
    local halfCmX = cxCells * 50.0
    local halfCmY = cyCells * 50.0
    local clsLow = ""
    pcall(function() clsLow = machine:GetClass():GetFName():ToString():lower() end)
    local isElevator = clsLow:find("elevator", 1, true) ~= nil

    -- Deduplicate ports sharing the same XY coordinate cell (some machines share bidirectional slots)
    local merged = {}
    local function addPortVec(v, isIn)
        local key = string.format("%.2f,%.2f", v.x, v.y)
        local entry = merged[key]
        if not entry then
            entry = { vx = v.x, vy = v.y, vz = v.z, isInput = false, isOutput = false, connected = false }
            merged[key] = entry
        end
        if isIn then entry.isInput = true else entry.isOutput = true end
        if v.connected then entry.connected = true end
    end
    for _, v in ipairs(rawInputs) do addPortVec(v, true) end
    for _, v in ipairs(rawOutputs) do addPortVec(v, false) end

    local rad = math.rad(myaw or 0.0)
    local cosA, sinA = math.cos(rad), math.sin(rad)

    -- MachineInputs / Outputs are 50cm grid offsets centered on the machine actor origin (0,0).
    -- Shift visual center 9.7cm (~1/6 of a 58cm port badge) inside the wall seam so 2/3 sits inside and 1/3 outside.
    local PORT_INWARD_SHIFT_CM = 9.7

    for _, mp in pairs(merged) do
        local lx = mp.vx * 50.0
        local ly = mp.vy * 50.0

        -- Determine open-side cardinal normal (points from wall seam into the adjacent belt cell)
        local nx, ny = 0.0, 0.0
        if isElevator and (math.abs(lx) > halfCmX + 25.0 or math.abs(ly) > halfCmY + 25.0) then
            -- Elevator ports sit on outer corridor walls and open inward toward the central hallway axis
            if math.abs(lx) >= math.abs(ly) then
                ny = (ly >= 0.0) and -1.0 or 1.0
            else
                nx = (lx >= 0.0) and -1.0 or 1.0
            end
        elseif math.abs(lx) / math.max(1.0, halfCmX) >= math.abs(ly) / math.max(1.0, halfCmY) then
            nx = (lx >= 0.0) and 1.0 or -1.0
        else
            ny = (ly >= 0.0) and 1.0 or -1.0
        end

        local portLx = lx - PORT_INWARD_SHIFT_CM * nx
        local portLy = ly - PORT_INWARD_SHIFT_CM * ny
        local adjLx = lx + 50.0 * nx
        local adjLy = ly + 50.0 * ny

        local wx = (mwx or 0.0) + portLx * cosA - portLy * sinA
        local wy = (mwy or 0.0) + portLx * sinA + portLy * cosA
        local ax = (mwx or 0.0) + adjLx * cosA - adjLy * sinA
        local ay = (mwy or 0.0) + adjLx * sinA + adjLy * cosA

        table.insert(ports, {
            px = wx, py = wy,
            adjX = ax, adjY = ay,
            isInput = mp.isInput,
            isOutput = mp.isOutput,
            isConnectedBySim = mp.connected,
        })
    end

    return ports
end

function StationData.GetProducerOutputsAndRates(machine)
    local outputs = {}
    if not Core.IsValidObj(machine) then return outputs end

    local rec = nil
    pcall(function() rec = machine.Recipe end)
    if not Core.IsValidObj(rec) then return outputs end

    local bonusMult = 1.0
    pcall(function()
        local bm = Core.GetFPFloat(machine.BonusMultiplier)
        if bm > 0.0001 then bonusMult = bm end
    end)

    local craftSec = 1.0
    local okSec, sec = pcall(function() return rec:GetCraftingSeconds() end)
    if okSec and type(sec) == "number" and sec > 0.0001 then
        craftSec = sec
    end

    local okOut, outStack = pcall(function() return rec.Output end)
    if okOut and outStack and Core.IsValidObj(outStack.Item) then
        local amt = tonumber(outStack.Amount) or 1
        local rate = (amt * 60.0 / craftSec) * bonusMult
        table.insert(outputs, { Item = outStack.Item, Rate = rate })
        return outputs
    end

    local okOuts, outs = pcall(function() return rec:GetOutputs() end)
    if okOuts and outs then
        StationData.ForEachArray(outs, function(_, elem)
            local st = Core.UnwrapStruct(elem)
            if st and Core.IsValidObj(st.Item) then
                local amt = tonumber(st.Amount) or 1
                local rate = (amt * 60.0 / craftSec) * bonusMult
                table.insert(outputs, { Item = st.Item, Rate = rate })
            end
        end)
    end
    return outputs
end

function StationData.GetMachineCategory(machine)
    if not Core.IsValidObj(machine) then return "Other" end
    local clsAddr = nil
    pcall(function()
        local c = machine:GetClass()
        if Core.IsValidObj(c) then clsAddr = c:GetAddress() end
    end)
    if clsAddr and CachedMachineCatByCls[clsAddr] then
        return CachedMachineCatByCls[clsAddr]
    end

    local cat = "Other"
    local asmCls = GetClassCached("AssemblerObject", PATHS.AssemblerObjectClass)
    if Core.IsValidObj(asmCls) and machine:IsA(asmCls) then
        cat = "Assembler"
    else
        local contCls = GetClassCached("ContainerObject", PATHS.ContainerObjectClass)
        if Core.IsValidObj(contCls) and machine:IsA(contCls) then
            cat = "Container"
        else
            local convCls = GetClassCached("ConveyorBeltObject", PATHS.ConveyorBeltObjectClass)
            if Core.IsValidObj(convCls) and machine:IsA(convCls) then
                cat = "Conveyor"
            end
        end
    end
    if clsAddr then CachedMachineCatByCls[clsAddr] = cat end
    return cat
end

function StationData.GetContainerInventory(container)
    if not Core.IsValidObj(container) then return nil end
    if container.GetInventory then
        local ok, inv = pcall(function() return container:GetInventory() end)
        if ok and Core.IsValidObj(inv) then return inv end
    end
    local okP, invP = pcall(function() return container.Inventory end)
    if okP and Core.IsValidObj(invP) then return invP end
    return nil
end

function StationData.GetPrimaryItemForMachine(machine)
    if not Core.IsValidObj(machine) then return nil, "Other" end
    local cat = StationData.GetMachineCategory(machine)

    if cat == "Assembler" then
        local okRec, rec = pcall(function() return machine.Recipe end)
        if okRec and Core.IsValidObj(rec) then
            local okOut, outStack = pcall(function() return rec.Output end)
            if okOut and outStack and Core.IsValidObj(outStack.Item) then
                return outStack.Item, cat
            end
            local okOuts, outs = pcall(function() return rec:GetOutputs() end)
            if okOuts and outs then
                local firstItem = nil
                StationData.ForEachArray(outs, function(_, elem)
                    if firstItem then return end
                    local st = Core.UnwrapStruct(elem)
                    if st and Core.IsValidObj(st.Item) then
                        firstItem = st.Item
                    end
                end)
                if firstItem then return firstItem, cat end
            end
        end
        return nil, cat
    end

    if cat == "Container" then
        local inv = StationData.GetContainerInventory(machine)
        if Core.IsValidObj(inv) then
            local bestItem = nil
            local bestAmount = -1
            local okSlots, slots = pcall(function() return inv:GetItemSlots() end)
            if okSlots and slots then
                StationData.ForEachArray(slots, function(_, elem)
                    local st = Core.UnwrapStruct(elem)
                    if st and Core.IsValidObj(st.Item) then
                        local amt = tonumber(st.Amount) or 1
                        if amt > bestAmount then
                            bestAmount = amt
                            bestItem = st.Item
                        end
                    end
                end)
            end
            if bestItem then return bestItem, cat end
        end
        return nil, cat
    end

    if cat == "Conveyor" then
        local okCur, cur = pcall(function() return machine.CurrentItem end)
        if okCur and cur ~= nil then
            local itemCls = GetClassCached("Item", PATHS.ItemClass)
            if Core.IsValidObj(cur) and Core.IsValidObj(itemCls) and cur:IsA(itemCls) then
                return cur, cat
            end
            local okItem, it = pcall(function() return cur.Item end)
            if okItem and Core.IsValidObj(it) then
                return it, cat
            end
        end
        return nil, cat
    end

    return nil, cat
end

function StationData.GetMachineDisplayName(machine)
    if not Core.IsValidObj(machine) then return "Machine" end
    local clsAddr = nil
    pcall(function()
        local c = machine:GetClass()
        if Core.IsValidObj(c) then clsAddr = c:GetAddress() end
    end)
    if clsAddr and CachedMachineDispByCls[clsAddr] then
        return CachedMachineDispByCls[clsAddr]
    end

    local name = "Machine"
    local okB, b = pcall(function() return machine.Buildable end)
    if okB and Core.IsValidObj(b) then
        local okN, n = pcall(function() return b.DisplayName:ToString() end)
        if okN and n and n ~= "" then name = n end
    end
    if name == "Machine" then
        local okCls, cls = pcall(function() return machine:GetClass():GetFName():ToString() end)
        if okCls and cls then
            name = cls:gsub("^BP_", ""):gsub("Object_C$", ""):gsub("_C$", "")
        end
    end
    if clsAddr then CachedMachineDispByCls[clsAddr] = name end
    return name
end

-- Returns unrotated footprint in 100cm grid cells (cellsX, cellsY) for a machine or buildable.
function StationData.GetMachineFootprintCells(machine, buildableOpt)
    local bld = Core.IsValidObj(buildableOpt) and buildableOpt or nil
    if not bld and Core.IsValidObj(machine) then
        pcall(function() bld = machine.Buildable end)
    end

    local clsKey = nil
    local actor = Core.IsValidObj(machine) and StationData.GetObjectActor(machine) or nil
    if Core.IsValidObj(actor) then
        local okC, cls = pcall(function() return actor:GetClass() end)
        if okC and Core.IsValidObj(cls) then clsKey = cls:GetAddress() end
    elseif Core.IsValidObj(bld) then
        clsKey = bld:GetAddress()
    elseif Core.IsValidObj(machine) then
        local okC, cls = pcall(function() return machine:GetClass() end)
        if okC and Core.IsValidObj(cls) then clsKey = cls:GetAddress() end
    end

    if clsKey and CachedFootprintsByClass[clsKey] then
        local f = CachedFootprintsByClass[clsKey]
        return f.cellsX, f.cellsY
    end

    local cx, cy = nil, nil
    local function tryReadDims(obj)
        if not Core.IsValidObj(obj) then return false end
        local found = false
        pcall(function()
            for _, propName in ipairs({ "MachineDimensions", "Dimensions", "Size" }) do
                local d = obj[propName]
                if d and d.X and d.Y then
                    local dx = math.abs(tonumber(d.X) or 0)
                    local dy = math.abs(tonumber(d.Y) or 0)
                    if dx > 0 and dy > 0 then
                        if dx >= 50 then dx = math.max(1, math.floor(dx / 100.0 + 0.5)) end
                        if dy >= 50 then dy = math.max(1, math.floor(dy / 100.0 + 0.5)) end
                        cx, cy = math.max(1, math.floor(dx + 0.5)), math.max(1, math.floor(dy + 0.5))
                        found = true
                        return
                    end
                end
            end
        end)
        return found
    end

    if not tryReadDims(machine) and not tryReadDims(bld) and Core.IsValidObj(actor) then
        pcall(function()
            local smCls = GetClassCached("StaticMeshComponent", "/Script/Engine.StaticMeshComponent")
            if Core.IsValidObj(smCls) and actor.K2_GetComponentsByClass then
                local compsRaw = actor:K2_GetComponentsByClass(smCls)
                local minX, maxX, minY, maxY = math.huge, -math.huge, math.huge, -math.huge
                local any = false
                StationData.ForEachArray(compsRaw, function(_, elem)
                    local c = Core.UnwrapArrayElem(elem)
                    if Core.IsValidObj(c) and c.StaticMesh and c.StaticMesh.ExtendedBounds then
                        -- Never call c:IsVisible() or c.StaticMesh:GetFName() (UE4SS 0x18 crash triggers; learning.md §6)
                        local hidden = (c.bHiddenInGame == true)
                        local compName = ""
                        pcall(function() compName = c:GetFName():ToString() end)
                        if not hidden and not compName:find("Collision", 1, true) then
                            local eb = c.StaticMesh.ExtendedBounds
                            if eb.BoxExtent and eb.Origin then
                                local rs = c.RelativeScale3D
                                local rl = c.RelativeLocation
                                local sx = math.abs(rs and (tonumber(rs.X) or 1.0) or 1.0)
                                local sy = math.abs(rs and (tonumber(rs.Y) or 1.0) or 1.0)
                                local lx = rl and (tonumber(rl.X) or 0.0) or 0.0
                                local ly = rl and (tonumber(rl.Y) or 0.0) or 0.0
                                local ox = (tonumber(eb.Origin.X) or 0.0) * sx + lx
                                local oy = (tonumber(eb.Origin.Y) or 0.0) * sy + ly
                                local ex = math.abs(tonumber(eb.BoxExtent.X) or 0.0) * sx
                                local ey = math.abs(tonumber(eb.BoxExtent.Y) or 0.0) * sy
                                if ex > 5.0 and ey > 5.0 then
                                    any = true
                                    if ox - ex < minX then minX = ox - ex end
                                    if ox + ex > maxX then maxX = ox + ex end
                                    if oy - ey < minY then minY = oy - ey end
                                    if oy + ey > maxY then maxY = oy + ey end
                                end
                            end
                        end
                    end
                end)
                if any then
                    cx = math.max(1, math.floor((maxX - minX) / 100.0 + 0.45))
                    cy = math.max(1, math.floor((maxY - minY) / 100.0 + 0.45))
                end
            end
        end)
    end

    if not cx or not cy then
        local cat = Core.IsValidObj(machine) and StationData.GetMachineCategory(machine) or "Other"
        if cat == "Assembler" then cx, cy = 3, 3
        elseif cat == "Container" then cx, cy = 1, 1
        else cx, cy = 1, 1 end
    end

    if clsKey then
        CachedFootprintsByClass[clsKey] = { cellsX = cx, cellsY = cy }
    end
    return cx, cy
end

function StationData.PrewarmBuildables(sampleMachine)
    if Core.IsValidObj(sampleMachine) then
        pcall(FindBuildableForMachineClass, sampleMachine)
    end
end

function StationData.GetMachineLocalPosAndYaw(machine, xform)
    return GetMachineLocalPosAndYaw(machine, xform)
end

function StationData.InvalidateMachineCache()
    MachineCacheVersion = MachineCacheVersion + 1
    CachedMachinesByFrame = {}
    CachedStationMachines = { key = nil, time = 0, list = {} }
end

function StationData.InvalidateCaches()
    MachineCacheVersion = MachineCacheVersion + 1
    AsyncFloorBuildGen = AsyncFloorBuildGen + 1
    CachedPlatforms = { key = nil, time = -999, list = {} }
    CachedMachinesByFrame = {}
    CachedStationMachines = { key = nil, time = 0, list = {} }
    CachedFloorMap = nil
    CachedPlayersSnapshot = { time = -999, list = {} }
    CachedWallAnchors = {}
    HiddenMachineIcons = {}
    CachedClasses = {}
    CachedFootprintsByClass = {}
    CachedBlockBoundsByCls = {}
    CachedStationWallsByKey = {}
    CachedMachineCatByCls = {}
    CachedMachineDispByCls = {}
    CachedHideByCls = {}
    CachedIconTexByCls = {}
    CachedBeltTexByCls = {}
    CachedBuildablesByCls = nil
    CachedBuildablesByName = nil
    CachedGameTexList = nil
    MissingIconDiagLogged = {}
    PortDiagLoggedByCls = {}
    BeltMatDiagLogged = false
    UndergroundDiagLogged = false
    StationDiagLoggedKey = nil
end

--------------------------------------------------------------------------------
-- Player Discovery & Online/Offline Status
--------------------------------------------------------------------------------

local function ToLuaString(v)
    if v == nil then return nil end
    if type(v) == "string" then
        return (v ~= "" and not v:match("^FString ") and not v:match("^FText ")) and v or nil
    end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and s ~= "" and not s:match("^FString ") and not s:match("^FText ") then
        return s
    end
    return nil
end

function StationData.GetAllPlayersInfo(localPC, forceRefresh)
    local now = os.clock()
    if not forceRefresh and (now - CachedPlayersSnapshot.time) < 2.0 and #CachedPlayersSnapshot.list > 0 then
        -- Refresh live positions on cached actors without calling FindAllOf
        for _, p in ipairs(CachedPlayersSnapshot.list) do
            if Core.IsValidObj(p.Actor) then
                local okLoc, loc = pcall(function() return p.Actor:K2_GetActorLocation() end)
                if okLoc and loc and type(loc.X) == "number" then
                    p.X, p.Y, p.Z = loc.X, loc.Y or 0, loc.Z or 0
                    p.HasPos = true
                end
            end
        end
        return CachedPlayersSnapshot.list
    end

    local players = {}
    local pc = localPC or Core.GetLocalPlayerController()
    local localPlayerObj = Core.IsValidObj(pc) and pc.PlayerObject or nil
    local localAddr = Core.IsValidObj(localPlayerObj) and localPlayerObj:GetAddress() or nil

    -- Build ConnectedPlayer lookup for nicknames & online status
    local connectedByPlayerAddr = {}
    local connectedById = {}
    local okConn, connList = pcall(FindAllOf, "ConnectedPlayer")
    if okConn and connList then
        for _, cp in ipairs(connList) do
            if Core.IsValidObj(cp) then
                local cpName = nil
                for _, prop in ipairs({ "Nickname", "AccountNickname", "PlayerName", "DisplayName" }) do
                    local okN, n = pcall(function()
                        local v = cp[prop]
                        return (v and type(v.ToString) == "function") and v:ToString() or tostring(v)
                    end)
                    if okN and n and n ~= "" and n ~= "nil" then
                        cpName = n
                        break
                    end
                end
                local po = nil
                pcall(function() po = cp.PlayerObject end)
                if Core.IsValidObj(po) then
                    connectedByPlayerAddr[po:GetAddress()] = { Name = cpName, Connected = cp }
                end
                local pid = nil
                pcall(function() pid = cp.PlayerID or cp.UserID or cp.ID end)
                if pid ~= nil then
                    connectedById[tostring(pid)] = { Name = cpName, Connected = cp }
                end
            end
        end
    end

    -- Build replicated GameState.PlayerArray lookup (works on both host & MP clients; only contains connected players)
    local onlinePawnAddrs = {}
    local onlinePlayerNames = {}
    if Core.IsValidObj(pc) then
        pcall(function()
            local w = pc:GetWorld()
            local gs = Core.IsValidObj(w) and w.GameState or nil
            if Core.IsValidObj(gs) and gs.PlayerArray then
                StationData.ForEachArray(gs.PlayerArray, function(_, elem)
                    local ps = Core.UnwrapArrayElem(elem)
                    if not Core.IsValidObj(ps) then return end
                    local pawn = nil
                    pcall(function()
                        pawn = ps.PawnPrivate
                        if not Core.IsValidObj(pawn) and ps.GetPawn then
                            pawn = ps:GetPawn()
                        end
                    end)
                    if Core.IsValidObj(pawn) then
                        onlinePawnAddrs[pawn:GetAddress()] = true
                    end
                    local psName = nil
                    pcall(function()
                        if ps.GetPlayerName then
                            psName = ToLuaString(ps:GetPlayerName())
                        end
                    end)
                    if psName and psName ~= "" then
                        onlinePlayerNames[string.lower(psName)] = true
                    end
                end)
            end
        end)
    end

    local okPO, poList = pcall(FindAllOf, "DMSPlayerObject")
    if not okPO or not poList then return players end

    for _, po in ipairs(poList) do
        if Core.IsValidObj(po) then
            local addr = po:GetAddress()
            local isLocal = (localAddr ~= nil and addr == localAddr)
            local connInfo = connectedByPlayerAddr[addr]
            if not connInfo then
                local okUid, uid = pcall(function() return po.UserID or po.ID end)
                if okUid and uid ~= nil then
                    connInfo = connectedById[tostring(uid)]
                end
            end

            -- Determine online status
            local isOnline = isLocal or (connInfo ~= nil)
            if not isOnline then
                for _, prop in ipairs({ "bIsOnline", "bOnline", "bConnected", "bIsConnected" }) do
                    local okB, bVal = pcall(function() return po[prop] end)
                    if okB and type(bVal) == "boolean" then
                        isOnline = bVal
                        break
                    end
                end
            end
            if not isOnline then
                local okCtrl, ctrl = pcall(function() return po.Controller or po.PlayerController end)
                if okCtrl and Core.IsValidObj(ctrl) then
                    isOnline = true
                end
            end

            -- Resolve nickname
            local name = connInfo and ToLuaString(connInfo.Name) or nil
            if (not name or name == "") and isLocal and Core.IsValidObj(pc) then
                local okAcc, acc = pcall(function() return pc:GetAccountNickname() end)
                if okAcc and acc then
                    name = ToLuaString(acc)
                end
            end
            if not name or name == "" then
                for _, prop in ipairs({ "DisplayName", "PlayerName", "Nickname", "AccountNickname" }) do
                    local okN, v = pcall(function() return po[prop] end)
                    if okN and v ~= nil then
                        local s = ToLuaString(v)
                        if s then
                            name = s
                            break
                        end
                    end
                end
            end
            if not name or name == "" then
                name = isLocal and "You" or "Player"
            end

            -- Resolve world position & actor
            local actor = StationData.GetObjectActor(po)
            if not Core.IsValidObj(actor) and isLocal and Core.IsValidObj(pc) then
                local okPawn, pawn = pcall(function() return pc.Pawn end)
                if okPawn and Core.IsValidObj(pawn) then actor = pawn end
            end
            if not Core.IsValidObj(actor) then
                pcall(function() actor = po.Character or po.Pawn end)
            end
            -- Offline players leave their character actor standing in the station, so actor presence
            -- alone does NOT mean online. Check replicated PlayerState/Controller/GameState.PlayerArray instead.
            if not isOnline and Core.IsValidObj(actor) then
                if onlinePawnAddrs[actor:GetAddress()] then
                    isOnline = true
                else
                    local okPS, aPS = pcall(function() return actor.PlayerState end)
                    if okPS and Core.IsValidObj(aPS) then
                        isOnline = true
                    else
                        local okAC, aCtrl = pcall(function()
                            return actor.GetController and actor:GetController() or actor.Controller
                        end)
                        if okAC and Core.IsValidObj(aCtrl) then
                            isOnline = true
                        end
                    end
                end
            end
            if not isOnline and name and name ~= "Player" and name ~= "You" and onlinePlayerNames[string.lower(name)] then
                isOnline = true
            end
            local frame = nil
            pcall(function() frame = po:GetFrame() end)

            local px, py, pz = 0, 0, 0
            local hasPos = false
            if Core.IsValidObj(actor) then
                local okLoc, loc = pcall(function() return actor:K2_GetActorLocation() end)
                if okLoc and loc then
                    px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
                    hasPos = true
                end
            elseif Core.IsValidObj(po.PilotedShip) then
                local shipActor = StationData.GetObjectActor(po.PilotedShip)
                if Core.IsValidObj(shipActor) then
                    local okLoc, loc = pcall(function() return shipActor:K2_GetActorLocation() end)
                    if okLoc and loc then
                        px, py, pz = loc.X or 0, loc.Y or 0, loc.Z or 0
                        hasPos = true
                    end
                end
            end
            if not hasPos and Core.IsValidObj(frame) then
                local okL, loc = pcall(function() return po.Location end)
                if okL and loc ~= nil then
                    -- po.Location is a simulation FFPVector in frame-local meters; convert to world cm
                    -- so WorldToStationLocal callers plot out-of-relevancy MP players accurately.
                    local fx, fy, fz = Core.GetFPVector(loc)
                    if type(fx) == "number" and type(fy) == "number" and type(fz) == "number" then
                        local okX, wx, wy, wz = pcall(function()
                            local xf = StationData.GetStationFrameTransform(frame)
                            return StationData.StationLocalToWorld(xf, fx * 100.0, fy * 100.0, fz * 100.0)
                        end)
                        if okX and type(wx) == "number" and type(wy) == "number" and type(wz) == "number" then
                            px, py, pz = wx, wy, wz
                            hasPos = true
                        end
                    end
                end
            end

            local solarSystemID = nil
            pcall(function()
                local ss = nil
                if po.GetSolarSystem then ss = po:GetSolarSystem() end
                if not Core.IsValidObj(ss) then ss = po.SolarSystem end
                if not Core.IsValidObj(ss) and Core.IsValidObj(frame) then
                    if frame.GetSolarSystem then ss = frame:GetSolarSystem() end
                    if not Core.IsValidObj(ss) then ss = frame.SolarSystem end
                end
                if Core.IsValidObj(ss) then
                    solarSystemID = StationData.GetObjectKey(ss) or tostring(ss:GetAddress())
                else
                    local rawId = po.SolarSystemID or (Core.IsValidObj(frame) and frame.SolarSystemID) or nil
                    if rawId ~= nil then solarSystemID = tostring(rawId) end
                end
            end)

            table.insert(players, {
                Key = StationData.GetObjectKey(po) or tostring(addr),
                PlayerObject = po,
                Actor = actor,
                Name = name,
                IsLocal = isLocal,
                IsOnline = isOnline,
                X = px,
                Y = py,
                Z = pz,
                HasPos = hasPos,
                Frame = frame,
                SolarSystemID = solarSystemID,
                PilotedShip = po.PilotedShip,
            })
        end
    end

    CachedPlayersSnapshot = { time = now, list = players }
    return players
end

return StationData
