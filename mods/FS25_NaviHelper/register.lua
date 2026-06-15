--[[
  register.lua
  Bootstrap for FS25 NaviHelper. Loads scripts and registers the vehicle specialization
  with all driveable vehicles at runtime (same pattern as FS25_AutoDrive).
]]

source(Utils.getFilename("scripts/Settings.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/AutoDriveBridge.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/NaviHelper.lua", g_currentModDirectory))
source(Utils.getFilename("scripts/NaviHelperVehicle.lua", g_currentModDirectory))

NaviHelperRegister = {}

if NaviHelperVehicle.specName == nil then
    NaviHelperVehicle.specName = g_currentModName and (g_currentModName .. ".NaviHelperVehicle") or "FS25_NaviHelper.NaviHelperVehicle"
end

if g_specializationManager and g_specializationManager:getSpecializationByName("NaviHelperVehicle") == nil then
    g_specializationManager:addSpecialization(
        "NaviHelperVehicle",
        "NaviHelperVehicle",
        Utils.getFilename("scripts/NaviHelperVehicle.lua", g_currentModDirectory),
        nil
    )
end

function NaviHelperRegister.registerNaviHelperToVehicleTypes()
    if NaviHelperVehicle == nil then
        if Logging then Logging.info("[NaviHelper] registerNaviHelperToVehicleTypes: NaviHelperVehicle nil") end
        return
    end
    if not g_vehicleTypeManager or not g_vehicleTypeManager.types then
        if Logging then Logging.info("[NaviHelper] registerNaviHelperToVehicleTypes: no vehicleTypeManager or types") end
        return
    end
    local specName = NaviHelperVehicle.specName
    local count = 0
    for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
        if typeDef ~= nil and vehicleType ~= "horse" and not typeDef.hasNaviHelperSpec then
            if NaviHelperVehicle.prerequisitesPresent(typeDef.specializations) then
                if typeDef.specializationsByName == nil or typeDef.specializationsByName[specName] == nil then
                    g_vehicleTypeManager:addSpecialization(vehicleType, specName)
                    typeDef.hasNaviHelperSpec = true
                    count = count + 1
                end
            end
        end
    end
    if Logging then Logging.info("[NaviHelper] registerNaviHelperToVehicleTypes: added spec to %d vehicle types", count) end
end

function NaviHelperValidateVehicleTypes(TypeManager)
    -- Hook runs when game validates types; ensure our spec is on all driveable vehicles
    NaviHelperRegister.registerNaviHelperToVehicleTypes()
end

local function check()
    if not g_currentModName or g_currentModName ~= "FS25_NaviHelper" then
        if Logging then Logging.info("[NaviHelper] check() skip: g_currentModName=%s", tostring(g_currentModName)) end
        return
    end
    if Logging then
        local n = 0
        if g_vehicleTypeManager and g_vehicleTypeManager.types then
            for _ in pairs(g_vehicleTypeManager.types) do n = n + 1 end
        end
        Logging.info("[NaviHelper] check() running; vehicleTypeManager.types count=%d", n)
    end
    if TypeManager and TypeManager.validateTypes then
        TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, NaviHelperValidateVehicleTypes)
    end
    -- NaviHelper registers itself as mod event listener at the end of NaviHelper.lua
    -- (canonical self-registration). Do NOT add it again here, or update()/draw() run twice per frame.
    NaviHelperRegister.registerNaviHelperToVehicleTypes()
end

check()
