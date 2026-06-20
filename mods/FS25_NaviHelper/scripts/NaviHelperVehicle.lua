--[[
  NaviHelperVehicle.lua
  Vehicle specialization for FS25 NaviHelper. Registers action events on the vehicle
  so that VEHICLE-category inputs (Alt+N, F10, etc.) are delivered in vehicle context.
  Pattern: same as FS25_AutoDrive (register.lua + spec, no vehicleTypes XML).
]]

NaviHelperVehicle = {}
NaviHelperVehicle.MOD_NAME = "FS25_NaviHelper"

if NaviHelperVehicle.specName == nil then
    NaviHelperVehicle.specName = g_currentModName and (g_currentModName .. ".NaviHelperVehicle") or "FS25_NaviHelper.NaviHelperVehicle"
end

function NaviHelperVehicle.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function NaviHelperVehicle.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", NaviHelperVehicle)
    -- Do NOT register onDrawUIInfo: the engine calls it for every vehicle each frame, which caused
    -- severe FPS drop. All drawing is done from NaviHelper:draw() (mod callback, once per frame).
end

-- Resolve action ID: FS25 may expose mod actions on InputAction or via nameActions, not Input.
local function getActionId(actionName)
    if Input and Input[actionName] ~= nil then
        return Input[actionName]
    end
    if InputAction and InputAction[actionName] ~= nil then
        return InputAction[actionName]
    end
    if g_inputBinding and g_inputBinding.nameActions then
        if g_inputBinding.nameActions[actionName] ~= nil then
            return g_inputBinding.nameActions[actionName]
        end
        -- Some builds use mod-prefixed key (e.g. FS25_NaviHelper.NAVIHELPER_TOGGLE_UI)
        local prefixed = g_currentModName and (g_currentModName .. "." .. actionName) or ("FS25_NaviHelper." .. actionName)
        if g_inputBinding.nameActions[prefixed] ~= nil then
            return g_inputBinding.nameActions[prefixed]
        end
    end
    return nil
end

function NaviHelperVehicle:onRegisterActionEvents(_, isOnActiveVehicle)
    if Logging then
        Logging.info("[NaviHelper] NaviHelperVehicle:onRegisterActionEvents isOnActiveVehicle=%s", tostring(isOnActiveVehicle))
    end
    if not isOnActiveVehicle then
        return
    end
    -- Store so we have a vehicle when user toggles nav aid (controlledVehicle is nil in draw context).
    if NaviHelper then NaviHelper.lastActiveVehicle = self end
    if not g_inputBinding then
        if Logging then Logging.info("[NaviHelper] onRegisterActionEvents: no g_inputBinding") end
        return
    end
    local actionNames = {
        "NAVIHELPER_TOGGLE_UI",
        "NAVIHELPER_CLEAR_TARGET",
        "NAVIHELPER_SET_TARGET_FROM_MAP",
        "NAVIHELPER_SET_TARGET_AHEAD",
    }
    local callbacks = {
        NaviHelperVehicle.onToggleUI,
        NaviHelperVehicle.onClearTarget,
        NaviHelperVehicle.onMapSelectionMode,
        NaviHelperVehicle.onRouteToADDest,
    }
    local registered = 0
    for i, actionName in ipairs(actionNames) do
        local actionId = getActionId(actionName)
        if actionId ~= nil then
            local _, eventId = g_inputBinding:registerActionEvent(actionId, self, callbacks[i], false, true, false, true)
            -- Critical: a registered action event stays INACTIVE until explicitly activated.
            -- Without this the keys never fire (registered but dead) — Super Strength does the same.
            if eventId then
                g_inputBinding:setActionEventActive(eventId, true)
                g_inputBinding:setActionEventTextVisibility(eventId, false)
            end
            registered = registered + 1
        end
    end
    if Logging then
        Logging.info("[NaviHelper] onRegisterActionEvents: registered %d actions", registered)
        if registered == 0 and g_inputBinding and g_inputBinding.nameActions then
            local n, sample = 0, {}
            for k, v in pairs(g_inputBinding.nameActions) do
                n = n + 1
                if n <= 5 then table.insert(sample, tostring(k)) end
            end
            Logging.info("[NaviHelper] nameActions has %d entries; sample keys: %s", n, table.concat(sample, ", "))
        end
    end
end

-- Forward to global NaviHelper; pass self (vehicle) so AD target lookup works when controlledVehicle is not yet set.
function NaviHelperVehicle:onToggleUI()
    if NaviHelper and NaviHelper.onToggleUI then
        NaviHelper:onToggleUI(self)
    end
end

function NaviHelperVehicle:onClearTarget()
    if NaviHelper and NaviHelper.onClearTarget then
        NaviHelper:onClearTarget(self)
    end
end

function NaviHelperVehicle:onMapSelectionMode()
    if NaviHelper and NaviHelper.onMapSelectionMode then
        NaviHelper:onMapSelectionMode()
    end
end

function NaviHelperVehicle:onRouteToADDest()
    if NaviHelper and NaviHelper.onRouteToADDest then
        NaviHelper:onRouteToADDest(self)
    end
end

