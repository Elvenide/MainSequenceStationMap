-- Elvenide's Station Map - Core Utilities & Feature Registry
-- 100% client-side / save-safe: does not modify world saves, pak files, or serialized objects.

local Core = {}

Core.VERSION = "0.1.1"

-- Shared Unreal Engine UMG enum constants (replaces magic integer literals across features)
Core.VIS = {
    Visible              = 0, -- ESlateVisibility::Visible
    Collapsed            = 1, -- ESlateVisibility::Collapsed (no layout space)
    Hidden               = 2, -- ESlateVisibility::Hidden (reserves layout space)
    HitTestInvisible     = 3, -- ESlateVisibility::HitTestInvisible (visible, passes clicks through)
    SelfHitTestInvisible = 4, -- ESlateVisibility::SelfHitTestInvisible (children still clickable)
}

Core.ALIGN = {
    Fill   = 0, -- HAlign_Fill / VAlign_Fill
    Left   = 1, -- HAlign_Left
    Top    = 1, -- VAlign_Top
    Center = 2, -- HAlign_Center / VAlign_Center
    Right  = 3, -- HAlign_Right
    Bottom = 3, -- VAlign_Bottom
}

Core.SIZE_RULE = {
    Auto = 0, -- ESlateSizeRule::Automatic
    Fill = 1, -- ESlateSizeRule::Fill
}

Core.PATHS = {
    PlayerControllerClass = "/Game/Blueprints/Player/BP_PlayerController.BP_PlayerController_C",
    WidgetSubsystemClass  = "/Script/MainSequence.WidgetSubsystem",
    WorldSubsystemClass   = "/Script/MainSequence.DMSWorldSubsystem",
    SubsystemLibCDO       = "/Script/Engine.Default__SubsystemBlueprintLibrary",
    WidgetBlueprintLibCDO = "/Script/UMG.Default__WidgetBlueprintLibrary",
    WidgetLayoutLibCDO    = "/Script/UMG.Default__WidgetLayoutLibrary",
    KismetTextLibCDO      = "/Script/Engine.Default__KismetTextLibrary",
    EnhancedInputLibCDO   = "/Script/EnhancedInput.Default__EnhancedInputLibrary",
    FPMathCDO             = "/Script/MainSequence.Default__FPMath",
    VerticalBoxClass      = "/Script/UMG.VerticalBox",
    HorizontalBoxClass    = "/Script/UMG.HorizontalBox",
    SizeBoxClass          = "/Script/UMG.SizeBox",
}

Core.Config = {}

local RegisteredHookAddresses = {}
local Features = {}
local WatchedWidgetClasses = {}
local RegisteredKeybinds = {}
local TrackedTextInputs = {}

function Core.Log(msg)
    print(string.format("[StationMap] %s\n", tostring(msg)))
end

function Core.IsValidObj(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function()
        return type(obj.IsValid) == "function" and obj:IsValid()
    end)
    return ok and valid == true
end

function Core.UnwrapArrayElem(elem)
    if elem == nil then return nil end
    if Core.IsValidObj(elem) then return elem end
    local ok, val = pcall(function() return elem:get() end)
    if ok and Core.IsValidObj(val) then return val end
    return nil
end

function Core.UnwrapStruct(val)
    if val == nil then return nil end
    local ok, inner = pcall(function()
        if type(val.get) == "function" then
            return val:get()
        end
        return val
    end)
    if ok and inner ~= nil then return inner end
    return val
end

function Core.Clamp(val, lo, hi)
    if type(val) ~= "number" or val ~= val then return lo end
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

function Core.FindOrLoadClass(path)
    local cls = StaticFindObject(path)
    if Core.IsValidObj(cls) then return cls end
    local ok, loaded = pcall(LoadAsset, path)
    if ok and Core.IsValidObj(loaded) then return loaded end
    return StaticFindObject(path)
end

function Core.GetCDO(path)
    return StaticFindObject(path)
end

function Core.GetFPFloat(fpNum)
    if not fpNum then return 0.0 end
    if type(fpNum) == "number" then return fpNum end
    if type(fpNum) ~= "userdata" then return 0.0 end
    local okV, raw = pcall(function() return fpNum.Value end)
    if okV and type(raw) == "number" then
        return raw / 65536.0
    end
    return 0.0
end

function Core.GetFPVector(fpVec)
    if not fpVec then return 0.0, 0.0, 0.0 end
    if type(fpVec.X) == "number" and type(fpVec.Y) == "number" then
        return fpVec.X, fpVec.Y, tonumber(fpVec.Z) or 0.0
    end
    if type(fpVec) ~= "userdata" then return 0.0, 0.0, 0.0 end
    local okV, x, y, z = pcall(function()
        return Core.GetFPFloat(fpVec.X), Core.GetFPFloat(fpVec.Y), Core.GetFPFloat(fpVec.Z)
    end)
    if okV and type(x) == "number" and type(y) == "number" then
        return x, y, tonumber(z) or 0.0
    end
    return 0.0, 0.0, 0.0
end

function Core.MakeText(str)
    local ktl = Core.GetCDO(Core.PATHS.KismetTextLibCDO)
    if Core.IsValidObj(ktl) then
        local ok, txt = pcall(function() return ktl:Conv_StringToText(str) end)
        if ok and txt then return txt end
    end
    return FText(str)
end

function Core.GetModDir()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local modDir = src:match("^(.*)[/\\]Scripts[/\\][^/\\]+$")
    return (modDir and modDir ~= "") and modDir or "."
end

function Core.GetConfigPath()
    return Core.GetModDir() .. "/config.json"
end

local CachedConfigDiskValues = nil

function Core.WriteConfig()
    local path = Core.GetConfigPath()
    local f = io.open(path, "w")
    if not f then
        Core.Log("Warning: could not write config file at " .. path)
        return
    end

    local keys = {}
    for k in pairs(Core.Config) do
        table.insert(keys, k)
    end
    table.sort(keys)

    local lines = { "{" }
    for idx, k in ipairs(keys) do
        local v = Core.Config[k]
        local safeKey = tostring(k):gsub('[\\"]', "")
        local serialized
        if type(v) == "boolean" then
            serialized = v and "true" or "false"
        elseif type(v) == "number" then
            serialized = tostring(v)
        else
            serialized = string.format('"%s"', tostring(v):gsub('[\\"]', ""))
        end
        local comma = (idx < #keys) and "," or ""
        table.insert(lines, string.format('    "%s": %s%s', safeKey, serialized, comma))
    end
    table.insert(lines, "}")

    f:write(table.concat(lines, "\n") .. "\n")
    f:close()

    CachedConfigDiskValues = {}
    for k, v in pairs(Core.Config) do
        CachedConfigDiskValues[k] = v
    end
end

local function ParseConfigRaw(raw)
    local parsed = {}
    if type(raw) ~= "string" or raw == "" then return parsed end
    for k, v in raw:gmatch('"([^"]+)"%s*:%s*([^,\r\n}]+)') do
        local trimmed = v:match("^%s*(.-)%s*$")
        if trimmed == "true" then
            parsed[k] = true
        elseif trimmed == "false" then
            parsed[k] = false
        else
            local sVal = trimmed:match('^"(.*)"$')
            if sVal ~= nil then
                parsed[k] = sVal
            else
                local nVal = tonumber(trimmed)
                if nVal ~= nil then
                    parsed[k] = nVal
                end
            end
        end
    end
    return parsed
end

function Core.ReadConfig(defaults)
    local diskValues = CachedConfigDiskValues
    if diskValues == nil then
        local path = Core.GetConfigPath()
        local f = io.open(path, "r")
        if not f then
            if defaults then
                for k, v in pairs(defaults) do
                    if Core.Config[k] == nil then
                        Core.Config[k] = v
                    end
                end
            end
            Core.WriteConfig()
            return
        end
        local raw = f:read("*a") or ""
        f:close()

        -- Parse ALL keys currently in config.json once and merge unknown keys into Core.Config
        -- BEFORE checking dirty/writing, so incremental feature registration never wipes
        -- saved keys belonging to features that haven't called Core.ReadConfig yet.
        diskValues = ParseConfigRaw(raw)
        CachedConfigDiskValues = diskValues
        for k, diskVal in pairs(diskValues) do
            if Core.Config[k] == nil then
                Core.Config[k] = diskVal
            end
        end
    end

    local dirty = false
    local keysToCheck = defaults or Core.Config
    for k, defaultVal in pairs(keysToCheck) do
        if Core.Config[k] == nil then
            Core.Config[k] = defaultVal
        end
        local diskVal = diskValues[k]
        if type(defaultVal) == "boolean" then
            if type(diskVal) == "boolean" then
                Core.Config[k] = diskVal
            else
                Core.Config[k] = defaultVal
                dirty = true
            end
        elseif type(defaultVal) == "number" then
            if type(diskVal) == "number" then
                Core.Config[k] = diskVal
            else
                Core.Config[k] = defaultVal
                dirty = true
            end
        else
            if type(diskVal) == "string" and diskVal ~= "" then
                Core.Config[k] = diskVal
            else
                Core.Config[k] = defaultVal
                dirty = true
            end
        end
    end

    if dirty then
        Core.WriteConfig()
    end
end

local CachedLocalPC = nil
local LastSettingsMenuSyncClock = {}

function Core.SetLocalPlayerController(pc)
    if Core.IsValidObj(pc) then
        CachedLocalPC = pc
    end
end

function Core.GetLocalPlayerController()
    if Core.IsValidObj(CachedLocalPC) then
        local okLocal, isLocal = pcall(function() return CachedLocalPC:IsLocalPlayerController() end)
        if okLocal and isLocal then
            return CachedLocalPC
        end
        CachedLocalPC = nil
    end

    -- Fast singleton lookup first (avoids scanning all PlayerControllers in singleplayer/most sessions)
    for _, clsName in ipairs({ "BP_PlayerController_C", "PlayerController" }) do
        local okF, first = pcall(FindFirstOf, clsName)
        if okF and Core.IsValidObj(first) then
            local okL, isL = pcall(function() return first:IsLocalPlayerController() end)
            if okL and isL then
                CachedLocalPC = first
                return first
            end
        end
    end

    -- Multiplayer fallback when another client's PlayerController appears first in GUObjectArray
    for _, clsName in ipairs({ "BP_PlayerController_C", "PlayerController" }) do
        local ok, list = pcall(FindAllOf, clsName)
        if ok and list then
            for _, pc in ipairs(list) do
                if Core.IsValidObj(pc) then
                    local okLocal, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
                    if okLocal and isLocal then
                        CachedLocalPC = pc
                        return pc
                    end
                end
            end
        end
    end
    return nil
end

function Core.GetWorldSubsystem(worldContext, classPath)
    local subLib = Core.GetCDO(Core.PATHS.SubsystemLibCDO)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(subLib) or not Core.IsValidObj(cls) or not Core.IsValidObj(worldContext) then
        return nil
    end
    local ok, sub = pcall(function() return subLib:GetWorldSubsystem(worldContext, cls) end)
    if ok and Core.IsValidObj(sub) then
        return sub
    end
    return nil
end

local TrackedWidgetsByClass = {} -- shortClassName -> { [addr] = widget }
local SeededWidgetClasses = {}   -- shortClassName -> true

local CORE_WATCHED_MODAL_CLASSES = {
    "WBP_SettingsMenu_C",
    "WBP_PauseMenu_C",
    "WBP_MainMenu_C",
    "WBP_Chat_C",
    "WBP_TextInput_C",
}

-- Exact Blueprint class paths for targeted NotifyOnNewObject registration.
-- Avoids intercepting every UUserWidget constructed in the entire game!
local WATCHED_WIDGET_CLASS_PATHS = {
    WBP_SettingsMenu_C      = "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C",
    WBP_MainMenu_C          = "/Game/Blueprints/Widgets/Menus/WBP_MainMenu.WBP_MainMenu_C",
    WBP_PauseMenu_C         = "/Game/Blueprints/Widgets/Menus/WBP_PauseMenu.WBP_PauseMenu_C",
    WBP_CharacterHUD_C      = "/Game/Blueprints/Widgets/HUDs/WBP_CharacterHUD.WBP_CharacterHUD_C",
    WBP_DesignerHUD_C       = "/Game/Blueprints/Widgets/HUDs/Designer/WBP_DesignerHUD.WBP_DesignerHUD_C",
    WBP_PlayerAlerts_C      = "/Game/Blueprints/Widgets/HUDs/WBP_PlayerAlerts.WBP_PlayerAlerts_C",
    WBP_Chat_C              = "/Game/Blueprints/Widgets/HUDs/WBP_Chat.WBP_Chat_C",
    WBP_PowerOverview_C     = "/Game/Blueprints/Widgets/Windows/WBP_PowerOverview.WBP_PowerOverview_C",
    WBP_ResearchTree_2_C    = "/Game/Blueprints/Widgets/Windows/WBP_ResearchTree_2.WBP_ResearchTree_2_C",
    WBP_CodexContent_C      = "/Game/Blueprints/Widgets/Display/Codex/WBP_CodexContent.WBP_CodexContent_C",
    WBP_TextInput_C         = "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C",
}

local TargetedWidgetWatchersRegistered = {} -- classPath -> true

local function TrackWidgetInstance(shortClassName, widget)
    if not shortClassName or not Core.IsValidObj(widget) then return end
    local bucket = TrackedWidgetsByClass[shortClassName]
    if not bucket then
        bucket = {}
        TrackedWidgetsByClass[shortClassName] = bucket
    end
    bucket[widget:GetAddress()] = widget
end

local function EnsureModalWidgetWatchers()
    for _, clsName in ipairs(CORE_WATCHED_MODAL_CLASSES) do
        WatchedWidgetClasses[clsName] = WatchedWidgetClasses[clsName] or {}
        local key = "__core_track_" .. clsName
        if not WatchedWidgetClasses[clsName][key] then
            WatchedWidgetClasses[clsName][key] = true
            table.insert(WatchedWidgetClasses[clsName], function(w)
                TrackWidgetInstance(clsName, w)
            end)
        end
    end
end

function Core.RegisterTargetedWidgetWatchers()
    EnsureModalWidgetWatchers()
    for clsName, _ in pairs(WatchedWidgetClasses) do
        local clsPath = WATCHED_WIDGET_CLASS_PATHS[clsName]
        if clsPath and not TargetedWidgetWatchersRegistered[clsPath] then
            TargetedWidgetWatchersRegistered[clsPath] = true
            local targetShort = clsName
            pcall(NotifyOnNewObject, clsPath, function(widget)
                if not Core.IsValidObj(widget) then return end
                if IsInGameThread() then
                    ExecuteInGameThreadAfterFrames(1, function()
                        if Core.IsValidObj(widget) then
                            Core.DispatchWidgetConstructed(widget, targetShort)
                        end
                    end)
                else
                    ExecuteInGameThread(function()
                        if Core.IsValidObj(widget) then
                            Core.DispatchWidgetConstructed(widget, targetShort)
                        end
                    end)
                end
            end)
        end
    end
end

local function GetTrackedWidgetsOfClass(shortClassName)
    local bucket = TrackedWidgetsByClass[shortClassName]
    if not SeededWidgetClasses[shortClassName] then
        SeededWidgetClasses[shortClassName] = true
        bucket = bucket or {}
        TrackedWidgetsByClass[shortClassName] = bucket
        local ok, widgets = pcall(FindAllOf, shortClassName)
        if ok and widgets then
            for _, w in ipairs(widgets) do
                if Core.IsValidObj(w) then
                    bucket[w:GetAddress()] = w
                end
            end
        end
    end
    return bucket
end

function Core.IsAnyWidgetClassVisible(shortClassName)
    local isTrackedClass = (WatchedWidgetClasses[shortClassName] ~= nil)
    if isTrackedClass then
        local bucket = GetTrackedWidgetsOfClass(shortClassName)
        if not bucket then return false end
        for addr, w in pairs(bucket) do
            if not Core.IsValidObj(w) then
                bucket[addr] = nil
            else
                local okInVp, inVp = pcall(function() return w:IsInViewport() end)
                local okVis, vis = pcall(function() return w:IsVisible() end)
                if okInVp and inVp and okVis and vis then
                    return true
                end
            end
        end
        return false
    end

    -- Non-tracked singleton modal popups (only queried on hotkey press): use FindFirstOf instead of FindAllOf
    local ok, w = pcall(FindFirstOf, shortClassName)
    if not ok or not Core.IsValidObj(w) then return false end
    local okInVp, inVp = pcall(function() return w:IsInViewport() end)
    local okVis, vis = pcall(function() return w:IsVisible() end)
    return (okInVp and inVp and okVis and vis) == true
end

-- Returns true if any blocking UI menu, modal popup, chat, keybind selector, or native CurrentWindow is open.
function Core.IsAnyBlockingMenuOpen(pc)
    if Core.IsSelectingAnyRegisteredKeybind and Core.IsSelectingAnyRegisteredKeybind() then
        return true
    end
    for _, clsName in ipairs({
        "WBP_SettingsMenu_C",
        "WBP_PauseMenu_C",
        "WBP_MainMenu_C",
        "WBP_ConfirmationPopup_C",
        "WBP_Confirmation_Popup_C",
        "WBP_RenamePopup_C",
        "WBP_ElevatorConfig_C",
    }) do
        if Core.IsAnyWidgetClassVisible(clsName) then
            return true
        end
    end
    local curPC = Core.IsValidObj(pc) and pc or Core.GetLocalPlayerController()
    if Core.IsValidObj(curPC) then
        local widgetSub = Core.GetWorldSubsystem(curPC, Core.PATHS.WidgetSubsystemClass)
        if Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow) then
            return true
        end
    end
    if Core.IsAnyTextInputFocused and Core.IsAnyTextInputFocused() then
        return true
    end
    return false
end

function Core.CreateRawWidget(classPath, outer)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(cls) or not Core.IsValidObj(outer) then return nil end
    local ok, widget = pcall(StaticConstructObject, cls, outer)
    if ok and Core.IsValidObj(widget) then return widget end
    return nil
end

function Core.CreateUserWidget(classPath, worldContext, owningPC)
    local wbl = Core.GetCDO(Core.PATHS.WidgetBlueprintLibCDO)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(wbl) or not Core.IsValidObj(cls) or not Core.IsValidObj(worldContext) then
        return nil
    end
    local ok, widget = pcall(function() return wbl:Create(worldContext, cls, owningPC) end)
    if ok and Core.IsValidObj(widget) then
        return widget
    end
    return nil
end

function Core.GetWidgetOuter(parentWidget)
    if Core.IsValidObj(parentWidget.WidgetTree) then
        return parentWidget.WidgetTree
    end
    return parentWidget
end

local VerifiedHooksThisMap = {} -- hookKey -> true (cleared on DispatchMapLoad for /Game/ Blueprint hooks)

function Core.TryRegisterHook(hookKey, ufuncPath, callbackFn)
    local isBP = (type(ufuncPath) == "string" and ufuncPath:sub(1, 6) == "/Game/")
    if RegisteredHookAddresses[hookKey] and (not isBP or VerifiedHooksThisMap[hookKey]) then
        return true
    end
    local ufunc = StaticFindObject(ufuncPath)
    if not Core.IsValidObj(ufunc) then return false end

    local addr = ufunc:GetAddress()
    if RegisteredHookAddresses[hookKey] == addr then
        VerifiedHooksThisMap[hookKey] = true
        return true
    end
    local ok = pcall(RegisterHook, ufuncPath, callbackFn)
    if ok then
        RegisteredHookAddresses[hookKey] = addr
        VerifiedHooksThisMap[hookKey] = true
        return true
    end
    return false
end

local FeatureToggles = {}
local FeatureToggleByName = {}

function Core.IsFeatureEnabled(name)
    return true
end

function Core.SetFeatureEnabled(name, enabled)
    if not name then return end
    local val = (enabled == true)
    local cfgKey = "Enable_" .. name
    if Core.Config[cfgKey] == val then return end
    Core.Config[cfgKey] = val
    Core.WriteConfig()
    local entry = FeatureToggleByName[name]
    if entry and entry.Feature then
        if val and type(entry.Feature.RegisterHooks) == "function" then
            pcall(entry.Feature.RegisterHooks, Core)
        end
        if type(entry.Feature.OnToggle) == "function" then
            local ok, err = pcall(entry.Feature.OnToggle, val)
            if not ok then
                Core.Log(string.format("[EqolSettings] OnToggle(%s, %s) err: %s", tostring(name), tostring(val), tostring(err)))
            end
        end
    end
end

function Core.GetToggleableFeatures()
    return FeatureToggles
end

function Core.RegisterToggleableOption(opts)
    if type(opts) ~= "table" or not opts.Name then return end
    if FeatureToggleByName[opts.Name] then return end
    local cfgKey = "Enable_" .. opts.Name
    Core.ReadConfig({ [cfgKey] = true })
    local entry = {
        Name        = opts.Name,
        DisplayName = opts.DisplayName or opts.Name,
        Description = opts.Description or "",
        ConfigKey   = cfgKey,
        Feature     = { OnToggle = opts.OnToggle },
    }
    table.insert(FeatureToggles, entry)
    FeatureToggleByName[opts.Name] = entry
end

function Core.RegisterFeature(feature)
    if type(feature) ~= "table" then return end
    table.insert(Features, feature)
    if feature.Name and feature.Toggleable ~= false then
        local cfgKey = "Enable_" .. feature.Name
        Core.ReadConfig({ [cfgKey] = true })
        local entry = {
            Name        = feature.Name,
            DisplayName = feature.DisplayName or feature.Name,
            Description = feature.Description or "",
            ConfigKey   = cfgKey,
            Feature     = feature,
        }
        table.insert(FeatureToggles, entry)
        FeatureToggleByName[feature.Name] = entry
    end
    if type(feature.WatchWidgets) == "table" then
        for clsName, handler in pairs(feature.WatchWidgets) do
            WatchedWidgetClasses[clsName] = WatchedWidgetClasses[clsName] or {}
            table.insert(WatchedWidgetClasses[clsName], handler)
        end
    end
end

function Core.InitAll()
    for _, feature in ipairs(Features) do
        if type(feature.Init) == "function" then
            feature.Init(Core)
        end
    end
    if next(RegisteredKeybinds) ~= nil then EnsureModalWidgetWatchers() end
end

function Core.SpawnActor(worldContext, classPath, loc, rot)
    local cls = Core.FindOrLoadClass(classPath)
    if not Core.IsValidObj(cls) then
        Core.Log("Core.SpawnActor: failed to find/load class " .. tostring(classPath))
        return nil
    end

    local world = nil
    if Core.IsValidObj(worldContext) and worldContext.GetWorld then
        pcall(function() world = worldContext:GetWorld() end)
    end
    if not Core.IsValidObj(world) then
        local pc = Core.GetLocalPlayerController()
        if Core.IsValidObj(pc) and pc.GetWorld then
            pcall(function() world = pc:GetWorld() end)
        end
    end
    if not Core.IsValidObj(world) then
        pcall(function() world = FindFirstOf("World") end)
    end
    if not Core.IsValidObj(world) then
        Core.Log("Core.SpawnActor: no valid UWorld")
        return nil
    end

    local pos = loc or { X = 0.0, Y = 0.0, Z = 0.0 }
    local ang = rot or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }
    local ok, actor = pcall(function() return world:SpawnActor(cls, pos, ang) end)
    if ok and Core.IsValidObj(actor) then
        return actor
    end
    Core.Log("Core.SpawnActor: SpawnActor failed for " .. tostring(classPath))
    return nil
end

function Core.EnsureAllHooks()
    if next(RegisteredKeybinds) ~= nil or next(TrackedTextInputs) ~= nil then Core.EnsureKeybindHooks() end
    for _, feature in ipairs(Features) do
        if type(feature.RegisterHooks) == "function" then
            local isEnabled = (feature.Toggleable == false) or (not feature.Name) or Core.IsFeatureEnabled(feature.Name)
            if isEnabled then
                feature.RegisterHooks(Core)
            end
        end
    end
end

-- TrackedTextInputs forward-declared at top
local TextInputFocusWatcherActive = false
local SuppressedCharacterInput = false
local SuppressedCharacterInputPC = nil

local function ResolveEnclosingUserWidget(widget)
    if not Core.IsValidObj(widget) or not widget.GetOuter then return nil end
    local okO, outer = pcall(function() return widget:GetOuter() end)
    if not okO or not Core.IsValidObj(outer) then return nil end
    if outer.GetOuter then
        local okOO, host = pcall(function() return outer:GetOuter() end)
        if okOO and Core.IsValidObj(host) and host.IsVisible and host:GetAddress() ~= widget:GetAddress() then
            return host
        end
    end
    return nil
end

local function IsWidgetChainVisible(startWidget, depthBudget)
    if not Core.IsValidObj(startWidget) or (depthBudget or 0) <= 0 then return false end

    local cur = startWidget
    local root = startWidget
    for _ = 1, 32 do
        if not Core.IsValidObj(cur) then break end
        local okV, vis = pcall(function() return cur:IsVisible() end)
        if okV and not vis then
            return false
        end
        local okP, parent = pcall(function() return cur:GetParent() end)
        if not okP or not Core.IsValidObj(parent) then
            root = cur
            break
        end
        cur = parent
    end

    -- Child UserWidgets stop their GetParent() chain at their internal WidgetTree root;
    -- walk up to the enclosing host UUserWidget when present before checking IsInViewport().
    local host = ResolveEnclosingUserWidget(root)
    if not Core.IsValidObj(host) and root:GetAddress() ~= startWidget:GetAddress() then
        host = ResolveEnclosingUserWidget(startWidget)
    end
    if Core.IsValidObj(host) then
        return IsWidgetChainVisible(host, (depthBudget or 8) - 1)
    end

    if Core.IsValidObj(root) and root.IsInViewport then
        local okRVP, rInVp = pcall(function() return root:IsInViewport() end)
        if okRVP and not rInVp then return false end
    end
    return true
end

local function IsWidgetTreeVisible(w, ownerWin)
    if not IsWidgetChainVisible(w, 8) then return false end
    if Core.IsValidObj(ownerWin) and not IsWidgetChainVisible(ownerWin, 8) then
        return false
    end
    return true
end

local function IsWidgetOrChildFocused(w, pc)
    if not Core.IsValidObj(w) then return false end
    for _, checkName in ipairs({ "HasKeyboardFocus", "HasAnyUserFocus", "HasFocusedDescendants" }) do
        local ok, res = pcall(function()
            return w[checkName] and w[checkName](w)
        end)
        if ok and res == true then
            return true
        end
    end
    if Core.IsValidObj(pc) then
        for _, pcCheck in ipairs({ "HasUserFocus", "HasUserFocusedDescendants" }) do
            local okU, resU = pcall(function()
                return w[pcCheck] and w[pcCheck](w, pc)
            end)
            if okU and resU == true then
                return true
            end
        end
    end
    return false
end

local function IsWidgetOrBoxHovered(w, box)
    if Core.IsValidObj(w) and w.IsHovered then
        local okH, h = pcall(function() return w:IsHovered() end)
        if okH and h == true then return true end
    end
    if Core.IsValidObj(box) and box.IsHovered then
        local okH, h = pcall(function() return box:IsHovered() end)
        if okH and h == true then return true end
    end
    return false
end

local function IsTrackedInputFocused(entry, pc)
    local w = entry and entry.Input or nil
    if not Core.IsValidObj(w) then return false end
    if not IsWidgetTreeVisible(w, entry.Owner) then return false end
    if entry.ExplicitFocus == true then return true end

    if IsWidgetOrChildFocused(w, pc) then return true end
    local okBox, box = pcall(function() return w.EditableTextBox_80 end)
    if okBox and Core.IsValidObj(box) and IsWidgetOrChildFocused(box, pc) then
        return true
    end
    return false
end

local function IsAnyTrackedTextInputFocused()
    local pc = Core.GetLocalPlayerController()
    for addr, entry in pairs(TrackedTextInputs) do
        if not Core.IsValidObj(entry.Input) then
            TrackedTextInputs[addr] = nil
        elseif IsTrackedInputFocused(entry, pc) then
            return true
        end
    end
    return false
end

local function RestoreSuppressedCharacterInput()
    if not SuppressedCharacterInput then return end
    local pc = Core.IsValidObj(SuppressedCharacterInputPC) and SuppressedCharacterInputPC or Core.GetLocalPlayerController()
    if Core.IsValidObj(pc) then
        pcall(function() pc:AllowCharacterInput(true) end)
    end
    SuppressedCharacterInput = false
    SuppressedCharacterInputPC = nil
end

local function SyncCharacterInputSuppression(precomputedFocused)
    local anyFocused = (precomputedFocused ~= nil) and precomputedFocused or IsAnyTrackedTextInputFocused()
    local pc = Core.GetLocalPlayerController()
    if anyFocused then
        if Core.IsValidObj(pc) and pc.CharacterInputEnabled == true then
            pcall(function() pc:AllowCharacterInput(false) end)
            SuppressedCharacterInput = true
            SuppressedCharacterInputPC = pc
        end
    else
        RestoreSuppressedCharacterInput()
    end
    return anyFocused
end

local KEY_LMB = nil

local function EnsureTextInputFocusWatcher()
    if TextInputFocusWatcherActive then return end
    TextInputFocusWatcherActive = true
    if KEY_LMB == nil then
        pcall(function() KEY_LMB = { KeyName = FName("LeftMouseButton") } end)
    end

    local function WatcherTick()
        if next(TrackedTextInputs) == nil then
            RestoreSuppressedCharacterInput()
            TextInputFocusWatcherActive = false
            return
        end

        local pc = Core.GetLocalPlayerController()
        local mouseDown = false
        if Core.IsValidObj(pc) and KEY_LMB ~= nil then
            local okMD, md = pcall(function()
                return pc:IsInputKeyDown(KEY_LMB)
                    or pc:WasInputKeyJustPressed(KEY_LMB)
            end)
            mouseDown = okMD and md == true
        end

        local anyVisible = false
        local anyFocused = false
        for addr, entry in pairs(TrackedTextInputs) do
            if not Core.IsValidObj(entry.Input) then
                TrackedTextInputs[addr] = nil
            else
                local vis = IsWidgetTreeVisible(entry.Input, entry.Owner)
                if not vis then
                    entry.ExplicitFocus = false
                else
                    anyVisible = true
                    local box = nil
                    pcall(function() box = entry.Input.EditableTextBox_80 end)
                    if IsWidgetOrChildFocused(entry.Input, pc)
                        or (Core.IsValidObj(box) and IsWidgetOrChildFocused(box, pc))
                    then
                        entry.ExplicitFocus = true
                    elseif mouseDown then
                        entry.ExplicitFocus = IsWidgetOrBoxHovered(entry.Input, box)
                    end
                    if entry.ExplicitFocus == true then
                        anyFocused = true
                    end
                end
            end
        end

        SyncCharacterInputSuppression(anyFocused)
        ExecuteInGameThreadWithDelay(anyVisible and 40 or 250, WatcherTick)
    end

    ExecuteInGameThreadWithDelay(40, WatcherTick)
end

function Core.RegisterTextInput(textInputWidget, ownerWindow)
    if not Core.IsValidObj(textInputWidget) then return end
    TrackedTextInputs[textInputWidget:GetAddress()] = {
        Input = textInputWidget,
        Owner = Core.IsValidObj(ownerWindow) and ownerWindow or nil,
        ExplicitFocus = false,
    }
    Core.EnsureKeybindHooks()
    EnsureTextInputFocusWatcher()
end

local function IsAnyClassInstanceFocused(shortClassName, pc)
    if WatchedWidgetClasses[shortClassName] ~= nil then
        local bucket = GetTrackedWidgetsOfClass(shortClassName)
        if not bucket then return false end
        for addr, w in pairs(bucket) do
            if not Core.IsValidObj(w) then
                bucket[addr] = nil
            elseif IsWidgetChainVisible(w, 8) and IsWidgetOrChildFocused(w, pc) then
                return true
            end
        end
        return false
    end

    local ok, list = pcall(FindAllOf, shortClassName)
    if not ok or not list then return false end
    for _, w in ipairs(list) do
        if Core.IsValidObj(w) and IsWidgetChainVisible(w, 8) and IsWidgetOrChildFocused(w, pc) then
            return true
        end
    end
    return false
end

function Core.IsAnyTextInputFocused()
    if IsAnyTrackedTextInputFocused() then
        return true
    end
    if Core.IsAnyWidgetClassVisible("WBP_RenamePopup_C")
        or Core.IsAnyWidgetClassVisible("WBP_ElevatorConfig_C")
    then
        return true
    end
    local chatBucket = GetTrackedWidgetsOfClass("WBP_Chat_C")
    if chatBucket then
        for addr, chat in pairs(chatBucket) do
            if not Core.IsValidObj(chat) then
                chatBucket[addr] = nil
            else
                local okOpen, isOpen = pcall(function() return chat.IsOpen == true end)
                if okOpen and isOpen then
                    return true
                end
            end
        end
    end
    local pc = Core.GetLocalPlayerController()
    if IsAnyClassInstanceFocused("WBP_TextInput_C", pc) then
        return true
    end
    return false
end

local ButtonClickCallbacks = {} -- btnAddr -> { btn = btn, fn = fn }
-- RegisteredKeybinds forward-declared at top

function Core.PruneAllCaches()
    CachedLocalPC = nil
    for addr, entry in pairs(TrackedTextInputs) do
        if not Core.IsValidObj(entry.Input) then
            TrackedTextInputs[addr] = nil
        end
    end
    for addr, entry in pairs(ButtonClickCallbacks) do
        if not entry or not Core.IsValidObj(entry.btn) then
            ButtonClickCallbacks[addr] = nil
        end
    end
    for _, bs in pairs(RegisteredKeybinds) do
        for mAddr, row in pairs(bs.MenuRows) do
            if not Core.IsValidObj(row) then
                bs.MenuRows[mAddr] = nil
            end
        end
        for rAddr, row in pairs(bs.TrackedRows) do
            if not Core.IsValidObj(row) then
                bs.TrackedRows[rAddr] = nil
            end
        end
    end
    for clsName, bucket in pairs(TrackedWidgetsByClass) do
        for addr, w in pairs(bucket) do
            if not Core.IsValidObj(w) then
                bucket[addr] = nil
            end
        end
        SeededWidgetClasses[clsName] = nil
    end
    SuppressedCharacterInput = false
    SuppressedCharacterInputPC = nil
    LastSettingsMenuSyncClock = {}
    for _, feature in ipairs(Features) do
        if type(feature.PruneCaches) == "function" then
            feature.PruneCaches(Core)
        end
    end
end

function Core.DispatchClientRestart()
    Core.PruneAllCaches()
    Core.EnsureAllHooks()
    for _, feature in ipairs(Features) do
        if type(feature.OnClientRestart) == "function" then
            feature.OnClientRestart(Core)
        end
    end
end

function Core.DispatchMapLoad()
    VerifiedHooksThisMap = {}
    Core.PruneAllCaches()
    Core.EnsureAllHooks()
    for _, feature in ipairs(Features) do
        if type(feature.OnMapLoad) == "function" then
            feature.OnMapLoad(Core)
        end
    end
end

function Core.IsWatchedWidgetClass(clsName)
    return WatchedWidgetClasses[clsName] ~= nil
end

function Core.DispatchWidgetConstructed(widget, clsName)
    local handlers = WatchedWidgetClasses[clsName]
    if not handlers then return end
    for _, handler in ipairs(handlers) do
        handler(widget, Core)
    end
end

--------------------------------------------------------------------------------
-- Reusable Configurable Keybind & Settings -> Controls Row Helper
--------------------------------------------------------------------------------

local UE_TO_UE4SS_KEY = {
    BackSpace         = Key and Key.BACKSPACE,
    Tab               = Key and Key.TAB,
    Enter             = Key and Key.RETURN,
    Return            = Key and Key.RETURN,
    Pause             = Key and Key.PAUSE,
    CapsLock          = Key and Key.CAPS_LOCK,
    Escape            = Key and Key.ESCAPE,
    SpaceBar          = Key and Key.SPACE,
    PageUp            = Key and Key.PAGE_UP,
    PageDown          = Key and Key.PAGE_DOWN,
    End               = Key and Key.END,
    Home              = Key and Key.HOME,
    Left              = Key and Key.LEFT_ARROW,
    Up                = Key and Key.UP_ARROW,
    Right             = Key and Key.RIGHT_ARROW,
    Down              = Key and Key.DOWN_ARROW,
    Insert            = Key and Key.INS,
    Delete            = Key and Key.DEL,
    Zero              = Key and Key.ZERO,
    One               = Key and Key.ONE,
    Two               = Key and Key.TWO,
    Three             = Key and Key.THREE,
    Four              = Key and Key.FOUR,
    Five              = Key and Key.FIVE,
    Six               = Key and Key.SIX,
    Seven             = Key and Key.SEVEN,
    Eight             = Key and Key.EIGHT,
    Nine              = Key and Key.NINE,
    NumPadZero        = Key and Key.NUM_ZERO,
    NumPadOne         = Key and Key.NUM_ONE,
    NumPadTwo         = Key and Key.NUM_TWO,
    NumPadThree       = Key and Key.NUM_THREE,
    NumPadFour        = Key and Key.NUM_FOUR,
    NumPadFive        = Key and Key.NUM_FIVE,
    NumPadSix         = Key and Key.NUM_SIX,
    NumPadSeven       = Key and Key.NUM_SEVEN,
    NumPadEight       = Key and Key.NUM_EIGHT,
    NumPadNine        = Key and Key.NUM_NINE,
    Semicolon         = Key and Key.OEM_ONE,
    Equals            = Key and Key.OEM_PLUS,
    Comma             = Key and Key.OEM_COMMA,
    Hyphen            = Key and Key.OEM_MINUS,
    Period            = Key and Key.OEM_PERIOD,
    Slash             = Key and Key.OEM_TWO,
    Tilde             = Key and Key.OEM_THREE,
    LeftBracket       = Key and Key.OEM_FOUR,
    Backslash         = Key and Key.OEM_FIVE,
    RightBracket      = Key and Key.OEM_SIX,
    Apostrophe        = Key and Key.OEM_SEVEN,
}

local SharedKeyHandlers = {}    -- ue4ssKey -> true
local SyncingKeybindRows = {}   -- rowAddr -> true (prevents re-entrant OnKeySelected crash)
local SharedRemapHooksDone = false
local InitialSettingsMenuScanDone = false
local MOD_KEYS = nil

local function EnsureModKeys()
    if MOD_KEYS then return end
    MOD_KEYS = {}
    for k, n in pairs({
        LShift = "LeftShift", RShift = "RightShift",
        LCtrl  = "LeftControl", RCtrl = "RightControl",
        LAlt   = "LeftAlt", RAlt = "RightAlt",
        LCmd   = "LeftCommand", RCmd = "RightCommand",
    }) do
        pcall(function() MOD_KEYS[k] = { KeyName = FName(n) } end)
    end
end

local function FormatKeyChord(keyName, bCtrl, bAlt, bShift, bCmd)
    if not keyName or keyName == "" or keyName == "None" then
        return "None"
    end
    local parts = {}
    if bCtrl then parts[#parts + 1] = "Ctrl" end
    if bAlt then parts[#parts + 1] = "Alt" end
    if bShift then parts[#parts + 1] = "Shift" end
    if bCmd then parts[#parts + 1] = "Cmd" end
    parts[#parts + 1] = keyName
    return table.concat(parts, "+")
end

local function ParseKeyChord(spec)
    local bCtrl, bAlt, bShift, bCmd = false, false, false, false
    local keyName = "None"
    if type(spec) == "string" and spec ~= "" and spec ~= "None" then
        for token in spec:gmatch("[^+]+") do
            local trimmed = token:match("^%s*(.-)%s*$")
            local low = string.lower(trimmed)
            if low == "ctrl" or low == "control" then
                bCtrl = true
            elseif low == "alt" then
                bAlt = true
            elseif low == "shift" then
                bShift = true
            elseif low == "cmd" or low == "command" then
                bCmd = true
            elseif trimmed ~= "" then
                keyName = trimmed
            end
        end
    end
    if keyName == "" or keyName == "None" then
        bCtrl, bAlt, bShift, bCmd = false, false, false, false
        keyName = "None"
    end
    return {
        keyName = keyName,
        bCtrl = bCtrl,
        bAlt = bAlt,
        bShift = bShift,
        bCmd = bCmd,
        canonical = FormatKeyChord(keyName, bCtrl, bAlt, bShift, bCmd),
    }
end

local function ModifiersMatch(pc, parsed)
    if not parsed or parsed.keyName == "None" then return false end
    if not Core.IsValidObj(pc) or not pc.IsInputKeyDown then
        return not (parsed.bCtrl or parsed.bAlt or parsed.bShift or parsed.bCmd)
    end
    EnsureModKeys()
    local M = MOD_KEYS
    local shiftDown, ctrlDown, altDown, cmdDown = false, false, false, false
    pcall(function()
        shiftDown = (M.LShift and pc:IsInputKeyDown(M.LShift) == true)
            or (M.RShift and pc:IsInputKeyDown(M.RShift) == true) or false
        ctrlDown = (M.LCtrl and pc:IsInputKeyDown(M.LCtrl) == true)
            or (M.RCtrl and pc:IsInputKeyDown(M.RCtrl) == true) or false
        altDown = (M.LAlt and pc:IsInputKeyDown(M.LAlt) == true)
            or (M.RAlt and pc:IsInputKeyDown(M.RAlt) == true) or false
        cmdDown = (M.LCmd and pc:IsInputKeyDown(M.LCmd) == true)
            or (M.RCmd and pc:IsInputKeyDown(M.RCmd) == true) or false
    end)
    local k = parsed.keyName
    local isShiftKey = (k == "LeftShift" or k == "RightShift")
    local isCtrlKey  = (k == "LeftControl" or k == "RightControl")
    local isAltKey   = (k == "LeftAlt" or k == "RightAlt")
    local isCmdKey   = (k == "LeftCommand" or k == "RightCommand")
    return (isCtrlKey or ctrlDown == parsed.bCtrl)
        and (isAltKey or altDown == parsed.bAlt)
        and (isShiftKey or shiftDown == parsed.bShift)
        and (isCmdKey or cmdDown == parsed.bCmd)
end

local function ResolveUE4SSKey(keyName)
    if not keyName or keyName == "" or keyName == "None" or not Key then return nil end
    if UE_TO_UE4SS_KEY[keyName] then return UE_TO_UE4SS_KEY[keyName] end
    local upper = string.upper(keyName)
    return Key[upper]
end

local function MakeInputChord(chordSpec)
    local parsed = ParseKeyChord(chordSpec)
    return {
        Key = { KeyName = FName(parsed.keyName) },
        bShift = parsed.bShift,
        bCtrl = parsed.bCtrl,
        bAlt = parsed.bAlt,
        bCmd = parsed.bCmd,
    }
end

function Core.IsSelectingAnyRegisteredKeybind()
    for _, bs in pairs(RegisteredKeybinds) do
        for addr, row in pairs(bs.TrackedRows) do
            if Core.IsValidObj(row) then
                local sel = row.InputKeySelector
                if Core.IsValidObj(sel) then
                    local okS, selecting = pcall(function() return sel:GetIsSelectingKey() end)
                    if okS and selecting then return true end
                end
            else
                bs.TrackedRows[addr] = nil
            end
        end
    end
    return false
end

local function SyncKeybindRow(bs, row)
    if not Core.IsValidObj(row) then return end
    row.MappingName = FName(bs.MappingName)
    local lbl = Core.MakeText(bs.Label)
    row.InputActionText = lbl
    if Core.IsValidObj(row.WBP_SettingEntryBody) then
        pcall(function() row.WBP_SettingEntryBody:SetText(lbl) end)
    end
    if Core.IsValidObj(row.InputKeySelector) then
        local rowAddr = row:GetAddress()
        SyncingKeybindRows[rowAddr] = true
        pcall(function() row.InputKeySelector:SetSelectedKey(MakeInputChord(Core.Config[bs.ConfigKey])) end)
        SyncingKeybindRows[rowAddr] = nil
    end
end

function Core.IsGameplayInputAllowed(opts)
    opts = opts or {}
    if Core.IsSelectingAnyRegisteredKeybind() or Core.IsAnyTextInputFocused() then
        return false
    end
    if Core.IsAnyWidgetClassVisible("WBP_SettingsMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_PauseMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_MainMenu_C")
        or Core.IsAnyWidgetClassVisible("WBP_ConfirmationPopup_C")
        or Core.IsAnyWidgetClassVisible("WBP_Confirmation_Popup_C")
    then
        return false
    end

    local pc = Core.GetLocalPlayerController()
    if not Core.IsValidObj(pc) then
        return false
    end

    -- Block while any native UI window (Codex, Research, Inventory, Machine UI, etc.) is active
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow) then
        local allowSelfWindow = false
        if opts.AllowNativeWindowClass then
            local cls = Core.FindOrLoadClass(opts.AllowNativeWindowClass)
            if Core.IsValidObj(cls) then
                local okIsA, isA = pcall(function() return widgetSub.CurrentWindow:IsA(cls) end)
                if okIsA and isA == true then
                    allowSelfWindow = true
                end
            end
        end
        if not allowSelfWindow then
            return false
        end
        return true
    end

    if opts.AllowCursorUI == true then
        return true
    end

    -- Visible cursor means a modal/overlay UI (Codex, Map, Logistics, Designer, Popups) owns input
    local showCursor = false
    pcall(function() showCursor = (pc.bShowMouseCursor == true) end)
    if showCursor then
        return false
    end

    local charEnabled = false
    pcall(function() charEnabled = (pc.CharacterInputEnabled == true) end)
    if charEnabled then
        return true
    end

    local isPiloting = false
    local isSpectating = false
    pcall(function()
        local po = pc.PlayerObject
        if Core.IsValidObj(po) then
            isPiloting = Core.IsValidObj(po.PilotedShip)
            if Core.IsValidObj(po.SpectatorView) then
                isSpectating = (po.SpectatorView.bSpectatorMode == true)
            end
        end
    end)
    return isPiloting or isSpectating
end

local function CanTriggerRegisteredKeybind(bs)
    if type(bs.CanTrigger) == "function" then
        local ok, customRes = pcall(bs.CanTrigger)
        if ok and customRes == true then
            return not Core.IsSelectingAnyRegisteredKeybind() and not Core.IsAnyTextInputFocused()
        elseif ok and customRes == false then
            return false
        end
    end
    return Core.IsGameplayInputAllowed(bs)
end

local function BuildUE4SSModifierList(parsed)
    local mods = {}
    local mask = 0
    if parsed and ModifierKey then
        if parsed.bCtrl and ModifierKey.CONTROL then
            mods[#mods + 1] = ModifierKey.CONTROL
            mask = mask + 1
        end
        if parsed.bAlt and ModifierKey.ALT then
            mods[#mods + 1] = ModifierKey.ALT
            mask = mask + 2
        end
        if parsed.bShift and ModifierKey.SHIFT then
            mods[#mods + 1] = ModifierKey.SHIFT
            mask = mask + 4
        end
    end
    return mods, mask
end

local function CloseBleedthroughVanillaWindow(pc, entry)
    if not Core.IsValidObj(pc) then return false end
    local widgetSub = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
    if not (Core.IsValidObj(widgetSub) and Core.IsValidObj(widgetSub.CurrentWindow)) then
        return false
    end
    if entry and entry.AllowNativeWindowClass then
        local cls = Core.FindOrLoadClass(entry.AllowNativeWindowClass)
        if Core.IsValidObj(cls) then
            local okIsA, isA = pcall(function() return widgetSub.CurrentWindow:IsA(cls) end)
            if okIsA and isA == true then
                return false
            end
        end
    end
    if widgetSub.CloseCurrentWindow then
        pcall(function() widgetSub:CloseCurrentWindow() end)
        return true
    end
    return false
end

local function ApplyKeybindState(bs, chordSpec, shouldSave)
    local parsed = ParseKeyChord(chordSpec)
    local normalized = parsed.canonical
    Core.Config[bs.ConfigKey] = normalized
    if shouldSave then Core.WriteConfig() end
    if type(bs.OnChanged) == "function" then
        pcall(bs.OnChanged, normalized)
    end

    local ue4ssKey = ResolveUE4SSKey(parsed.keyName)
    local modList, modMask = BuildUE4SSModifierList(parsed)
    bs.ParsedChord = parsed
    bs.ActiveUe4ssKey = ue4ssKey
    bs.ActiveModMask = modMask
    bs.FallbackWasDown = false

    if ue4ssKey ~= nil then
        local handlerKey = tostring(ue4ssKey) .. ":" .. tostring(modMask)
        if not SharedKeyHandlers[handlerKey] then
            SharedKeyHandlers[handlerKey] = true
            local function onUe4ssKeyPress()
                for _, entry in pairs(RegisteredKeybinds) do
                    if entry.ActiveUe4ssKey == ue4ssKey and entry.ActiveModMask == modMask then
                        ExecuteInGameThread(function()
                            local pc = Core.GetLocalPlayerController()
                            if not ModifiersMatch(pc, entry.ParsedChord) then return end
                            local hadNativeWin = false
                            if modMask > 0 and Core.IsValidObj(pc) then
                                local ws = Core.GetWorldSubsystem(pc, Core.PATHS.WidgetSubsystemClass)
                                hadNativeWin = Core.IsValidObj(ws) and Core.IsValidObj(ws.CurrentWindow)
                            end
                            if CanTriggerRegisteredKeybind(entry) then
                                entry.OnPress()
                                -- If a modified chord shares a base key with a vanilla keybind (e.g. Shift+M vs M),
                                -- close any vanilla CurrentWindow that opened on the same keypress.
                                if modMask > 0 and not hadNativeWin then
                                    ExecuteInGameThreadAfterFrames(1, function()
                                        local curPC = Core.GetLocalPlayerController()
                                        if not CloseBleedthroughVanillaWindow(curPC, entry) then
                                            ExecuteInGameThreadAfterFrames(1, function()
                                                CloseBleedthroughVanillaWindow(Core.GetLocalPlayerController(), entry)
                                            end)
                                        end
                                    end)
                                end
                            end
                        end)
                    end
                end
            end
            if modMask > 0 then
                RegisterKeyBind(ue4ssKey, modList, onUe4ssKeyPress)
            else
                RegisterKeyBind(ue4ssKey, onUe4ssKeyPress)
            end
        end
    elseif not bs.FallbackPollActive and parsed.keyName ~= "None" then
        bs.FallbackPollActive = true
        local function PollTick()
            local curParsed = bs.ParsedChord
            if bs.ActiveUe4ssKey ~= nil or not curParsed or curParsed.keyName == "None" then
                bs.FallbackPollActive = false
                return
            end
            local pc = Core.GetLocalPlayerController()
            if Core.IsValidObj(pc) then
                local okD, down = pcall(function() return pc:IsInputKeyDown({ KeyName = FName(curParsed.keyName) }) end)
                if okD and down and not bs.FallbackWasDown then
                    bs.FallbackWasDown = true
                    if ModifiersMatch(pc, curParsed) and CanTriggerRegisteredKeybind(bs) then
                        bs.OnPress()
                    end
                elseif not okD or not down then
                    bs.FallbackWasDown = false
                end
            end
            ExecuteInGameThreadWithDelay(33, PollTick)
        end
        ExecuteInGameThreadWithDelay(33, PollTick)
    end
end

local SettingsMenuCallbacks = {}

function Core.OnSettingsMenuReady(cb)
    if type(cb) ~= "function" then return end
    table.insert(SettingsMenuCallbacks, cb)
    -- Replay for any WBP_SettingsMenu_C already tracked before this callback registered
    -- (prevents registration-order races on UE4SS hot-reload or pre-existing Settings menus).
    local existingMenus = TrackedWidgetsByClass["WBP_SettingsMenu_C"]
    if existingMenus then
        for addr, m in pairs(existingMenus) do
            if Core.IsValidObj(m) then
                pcall(cb, m)
            else
                existingMenus[addr] = nil
            end
        end
    end
end

local function EnsureMenuKeybindRows(menu)
    if not Core.IsValidObj(menu) then return end
    local scrollBox = menu.ControlSettings
    if not Core.IsValidObj(scrollBox) then return end
    local menuAddr = menu:GetAddress()
    local pc = Core.IsValidObj(menu.PC) and menu.PC or Core.GetLocalPlayerController()

    for _, bs in pairs(RegisteredKeybinds) do
        local existing = bs.MenuRows[menuAddr]
        if Core.IsValidObj(existing) then
            local okHas, hasChild = pcall(function() return scrollBox:HasChild(existing) end)
            if okHas and hasChild then
                SyncKeybindRow(bs, existing)
                goto continue_kb
            end
        end

        local row = Core.CreateUserWidget("/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C", menu, pc)
        if Core.IsValidObj(row) then
            bs.MenuRows[menuAddr] = row
            bs.TrackedRows[row:GetAddress()] = row
            row.MappingName = FName(bs.MappingName)
            local slot = scrollBox:AddChild(row)
            if Core.IsValidObj(slot) then
                local refRow = Core.IsValidObj(menu.StatusWindow) and menu.StatusWindow or menu.Statistics
                if Core.IsValidObj(refRow) and Core.IsValidObj(refRow.Slot) then
                    pcall(function()
                        slot:SetPadding(refRow.Slot.Padding)
                        slot:SetHorizontalAlignment(refRow.Slot.HorizontalAlignment)
                        slot:SetVerticalAlignment(refRow.Slot.VerticalAlignment)
                    end)
                end
            end
            SyncKeybindRow(bs, row)
        end
        ::continue_kb::
    end

    for _, cb in ipairs(SettingsMenuCallbacks) do
        pcall(cb, menu)
    end
end

local function ScheduleSettingsMenuSync(menu)
    if not Core.IsValidObj(menu) then return end
    local addr = menu:GetAddress()
    local now = os.clock()
    if LastSettingsMenuSyncClock[addr] and (now - LastSettingsMenuSyncClock[addr]) < 0.12 then
        return
    end
    LastSettingsMenuSyncClock[addr] = now
    -- Defer off the Esc/PauseMenu construction frame so pressing Esc has zero hitch
    ExecuteInGameThreadWithDelay(60, function()
        if Core.IsValidObj(menu) then
            EnsureMenuKeybindRows(menu)
        end
    end)
end

function Core.EnsureKeybindHooks()
    if not SharedRemapHooksDone then
        SharedRemapHooksDone = true
        WatchedWidgetClasses["WBP_SettingsMenu_C"] = WatchedWidgetClasses["WBP_SettingsMenu_C"] or {}
        table.insert(WatchedWidgetClasses["WBP_SettingsMenu_C"], function(menu)
            Core.EnsureKeybindHooks()
            ScheduleSettingsMenuSync(menu)
        end)
    end

    Core.TryRegisterHook(
        "Core_SettingsMenu_Setup",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Setup",
        function(Context)
            ScheduleSettingsMenuSync(Context:get())
        end
    )
    Core.TryRegisterHook(
        "Core_SettingsMenu_Refresh",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:Refresh",
        function(Context)
            ScheduleSettingsMenuSync(Context:get())
        end
    )
    Core.TryRegisterHook(
        "Core_SettingsMenu_RefreshInGame",
        "/Game/Blueprints/Widgets/Menus/WBP_SettingsMenu.WBP_SettingsMenu_C:RefreshInGame",
        function(Context)
            ScheduleSettingsMenuSync(Context:get())
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_LoadSettings",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:LoadSettings",
        function(Context)
            local row = Context:get()
            ExecuteInGameThread(function()
                if not Core.IsValidObj(row) then return end
                local okN, mName = pcall(function() return row.MappingName:ToString() end)
                local bs = okN and RegisteredKeybinds[mName] or nil
                if bs then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_RefreshDisplayKey",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:RefreshDisplayKey",
        function(Context)
            local row = Context:get()
            ExecuteInGameThread(function()
                if not Core.IsValidObj(row) then return end
                local okN, mName = pcall(function() return row.MappingName:ToString() end)
                local bs = okN and RegisteredKeybinds[mName] or nil
                if bs then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_OnKeySelected",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_InputKeySelector_K2Node_ComponentBoundEvent_0_OnKeySelected__DelegateSignature",
        function(Context, SelectedKeyParam)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            if SyncingKeybindRows[row:GetAddress()] then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end

            local okChord, chordStr = pcall(function()
                local chord = (type(SelectedKeyParam.get) == "function") and SelectedKeyParam:get() or SelectedKeyParam
                local kName = chord and chord.Key and chord.Key.KeyName and chord.Key.KeyName:ToString() or ""
                if kName == "" or kName == "None" then return nil end
                local bCtrl  = (chord.bCtrl == true)
                local bAlt   = (chord.bAlt == true)
                local bShift = (chord.bShift == true)
                local bCmd   = (chord.bCmd == true)
                return FormatKeyChord(kName, bCtrl, bAlt, bShift, bCmd)
            end)
            if okChord and chordStr and chordStr ~= "" and chordStr ~= "None" then
                -- Defer off the Slate OnKeySelected callback stack; calling SetSelectedKey synchronously
                -- inside OnKeySelected causes re-entrant recursion / Slate crashes on modifier chords (e.g. Shift+M).
                ExecuteInGameThreadWithDelay(10, function()
                    ApplyKeybindState(bs, chordStr, true)
                end)
            end
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_Revert",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_RevertToDefaultButton_K2Node_ComponentBoundEvent_1_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end
            ExecuteInGameThreadWithDelay(10, function()
                ApplyKeybindState(bs, bs.DefaultKey, true)
                if Core.IsValidObj(row) then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_InputRemap_Clear",
        "/Game/Blueprints/Widgets/Display/Settings/WBP_InputRemap.WBP_InputRemap_C:BndEvt__WBP_InputRemap_ClearMappingButton_K2Node_ComponentBoundEvent_2_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local row = Context:get()
            if not Core.IsValidObj(row) then return end
            local okN, mName = pcall(function() return row.MappingName:ToString() end)
            local bs = okN and RegisteredKeybinds[mName] or nil
            if not bs then return end
            ExecuteInGameThreadWithDelay(10, function()
                ApplyKeybindState(bs, "None", true)
                if Core.IsValidObj(row) then SyncKeybindRow(bs, row) end
            end)
        end
    )
    Core.TryRegisterHook(
        "Core_TextInput_OnChanged",
        "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C:BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_0_OnEditableTextBoxChangedEvent__DelegateSignature",
        function(Context)
            local inputWidget = Context:get()
            if Core.IsValidObj(inputWidget) then
                local entry = TrackedTextInputs[inputWidget:GetAddress()]
                if entry and IsWidgetTreeVisible(inputWidget, entry.Owner) then
                    entry.ExplicitFocus = true
                    SyncCharacterInputSuppression()
                end
            end
        end
    )
    Core.TryRegisterHook(
        "Core_TextInput_OnCommitted",
        "/Game/Blueprints/Widgets/Basic/WBP_TextInput.WBP_TextInput_C:BndEvt__WBP_TextInput_EditableTextBox_80_K2Node_ComponentBoundEvent_1_OnEditableTextBoxCommittedEvent__DelegateSignature",
        function(Context)
            local inputWidget = Context:get()
            if Core.IsValidObj(inputWidget) then
                local entry = TrackedTextInputs[inputWidget:GetAddress()]
                if entry then
                    entry.ExplicitFocus = false
                end
            end
            ExecuteInGameThreadWithDelay(1, SyncCharacterInputSuppression)
        end
    )

    if not InitialSettingsMenuScanDone then
        InitialSettingsMenuScanDone = true
        local okMenu, m = pcall(FindFirstOf, "WBP_SettingsMenu_C")
        if okMenu and Core.IsValidObj(m) then
            TrackWidgetInstance("WBP_SettingsMenu_C", m)
            EnsureMenuKeybindRows(m)
        end
    end
end

function Core.RegisterConfigurableKeybind(opts)
    local bs = {
        ConfigKey = opts.ConfigKey,
        DefaultKey = opts.DefaultKey,
        MappingName = opts.MappingName,
        Label = opts.Label,
        OnPress = opts.OnPress,
        OnChanged = opts.OnChanged,
        CanTrigger = opts.CanTrigger,
        AllowCursorUI = opts.AllowCursorUI,
        AllowNativeWindowClass = opts.AllowNativeWindowClass,
        ActiveUe4ssKey = nil,
        FallbackPollActive = false,
        FallbackWasDown = false,
        MenuRows = {},
        TrackedRows = {},
    }
    RegisteredKeybinds[bs.MappingName] = bs
    Core.ReadConfig({ [bs.ConfigKey] = bs.DefaultKey })
    ApplyKeybindState(bs, Core.Config[bs.ConfigKey], false)
    Core.EnsureKeybindHooks()
    return bs
end

--------------------------------------------------------------------------------
-- Safe WBP_Button_C Click Registry (avoids UButton.OnPressed:Add crashes)
--------------------------------------------------------------------------------

function Core.UnregisterWBPButtonClick(btn)
    if not Core.IsValidObj(btn) then return end
    ButtonClickCallbacks[btn:GetAddress()] = nil
end

function Core.RegisterWBPButtonClick(btn, fn)
    if not Core.IsValidObj(btn) or type(fn) ~= "function" then return end
    ButtonClickCallbacks[btn:GetAddress()] = { btn = btn, fn = fn }

    Core.TryRegisterHook(
        "Core_WBPButton_OnPressed",
        "/Game/Blueprints/Widgets/Basic/WBP_Button.WBP_Button_C:BndEvt__WBP_Button_Button_K2Node_ComponentBoundEvent_0_OnButtonPressedEvent__DelegateSignature",
        function(Context)
            local w = Context:get()
            if Core.IsValidObj(w) then
                local addr = w:GetAddress()
                local entry = ButtonClickCallbacks[addr]
                if entry then
                    if Core.IsValidObj(entry.btn) and entry.btn:GetAddress() == addr then
                        pcall(entry.fn, w)
                    else
                        ButtonClickCallbacks[addr] = nil
                    end
                end
            end
        end
    )
end

return Core
