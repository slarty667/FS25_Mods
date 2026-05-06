--[[
  MouseSteeringVehicle.lua
  Vehicle specialization. Sets the controlled vehicle reference for the mod
  and draws the HUD. Also applies steering in onUpdate (after game input processing).
]]

MouseSteeringVehicle = {}
MouseSteeringVehicle.MOD_NAME = "FS25_MouseSteering_MiddleClick"
--- Weak keys: mark our wrapped callbacks so we do not double-wrap.
MouseSteeringVehicle._flWrapMarkers = MouseSteeringVehicle._flWrapMarkers
    or setmetatable({}, { __mode = "k" })

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
    SpecializationUtil.registerEventListener(vehicleType, "onPostUpdate", MouseSteeringVehicle)
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
    local suppressFl = false
    if MouseSteering and MouseSteering.isFrontloaderSelectionSuppressingMouse then
        local ok, v = pcall(function()
            return MouseSteering:isFrontloaderSelectionSuppressingMouse(self)
        end)
        if ok then suppressFl = v end
    end
    if MouseSteering and MouseSteering.armed
        and (MouseSteering.active or MouseSteering._steeringCoast)
        and not suppressFl then
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
-- onPostUpdate: after vanilla + implements read input, strip mouse-driven
-- hydraulic axes from frontloader hardware while LMB mouse-steering the tractor.
-- Prevents fork up/down from following horizontal mouse steering.
---------------------------------------------------------------------------
function MouseSteeringVehicle:onPostUpdate(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local mission = g_currentMission
    if not mission or not mission.mouseSteering then return end

    local isEntered = self.getIsEntered and self:getIsEntered()
    local isControlled = self.getIsControlled and self:getIsControlled()
    if not isEntered or not isControlled then return end

    if not MouseSteering or not MouseSteering.armed or not MouseSteering.active then return end
    if MouseSteering.isFrontloaderSelectionSuppressingMouse
        and MouseSteering:isFrontloaderSelectionSuppressingMouse(self) then
        return
    end

    pcall(function()
        MouseSteering:tryZeroFrontloaderHydraulics(self, "vehiclePost")
    end)

    --- InputBinding replaces action row callbacks when selection changes; re-wrap whenever callback is not ours.
    local function shouldSuppressFrontloaderAxisForVehicle(rootVehicle)
        if not MouseSteering or not rootVehicle then return false end
        if not MouseSteering.armed or not MouseSteering.active then return false end
        if MouseSteering._otherMouseButtonDown then return false end
        if MouseSteering.isFrontloaderSelectionSuppressingMouse then
            local ok, sup = pcall(function()
                return MouseSteering:isFrontloaderSelectionSuppressingMouse(rootVehicle)
            end)
            if ok and sup then return false end
        end
        return true
    end

    local function installFrontloaderAxisSuppressWrapper(ev, actionName)
        if type(ev) ~= "table" or type(actionName) ~= "string" then return end
        local aU = actionName:upper()
        if not (aU == "AXIS_FRONTLOADER_ARM" or aU == "AXIS_FRONTLOADER_TOOL" or aU == "AXIS_FRONTLOADER_TOOL2") then
            return
        end
        local cbKey = nil
        if type(ev.callback) == "function" then
            cbKey = "callback"
        elseif type(ev.callbackFunc) == "function" then
            cbKey = "callbackFunc"
        elseif type(ev.func) == "function" then
            cbKey = "func"
        end
        if not cbKey then return end
        local current = ev[cbKey]
        if type(current) ~= "function" then return end
        if MouseSteeringVehicle._flWrapMarkers[current] then return end

        local oldFn = current
        local wrapped
        wrapped = function(...)
            if shouldSuppressFrontloaderAxisForVehicle(self) then
                return
            end
            return oldFn(...)
        end
        MouseSteeringVehicle._flWrapMarkers[wrapped] = true
        ev[cbKey] = wrapped
    end

    if g_inputBinding and g_inputBinding.actionEvents then
        pcall(function()
            for actionObj, rows in pairs(g_inputBinding.actionEvents) do
                if type(rows) == "table" then
                    for _, ev in ipairs(rows) do
                        if type(ev) == "table" then
                            local tgt = ev.targetObject or ev.target or ev.object or ev.instance or ev.self
                            local linkedToVehicle = (tgt == self)
                            if not linkedToVehicle and (type(tgt) == "table" or type(tgt) == "userdata") then
                                pcall(function()
                                    if tgt.rootVehicle == self then
                                        linkedToVehicle = true
                                    elseif type(tgt.getRootVehicle) == "function" then
                                        linkedToVehicle = (tgt:getRootVehicle() == self)
                                    end
                                end)
                            end
                            if linkedToVehicle then
                                local ao = tostring(actionObj or "")
                                local actionName = ao:match("^%[([^:]+):")
                                if type(actionName) ~= "string" or actionName == "" then
                                    actionName = ao
                                end
                                installFrontloaderAxisSuppressWrapper(ev, actionName)
                            end
                        end
                    end
                end
            end
        end)
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
