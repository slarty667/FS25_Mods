--[[
  MouseSteeringVehicle.lua
  Vehicle specialization. Sets the controlled vehicle reference for the mod
  and draws the HUD. Also applies steering in onUpdate (after game input processing).
]]

MouseSteeringVehicle = {}
MouseSteeringVehicle.MOD_NAME = "FS25_MouseSteering_MiddleClick"

if MouseSteeringVehicle.specName == nil then
    MouseSteeringVehicle.specName = g_currentModName and (g_currentModName .. ".MouseSteeringVehicle")
        or "FS25_MouseSteering_MiddleClick.MouseSteeringVehicle"
end

function MouseSteeringVehicle.prerequisitesPresent(specializations)
    return SpecializationUtil.hasSpecialization(Drivable, specializations)
        and SpecializationUtil.hasSpecialization(Enterable, specializations)
end

function MouseSteeringVehicle.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onUpdate", MouseSteeringVehicle)
    SpecializationUtil.registerEventListener(vehicleType, "onDrawUIInfo", MouseSteeringVehicle)
    SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", MouseSteeringVehicle)
end

local function getActionId(actionName)
    if Input and Input[actionName] ~= nil then return Input[actionName] end
    if InputAction and InputAction[actionName] ~= nil then return InputAction[actionName] end
    if g_inputBinding and g_inputBinding.nameActions then
        if g_inputBinding.nameActions[actionName] ~= nil then return g_inputBinding.nameActions[actionName] end
        local prefixed = g_currentModName and (g_currentModName .. "." .. actionName) or ("FS25_MouseSteering_MiddleClick." .. actionName)
        if g_inputBinding.nameActions[prefixed] ~= nil then return g_inputBinding.nameActions[prefixed] end
    end
    return nil
end

function MouseSteeringVehicle:onRegisterActionEvents(_, isOnActiveVehicle)
    if not isOnActiveVehicle or not g_inputBinding then return end

    -- Register the toggle-armed action so it appears in the vanilla help icon box
    -- (top-left of the HUD) while the player is inside a vehicle.
    local actionId = getActionId("MOUSESTEERING_TOGGLE_ARMED")
    if actionId then
        local _, eventId = InputBinding.registerActionEvent(
            g_inputBinding, actionId, self, MouseSteeringVehicle.onToggleArmedAction,
            false, true, false, true
        )
        if eventId then
            pcall(function() g_inputBinding:setActionEventTextVisibility(eventId, true) end)
            if GS_PRIO_NORMAL and g_inputBinding.setActionEventTextPriority then
                pcall(function() g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_NORMAL) end)
            end
        end
    end
end

---Action callback for MOUSESTEERING_TOGGLE_ARMED.
---Routes to MouseSteering:onToggleArmed, same behaviour as Ctrl+M polled via keyEvent.
function MouseSteeringVehicle.onToggleArmedAction(self)
    if MouseSteering and MouseSteering.onToggleArmed then
        MouseSteering:onToggleArmed(self)
    end
end

---------------------------------------------------------------------------
-- onUpdate: set controlled vehicle + apply steering (after game input)
---------------------------------------------------------------------------
function MouseSteeringVehicle:onUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local mission = g_currentMission
    if not mission or not mission.mouseSteering then return end

    local isEntered = self.getIsEntered and self:getIsEntered()
    local isControlled = self.getIsControlled and self:getIsControlled()
    if not isEntered or not isControlled then return end

    -- Tell mod instance this is the controlled vehicle
    mission.mouseSteering:setControlledVehicle(self)

    -- Apply steering here (vehicle spec onUpdate runs AFTER Drivable input processing).
    -- Only write to axisSteer while LMB is held (active). When released, the game's
    -- own vehicle physics (caster effect) handle speed-dependent centering naturally.
    if MouseSteering and MouseSteering.armed and MouseSteering.active then
        local out = MouseSteering.steeringValue or 0
        local deadzone = (MouseSteeringSettings and MouseSteeringSettings.deadzone) or 0.02
        if math.abs(out) < deadzone then out = 0 end

        local drivable = self.spec_drivable
        if drivable and drivable.lastInputValues then
            drivable.lastInputValues.axisSteer = out
            drivable.lastInputValues.axisSteerIsAnalog = true
            if drivable.lastInputValues.axisSteerDeviceCategory == nil then
                pcall(function()
                    drivable.lastInputValues.axisSteerDeviceCategory = InputDevice.CATEGORY.WHEEL
                end)
            end
        end
    end
end

---------------------------------------------------------------------------
-- onDrawUIInfo: draw HUD for controlled vehicle
---------------------------------------------------------------------------
function MouseSteeringVehicle:onDrawUIInfo()
    if not g_currentMission then return end
    local isEntered = self.getIsEntered and self:getIsEntered()
    local isControlled = self.getIsControlled and self:getIsControlled()
    if not isEntered or not isControlled then return end
    if MouseSteering and MouseSteering.drawForVehicle then
        MouseSteering:drawForVehicle(self)
    end
end
