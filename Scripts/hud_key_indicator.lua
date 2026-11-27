-- Self-contained HUD Keybind Indicator helper for Main Sequence standalone mods
-- Safely shares the bottom-right HUDInputContainer (row=0, col=1) HorizontalBox across
-- multiple independent mods so each installed mod only renders its own keybind badge.

local Core = require("core")
local StationData = require("station_data")

local HudKeyIndicator = {}

local ICON_PATHS_BY_KIND = {
    Logistics = {
        "/Game/Materials/UI_Textures/T_MatSciIcon.T_MatSciIcon",
        "/Game/Materials/Icons/T_MatSciIcon.T_MatSciIcon",
        "/Game/Textures/Icons/T_MatSciIcon.T_MatSciIcon",
        "/Game/Textures/T_MatSciIcon.T_MatSciIcon",
    },
    Power = {
        "/Game/Materials/Icons/UI/T_UI_Power.T_UI_Power",
        "/Game/Materials/Icons/UI/T_UI_Electricity.T_UI_Electricity",
        "/Game/Materials/Icons/UI/T_UI_Energy.T_UI_Energy",
        "/Game/Materials/Icons/UI/T_UI_Lightning.T_UI_Lightning",
        "/Game/Materials/Icons/UI/T_UI_Bolt.T_UI_Bolt",
        "/Game/Materials/Icons/T_Power.T_Power",
        "/Game/Materials/Icons/T_PowerIcon.T_PowerIcon",
        "/Game/Materials/Icons/T_Electricity.T_Electricity",
        "/Game/Materials/Icons/T_ElectricityIcon.T_ElectricityIcon",
        "/Game/Materials/Icons/T_Energy.T_Energy",
        "/Game/Materials/Icons/T_EnergyIcon.T_EnergyIcon",
        "/Game/Materials/Icons/T_Lightning.T_Lightning",
        "/Game/Materials/UI_Textures/T_Power.T_Power",
        "/Game/Materials/UI_Textures/T_PowerIcon.T_PowerIcon",
        "/Game/Materials/UI_Textures/T_Electricity.T_Electricity",
        "/Game/Materials/UI_Textures/T_ElectricityIcon.T_ElectricityIcon",
        "/Game/Materials/UI_Textures/T_Energy.T_Energy",
        "/Game/Materials/UI_Textures/T_EnergyIcon.T_EnergyIcon",
        "/Game/Textures/Icons/T_PowerIcon.T_PowerIcon",
        "/Game/Textures/Icons/T_Power.T_Power",
    },
    StationMap = {
        "/Game/Materials/Icons/UI/T_UI_StationIcon.T_UI_StationIcon",
        "/Game/Materials/UI_Textures/T_StationMapIcon.T_StationMapIcon",
        "/Game/Materials/UI_Textures/T_StationIcon.T_StationIcon",
        "/Game/Materials/Icons/T_StationIcon.T_StationIcon",
        "/Game/Materials/UI_Textures/T_MapIcon.T_MapIcon",
        "/Game/Materials/Icons/T_MapIcon.T_MapIcon",
    },
}

local function GetFormattedKeybind(configKey, defaultKey)
    local raw = tostring(Core.Config[configKey] or defaultKey or "")
    local keyStr = (Core.FormatKeyLabel and Core.FormatKeyLabel(raw)) or raw
    if keyStr == "" then keyStr = defaultKey or "" end
    return keyStr
end

local function FindSharedIconsHBox(container)
    if not Core.IsValidObj(container) or not container.GetChildrenCount or not container.GetChildAt then
        return nil
    end
    local okN, count = pcall(function() return tonumber(container:GetChildrenCount()) or 0 end)
    if not okN or count <= 0 then return nil end
    for i = 0, count - 1 do
        local foundHBox = nil
        pcall(function()
            local child = container:GetChildAt(i)
            if not Core.IsValidObj(child) then return end
            local slot = child.Slot
            if not Core.IsValidObj(slot) then return end
            local r = tonumber(slot.Row)
            local c = tonumber(slot.Column)
            if r ~= 0 or c ~= 1 then return end
            -- Expect our 1x1 SizeBox -> CanvasPanel -> HorizontalBox structure
            local cn = child:GetClass():GetFName():ToString()
            if cn ~= "SizeBox" then return end
            if child.GetChildAt then
                local canvas = child:GetChildAt(0)
                if Core.IsValidObj(canvas) and canvas:GetClass():GetFName():ToString() == "CanvasPanel" and canvas.GetChildAt then
                    local hbox = canvas:GetChildAt(0)
                    if Core.IsValidObj(hbox) and hbox:GetClass():GetFName():ToString() == "HorizontalBox" then
                        foundHBox = hbox
                    end
                end
            end
        end)
        if Core.IsValidObj(foundHBox) then
            return foundHBox
        end
    end
    return nil
end

local function ReadHudRowMetrics(hud)
    local refWidget = nil
    for _, prop in ipairs({ "InventoryInput", "BuildingInput", "DisassembleInput", "MapInput" }) do
        local okW, w = pcall(function() return hud[prop] end)
        if okW and Core.IsValidObj(w) and Core.IsValidObj(w.Slot) then
            refWidget = w
            break
        end
    end
    local refSlot = Core.IsValidObj(refWidget) and refWidget.Slot or nil

    local padL, padR, padT, padB = 4.0, 4.0, 0.0, 0.0
    local nudgeX, nudgeY = 0.0, 0.0
    local refVAlign = 2
    if Core.IsValidObj(refSlot) then
        pcall(function()
            local p = refSlot.Padding
            if p then
                padL = tonumber(p.Left) or padL
                padR = tonumber(p.Right) or padR
                padT = tonumber(p.Top) or padT
                padB = tonumber(p.Bottom) or padB
            end
            if refSlot.Nudge then
                nudgeX = tonumber(refSlot.Nudge.X) or 0.0
                nudgeY = tonumber(refSlot.Nudge.Y) or 0.0
            end
            if type(refSlot.VerticalAlignment) == "number" then
                refVAlign = refSlot.VerticalAlignment
            end
        end)
    end
    if nudgeX == 0.0 and Core.IsValidObj(refWidget) then
        pcall(function()
            local rt = refWidget.RenderTransform
            if rt and rt.Translation then
                nudgeX = tonumber(rt.Translation.X) or 0.0
            end
        end)
    end
    if math.abs(nudgeX) < 0.5 then
        nudgeX = 22.0
    end
    return padL, padR, padT, padB, nudgeX, nudgeY, refVAlign
end

function HudKeyIndicator.Create(def)
    local inst = {}
    local trackedByHud = {} -- hudAddr -> { Icon, IconAddr, KeyText, LastVis, LastKeyStr }
    local cachedTex = nil
    local texCooldown = nil
    local pollActive = false
    local initialScanDone = false

    local function FindIconTexture(hud)
        if Core.IsValidObj(cachedTex) then return cachedTex end
        local now = os.clock()
        if texCooldown and (now - texCooldown) < 8.0 then return nil end

        local tex = nil
        for _, tPath in ipairs(ICON_PATHS_BY_KIND[def.Kind] or {}) do
            local candidate = Core.FindOrLoadClass(tPath)
            if Core.IsValidObj(candidate) then
                tex = candidate
                break
            end
        end
        if not Core.IsValidObj(tex) and Core.IsValidObj(hud) then
            if def.Kind == "StationMap" and Core.IsValidObj(hud.MapInput) then
                pcall(function() tex = hud.MapInput.Icon end)
            elseif def.Kind ~= "Power" and Core.IsValidObj(hud.ResearchInput) then
                pcall(function() tex = hud.ResearchInput.Icon end)
            end
        end
        if Core.IsValidObj(tex) then
            cachedTex = tex
            texCooldown = nil
        else
            texCooldown = now
        end
        return tex
    end

    local function ShouldShowIndicator()
        local pc = Core.GetLocalPlayerController()
        if not Core.IsValidObj(pc) then return false end
        local playerObj = pc.PlayerObject
        local piloting = Core.IsValidObj(playerObj) and Core.IsValidObj(playerObj.PilotedShip)
        if piloting then return false end
        local inStation = StationData.IsPlayerInStation(pc)
        return inStation == true
    end

    local function StartPoll()
        if pollActive then return end
        pollActive = true

        local function Tick()
            local anyValid = false
            local show = ShouldShowIndicator()
            local targetVis = show and 0 or 1 -- Visible or Collapsed
            local keyStr = GetFormattedKeybind(def.ConfigKey, def.DefaultKey)

            for addr, entry in pairs(trackedByHud) do
                if Core.IsValidObj(entry.Icon) then
                    anyValid = true
                    if entry.LastVis ~= targetVis then
                        entry.LastVis = targetVis
                        pcall(function() entry.Icon:SetVisibility(targetVis) end)
                    end
                    if show and Core.IsValidObj(entry.KeyText) and entry.LastKeyStr ~= keyStr then
                        entry.LastKeyStr = keyStr
                        pcall(function() entry.KeyText:SetText(Core.MakeText(keyStr)) end)
                    end
                else
                    trackedByHud[addr] = nil
                end
            end

            if anyValid then
                ExecuteInGameThreadWithDelay(1200, Tick)
            else
                pollActive = false
            end
        end

        ExecuteInGameThreadWithDelay(1200, Tick)
    end

    function inst.EnsureForHud(hud)
        if not Core.IsValidObj(hud) then return end
        local addr = hud:GetAddress()
        if trackedByHud[addr] and Core.IsValidObj(trackedByHud[addr].Icon) then
            StartPoll()
            return
        end

        local container = hud.HUDInputContainer
        if not Core.IsValidObj(container) then return end

        local okPC, owningPC = pcall(function() return hud:GetOwningPlayer() end)
        local pc = (okPC and Core.IsValidObj(owningPC)) and owningPC or Core.GetLocalPlayerController()
        local outer = Core.GetWidgetOuter(hud)
        local padL, padR, padT, padB, nudgeX, nudgeY, refVAlign = ReadHudRowMetrics(hud)

        -- Reuse the shared HorizontalBox at Grid (0, 1) if another standalone mod already created it
        local iconsHBox = FindSharedIconsHBox(container)
        if not Core.IsValidObj(iconsHBox) then
            local hostSizeBox = Core.CreateRawWidget(Core.PATHS.SizeBoxClass, outer)
            local hostCanvas = Core.CreateRawWidget("/Script/UMG.CanvasPanel", outer)
            iconsHBox = Core.CreateRawWidget(Core.PATHS.HorizontalBoxClass, outer)
            if not (Core.IsValidObj(hostSizeBox) and Core.IsValidObj(hostCanvas) and Core.IsValidObj(iconsHBox)) then
                return
            end
            pcall(function()
                hostSizeBox:SetWidthOverride(1.0)
                hostSizeBox:SetHeightOverride(1.0)
                if hostSizeBox.SetClipping then hostSizeBox:SetClipping(0) end
                if hostCanvas.SetClipping then hostCanvas:SetClipping(0) end
            end)
            hostSizeBox:AddChild(hostCanvas)

            local cSlot = hostCanvas:AddChildToCanvas(iconsHBox)
            if Core.IsValidObj(cSlot) then
                pcall(function()
                    cSlot:SetAnchors({ Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } })
                    cSlot:SetAlignment({ X = 1.0, Y = 0.5 })
                    cSlot:SetAutoSize(true)
                    cSlot:SetPosition({ X = nudgeX, Y = nudgeY })
                end)
            end

            local gSlot = container:AddChildToGrid(hostSizeBox, 0, 1)
            if Core.IsValidObj(gSlot) then
                pcall(function()
                    gSlot:SetPadding({ Left = 0.0, Top = 0.0, Right = 0.0, Bottom = 0.0 })
                    gSlot:SetHorizontalAlignment(3) -- Right
                    gSlot:SetVerticalAlignment(2)   -- Center
                end)
            end
        end

        local inputIconCls = "/Game/Blueprints/Widgets/HUDs/WBP_InputIcon.WBP_InputIcon_C"
        local iconW = Core.CreateUserWidget(inputIconCls, hud, pc)
        if not Core.IsValidObj(iconW) then return end

        local entry = {
            Icon = iconW,
            IconAddr = iconW:GetAddress(),
            KeyText = nil,
            LastVis = nil,
            LastKeyStr = nil,
        }

        local function ApplyVisuals()
            local tex = FindIconTexture(hud)
            local keyStr = GetFormattedKeybind(def.ConfigKey, def.DefaultKey)
            local show = ShouldShowIndicator()
            pcall(function()
                if Core.IsValidObj(tex) then
                    iconW.Icon = tex
                    if Core.IsValidObj(iconW.Image_82) then
                        iconW.Image_82:SetBrushFromTexture(tex, false)
                    end
                end
                if Core.IsValidObj(iconW.WBP_InputKey) and Core.IsValidObj(iconW.WBP_InputKey.WBP_Text) then
                    entry.KeyText = iconW.WBP_InputKey.WBP_Text
                    entry.KeyText:SetText(Core.MakeText(keyStr))
                    entry.LastKeyStr = keyStr
                end
                local vis = show and 0 or 1
                iconW:SetVisibility(vis)
                entry.LastVis = vis
            end)
        end

        ApplyVisuals()
        ExecuteInGameThreadAfterFrames(1, function()
            if Core.IsValidObj(iconW) then ApplyVisuals() end
        end)

        local hSlot = iconsHBox:AddChildToHorizontalBox(iconW)
        if Core.IsValidObj(hSlot) then
            pcall(function()
                hSlot:SetPadding({ Left = padL, Top = padT, Right = padR, Bottom = padB })
                hSlot:SetVerticalAlignment(refVAlign)
            end)
        end

        trackedByHud[addr] = entry
        StartPoll()
    end

    function inst.UpdateKeyText()
        local keyStr = GetFormattedKeybind(def.ConfigKey, def.DefaultKey)
        for addr, entry in pairs(trackedByHud) do
            if Core.IsValidObj(entry.Icon) then
                pcall(function()
                    local kt = entry.KeyText
                    if not Core.IsValidObj(kt) and Core.IsValidObj(entry.Icon.WBP_InputKey) then
                        kt = entry.Icon.WBP_InputKey.WBP_Text
                        entry.KeyText = kt
                    end
                    if Core.IsValidObj(kt) then
                        kt:SetText(Core.MakeText(keyStr))
                        entry.LastKeyStr = keyStr
                    end
                end)
            else
                trackedByHud[addr] = nil
            end
        end
    end

    function inst.RegisterHooks()
        Core.TryRegisterHook(
            "InputIcon_RefreshVisible_" .. tostring(def.Kind),
            "/Game/Blueprints/Widgets/HUDs/WBP_InputIcon.WBP_InputIcon_C:RefreshVisible",
            function(Context)
                local iconW = Context:get()
                if not Core.IsValidObj(iconW) then return end
                local iconAddr = iconW:GetAddress()
                for _, entry in pairs(trackedByHud) do
                    if entry.IconAddr == iconAddr then
                        pcall(function()
                            local show = ShouldShowIndicator()
                            iconW:SetVisibility(show and 0 or 1)
                            entry.LastVis = show and 0 or 1
                            local kt = entry.KeyText
                            if not Core.IsValidObj(kt) and Core.IsValidObj(iconW.WBP_InputKey) then
                                kt = iconW.WBP_InputKey.WBP_Text
                                entry.KeyText = kt
                            end
                            if Core.IsValidObj(kt) then
                                local keyStr = GetFormattedKeybind(def.ConfigKey, def.DefaultKey)
                                kt:SetText(Core.MakeText(keyStr))
                                entry.LastKeyStr = keyStr
                            end
                        end)
                        return
                    end
                end
            end
        )

        Core.TryRegisterHook(
            "CharacterHUD_RefreshKeybinds_" .. tostring(def.Kind),
            "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C:RefreshKeybinds",
            function(Context)
                local hud = Context:get()
                if Core.IsValidObj(hud) then
                    inst.EnsureForHud(hud)
                    inst.UpdateKeyText()
                end
            end
        )

        if not initialScanDone then
            initialScanDone = true
            local okH, hud = pcall(FindFirstOf, "WBP_CharacterHUD_C")
            if okH and Core.IsValidObj(hud) then
                inst.EnsureForHud(hud)
            end
        end
    end

    function inst.PruneCaches()
        for addr, entry in pairs(trackedByHud) do
            if not Core.IsValidObj(entry.Icon) then
                trackedByHud[addr] = nil
            end
        end
    end

    return inst
end

return HudKeyIndicator
