-- Elvenide's Station Map for Main Sequence
-- Entrypoint: registers core utilities and feature module(s).

do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local scriptDir = src:match("^(.*)[/\\][^/\\]+$")
    if scriptDir and scriptDir ~= "" then
        local luaPattern = scriptDir .. "/?.lua"
        if not package.path:find(luaPattern, 1, true) then
            package.path = luaPattern .. ";" .. package.path
        end
    end
end

local Core = require("core")

Core.RegisterFeature(require("features.station_map"))

-- Startup
Core.InitAll()
Core.EnsureAllHooks()
Core.RegisterTargetedWidgetWatchers()

pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function(Context)
    local pc = Context and Context:get() or nil
    if not Core.IsValidObj(pc) then return end
    local okL, isLocal = pcall(function() return pc:IsLocalPlayerController() end)
    if not (okL and isLocal) then return end
    Core.SetLocalPlayerController(pc)
    Core.DispatchClientRestart()
end)

RegisterInitGameStatePostHook(function()
    Core.DispatchMapLoad()
end)

RegisterLoadMapPostHook(function()
    Core.DispatchMapLoad()
end)

Core.Log("Initialized v" .. tostring(Core.VERSION))