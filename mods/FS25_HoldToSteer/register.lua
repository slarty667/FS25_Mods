--[[
  register.lua
  Bootstrap for FS25_HoldToSteer.
  Creates mod instance on Mission00.load, sets mission.mouseSteering, addModEventListener.
]]

source(Utils.getFilename("scripts/lib/UIHelper.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/PathGeometry.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/TrailerKinematics.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/VehicleIntrospection.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/SegmentPool.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/SteeringPathIndicator.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/RmbSuppression.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/MouseSteering.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/VehicleCameraExtension.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/MouseSteeringVehicle.lua", g_currentModDirectory))

MouseSteeringRegister = {}
MouseSteeringRegister.MOD_NAME = "FS25_HoldToSteer"
MouseSteeringRegister.LEGACY_MOD_NAME = "FS25_MouseSteering_MiddleClick"

if MouseSteeringVehicle.specName == nil then
    MouseSteeringVehicle.specName = g_currentModName and (g_currentModName .. ".MouseSteeringVehicle")
        or (MouseSteeringRegister.MOD_NAME .. ".MouseSteeringVehicle")
end

if g_specializationManager and g_specializationManager:getSpecializationByName("MouseSteeringVehicle") == nil then
    g_specializationManager:addSpecialization(
        "MouseSteeringVehicle",
        "MouseSteeringVehicle",
        Utils.getFilename("scripts/MouseSteeringVehicle.lua", g_currentModDirectory),
        nil
    )
end

function MouseSteeringRegister.registerToVehicleTypes()
    if not MouseSteeringVehicle or not g_vehicleTypeManager or not g_vehicleTypeManager.types then return end
    local specName = MouseSteeringVehicle.specName
    local count = 0
    for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
        if typeDef ~= nil and vehicleType ~= "horse" and not typeDef.hasMouseSteeringSpec then
            if MouseSteeringVehicle.prerequisitesPresent(typeDef.specializations) then
                if typeDef.specializationsByName == nil or typeDef.specializationsByName[specName] == nil then
                    g_vehicleTypeManager:addSpecialization(vehicleType, specName)
                    typeDef.hasMouseSteeringSpec = true
                    count = count + 1
                end
            end
        end
    end
    if Logging then Logging.info("[MouseSteering] registered spec to %d vehicle types", count) end
end

--- Runs before vanilla TypeManager.validateTypes (vehicle types must be patched early).
function MouseSteeringValidateVehicleTypesPre(TypeManager)
    MouseSteeringRegister.registerToVehicleTypes()
end

--- Runs after vanilla validateTypes — specialization lookups may be incomplete if we run too early.
function MouseSteeringValidateVehicleTypesPost(TypeManager)
    if VehicleCameraExtension and VehicleCameraExtension.applySpecializationLookHooksAtValidateTypes then
        VehicleCameraExtension:applySpecializationLookHooksAtValidateTypes()
    end
end

---------------------------------------------------------------------------
-- Mod instance (created on Mission00.load)
---------------------------------------------------------------------------
local modInstance = nil

local function createModInstance(mission)
    if modInstance then return end
    modInstance = {
        mission = mission,
        controlledVehicle = nil,
    }
    function modInstance:setControlledVehicle(vehicle)
        self.controlledVehicle = vehicle
        if MouseSteering then
            MouseSteering.drawVehicle = vehicle
            MouseSteering:onControlledVehicleChanged(vehicle)
        end
    end
    function modInstance:draw(dt)
        -- Late pass: vehicle/implement input may be applied after mission:update / vehicle onPostUpdate.
        local v = self.controlledVehicle
        if v and MouseSteering then
            MouseSteering:tryZeroFrontloaderHydraulics(v, "modDraw")
        end
        if not self.mission or not self.mission.hud then return end
        if self.mission.hud.isMenuVisible or g_noHudModeEnabled then return end
        if MouseSteering then MouseSteering:draw() end
    end
    function modInstance:update(dt)
        -- Clear vehicle ref if player left, and propagate the nil so MouseSteering
        -- can disarm cleanly. Without the explicit notification the next
        -- onControlledVehicleChanged(nil) is never called and armed stays true.
        if self.controlledVehicle then
            local v = self.controlledVehicle
            if v.getIsControlled and not v:getIsControlled() then
                self.controlledVehicle = nil
                if MouseSteering and MouseSteering.onControlledVehicleChanged then
                    MouseSteering:onControlledVehicleChanged(nil)
                end
            end
        end
        if MouseSteering then MouseSteering:update(dt) end
    end
    function modInstance:loadMap(name)
        -- Load persisted settings from XML
        if MouseSteeringSettings and MouseSteeringSettings.loadFromXML then
            MouseSteeringSettings:loadFromXML()
        end
        if MouseSteering then MouseSteering:loadMap(name) end
    end
    function modInstance:keyEvent(unicode, sym, modifier, isDown)
        if MouseSteering then MouseSteering:keyEvent(unicode, sym, modifier, isDown) end
    end
    function modInstance:mouseEvent(posX, posY, isDown, isUp, button)
        if MouseSteering then MouseSteering:mouseEvent(posX, posY, isDown, isUp, button) end
    end
    function modInstance:delete()
        -- Save settings before unloading
        if MouseSteeringSettings and MouseSteeringSettings.saveToXML then
            MouseSteeringSettings:saveToXML()
        end
        if SteeringPathIndicator and SteeringPathIndicator.shutdown then
            SteeringPathIndicator:shutdown()
        end
        if RmbSuppression and RmbSuppression.uninstall then
            RmbSuppression:uninstall()
        end
        if VehicleCameraExtension then VehicleCameraExtension:uninstall() end
        if g_currentMission then g_currentMission.mouseSteering = nil end
        modInstance = nil
    end

    mission.mouseSteering = modInstance
    addModEventListener(modInstance)

    -- Install camera overwrite early (before any vehicle action events are registered)
    if VehicleCameraExtension then VehicleCameraExtension:install() end

    if Logging then Logging.info("[MouseSteering] mod instance created, camera extension installed") end
end

local function onMissionLoad(mission)
    if not mission or mission.cancelLoading then return end
    -- Retry camera extension install (in case VehicleCamera wasn't ready at Mission00.load)
    if VehicleCameraExtension then VehicleCameraExtension:install() end
end

local function onUnload()
    if modInstance then modInstance:delete() end
end

local function init()
    if not g_currentModName then return end
    local isCurrent = (g_currentModName == MouseSteeringRegister.MOD_NAME)
    local isLegacy = (g_currentModName == MouseSteeringRegister.LEGACY_MOD_NAME)
    if not isCurrent and not isLegacy then return end

    if Logging and Logging.info and isLegacy then
        Logging.info(
            "[MouseSteering] loaded via legacy mod name '%s' (recommended: '%s')",
            MouseSteeringRegister.LEGACY_MOD_NAME,
            MouseSteeringRegister.MOD_NAME
        )
    end

    if TypeManager and TypeManager.validateTypes then
        TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, MouseSteeringValidateVehicleTypesPre)
        TypeManager.validateTypes = Utils.appendedFunction(TypeManager.validateTypes, MouseSteeringValidateVehicleTypesPost)
    end
    if Mission00 and Mission00.load then
        Mission00.load = Utils.prependedFunction(Mission00.load, function(mission)
            createModInstance(mission)
        end)
    end
    if Mission00 and Mission00.loadMission00Finished then
        Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoad)
    end
    if FSBaseMission and FSBaseMission.delete then
        FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, onUnload)
    end
    MouseSteeringRegister.registerToVehicleTypes()
    if Logging then Logging.info("[MouseSteering] init complete") end
end

init()
