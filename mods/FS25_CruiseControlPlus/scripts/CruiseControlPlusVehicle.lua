--[[
  CruiseControlPlusVehicle.lua
  Vehicle specialization for FS25_CruiseControlPlus. Registers action CRUISECONTROLPLUS_SET_TO_CURRENT
  (set cruise to current speed and activate). Pattern from CruiseControlLevels: own action, no KEY_3 hook.
]]

CruiseControlPlusVehicle = {}
CruiseControlPlusVehicle.MOD_NAME = "FS25_CruiseControlPlus"

if CruiseControlPlusVehicle.specName == nil then
    CruiseControlPlusVehicle.specName = g_currentModName and (g_currentModName .. ".CruiseControlPlusVehicle")
        or "FS25_CruiseControlPlus.CruiseControlPlusVehicle"
end

function CruiseControlPlusVehicle.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function CruiseControlPlusVehicle.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onLoad", CruiseControlPlusVehicle)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", CruiseControlPlusVehicle)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", CruiseControlPlusVehicle)
    SpecializationUtil.registerEventListener(vehicleType, "onDrawUIInfo", CruiseControlPlusVehicle)
end

function CruiseControlPlusVehicle:onLoad()
    self.spec_cruiseControlPlus = {}
    self.spec_cruiseControlPlus.actionEvents = {}
end

function CruiseControlPlusVehicle:onRegisterActionEvents(_, isOnActiveVehicle)
    if not isOnActiveVehicle or not g_currentMission then return end
    if g_currentMission.cruiseControlPlus then
        g_currentMission.cruiseControlPlus:setControlledVehicle(self)
    end
    local spec = self.spec_cruiseControlPlus
    if not spec or not spec.actionEvents then return end
    if not self.isClient then return end
    self:clearActionEventsTable(spec.actionEvents)
    if self:getIsActiveForInput(true, true) then
        local actionId = InputAction.CRUISECONTROLPLUS_SET_TO_CURRENT
        if actionId == nil and g_inputBinding and g_inputBinding.nameActions then
            actionId = g_inputBinding.nameActions["CRUISECONTROLPLUS_SET_TO_CURRENT"]
        end
        if actionId ~= nil then
            self:addActionEvent(spec.actionEvents, actionId, self, CruiseControlPlusVehicle.onSetCruiseToCurrentSpeed, false, true, false, true)
        end
    end
end

--- Callback for CRUISECONTROLPLUS_SET_TO_CURRENT: set cruise speed to current speed and activate (CCL pattern).
function CruiseControlPlusVehicle.onSetCruiseToCurrentSpeed(self)
    if not self or not self.spec_drivable or not self.spec_drivable.cruiseControl then return end
    if self:getDrivingDirection() < 0 then return end
    local kmh = CruiseControlPlus and CruiseControlPlus.getCurrentSpeedKmh(self, CruiseControlPlusSettings)
    if kmh == nil then
        if g_currentMission and g_currentMission.showBlinkingWarning and g_i18n then
            local msg = g_i18n:getText("CRUISECONTROLPLUS_SPEED_TOO_LOW") or "Speed too low"
            g_currentMission:showBlinkingWarning(msg, 2000)
        end
        return
    end
    self:setCruiseControlMaxSpeed(kmh)
    local spec = self.spec_drivable
    if spec.cruiseControl.speed ~= spec.cruiseControl.speedSent then
        if g_server ~= nil then
            g_server:broadcastEvent(SetCruiseControlSpeedEvent.new(self, spec.cruiseControl.speed, spec.cruiseControl.speedReverse), nil, nil, self)
        elseif g_client and g_client.getServerConnection then
            local conn = g_client:getServerConnection()
            if conn and conn.sendEvent then
                conn:sendEvent(SetCruiseControlSpeedEvent.new(self, spec.cruiseControl.speed, spec.cruiseControl.speedReverse))
            end
        end
        spec.cruiseControl.speedSent = spec.cruiseControl.speed
        spec.cruiseControl.speedReverseSent = spec.cruiseControl.speedReverse
    end
    local stateActive = (Drivable and Drivable.CRUISECONTROL_STATE_ACTIVE) or 1
    self:setCruiseControlState(stateActive)
    if SetCruiseControlStateEvent and g_client and g_client.getServerConnection then
        local conn = g_client:getServerConnection()
        if conn and conn.sendEvent then
            pcall(function() conn:sendEvent(SetCruiseControlStateEvent.new(self, stateActive)) end)
        end
    end
    if CruiseControlPlus then
        CruiseControlPlus.lastSetSpeedKmh = kmh
        CruiseControlPlus.lastSetSpeedTime = (g_currentMission and g_currentMission.time) or (getTickCount and getTickCount()) or 0
    end
end

function CruiseControlPlusVehicle:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local mission = g_currentMission
    if not mission or not mission.cruiseControlPlus then return end
    local isEntered = self.getIsEntered and self:getIsEntered()
    local isControlled = self.getIsControlled and self:getIsControlled()
    if not isEntered or not isControlled then return end
    mission.cruiseControlPlus:setControlledVehicle(self)
end

function CruiseControlPlusVehicle:onDrawUIInfo()
    -- Phase 8: optional HUD notification from CruiseControlPlus:draw or here
end
