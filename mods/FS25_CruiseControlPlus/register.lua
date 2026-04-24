--[[
  register.lua
  Bootstrap for FS25_CruiseControlPlus.
  Registers vehicle specialization, creates mod instance on Mission00.load.
]]

source(Utils.getFilename("scripts/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/DebugLog.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/CruiseControlPlus.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/CruiseControlPlusVehicle.lua", g_currentModDirectory))

CruiseControlPlusRegister = {}

if CruiseControlPlusVehicle.specName == nil then
    CruiseControlPlusVehicle.specName = g_currentModName and (g_currentModName .. ".CruiseControlPlusVehicle")
        or "FS25_CruiseControlPlus.CruiseControlPlusVehicle"
end

if g_specializationManager and g_specializationManager:getSpecializationByName("CruiseControlPlusVehicle") == nil then
    g_specializationManager:addSpecialization(
        "CruiseControlPlusVehicle",
        "CruiseControlPlusVehicle",
        Utils.getFilename("scripts/CruiseControlPlusVehicle.lua", g_currentModDirectory),
        nil
    )
end

function CruiseControlPlusRegister.registerToVehicleTypes()
    if not CruiseControlPlusVehicle or not g_vehicleTypeManager or not g_vehicleTypeManager.types then return end
    local specName = CruiseControlPlusVehicle.specName
    local count = 0
    for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
        if typeDef ~= nil and vehicleType ~= "horse" and not typeDef.hasCruiseControlPlusSpec then
            if CruiseControlPlusVehicle.prerequisitesPresent(typeDef.specializations) then
                if typeDef.specializationsByName == nil or typeDef.specializationsByName[specName] == nil then
                    g_vehicleTypeManager:addSpecialization(vehicleType, specName)
                    typeDef.hasCruiseControlPlusSpec = true
                    count = count + 1
                end
            end
        end
    end
    if Logging then Logging.info("[CruiseControlPlus] registered spec to %d vehicle types", count) end
end

function CruiseControlPlusValidateVehicleTypes(TypeManager)
    CruiseControlPlusRegister.registerToVehicleTypes()
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
    end
    function modInstance:draw(dt)
        if not self.mission or not self.mission.hud then return end
        if self.mission.hud.isMenuVisible or g_noHudModeEnabled then return end
        if CruiseControlPlus and CruiseControlPlus.draw then
            CruiseControlPlus:draw(dt)
        end
    end
    function modInstance:update(dt)
        if self.controlledVehicle then
            local v = self.controlledVehicle
            if v.getIsControlled and not v:getIsControlled() then
                self.controlledVehicle = nil
            end
        end
    end
    function modInstance:loadMap(name)
        if CruiseControlPlusSettings and CruiseControlPlusSettings.loadFromXML then
            CruiseControlPlusSettings:loadFromXML()
        end
        if CruiseControlPlus and CruiseControlPlus.loadMap then
            CruiseControlPlus:loadMap(name)
        end
    end
    function modInstance:delete()
        if CruiseControlPlusSettings and CruiseControlPlusSettings.saveToXML then
            CruiseControlPlusSettings:saveToXML()
        end
        if g_currentMission then g_currentMission.cruiseControlPlus = nil end
        modInstance = nil
    end

    mission.cruiseControlPlus = modInstance
    addModEventListener(modInstance)

    if Logging then Logging.info("[CruiseControlPlus] mod instance created") end
end

local function onUnload()
    if modInstance then modInstance:delete() end
end

local function init()
    if not g_currentModName or g_currentModName ~= "FS25_CruiseControlPlus" then return end
    if TypeManager and TypeManager.validateTypes then
        TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, CruiseControlPlusValidateVehicleTypes)
    end
    if Mission00 and Mission00.load then
        Mission00.load = Utils.prependedFunction(Mission00.load, function(mission)
            createModInstance(mission)
        end)
    end
    if FSBaseMission and FSBaseMission.delete then
        FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, onUnload)
    end
    CruiseControlPlusRegister.registerToVehicleTypes()
    if Logging then Logging.info("[CruiseControlPlus] init complete") end
end

init()
