--[[
  register.lua
  FS25_ControlsSearch – bootstrap. Loads one script and creates mod instance on Mission00.load.
]]

source(Utils.getFilename("scripts/ControlsSearch.lua", g_currentModDirectory))

ControlsSearchRegister = {}

local modInstance = nil

local function createModInstance(mission)
    if modInstance then return end
    modInstance = {
        mission = mission,
    }
    function modInstance:draw(dt)
        if ControlsSearch then ControlsSearch.draw(self) end
    end
    function modInstance:update(dt)
        if ControlsSearch then ControlsSearch.update(self, dt) end
    end
    function modInstance:keyEvent(unicode, sym, modifier, isDown)
        if ControlsSearch then ControlsSearch.keyEvent(self, unicode, sym, modifier, isDown) end
    end
    function modInstance:delete()
        if g_currentMission then g_currentMission.controlsSearch = nil end
        modInstance = nil
    end

    mission.controlsSearch = modInstance
    addModEventListener(modInstance)
    if Logging then Logging.info("[ControlsSearch] mod instance created") end
end

local function onUnload()
    if modInstance then modInstance:delete() end
end

local function init()
    if not g_currentModName or g_currentModName ~= "FS25_ControlsSearch" then return end
    if Mission00 and Mission00.load then
        Mission00.load = Utils.prependedFunction(Mission00.load, function(mission)
            createModInstance(mission)
        end)
    end
    if FSBaseMission and FSBaseMission.delete then
        FSBaseMission.delete = Utils.appendedFunction(FSBaseMission.delete, onUnload)
    end
    if Logging then Logging.info("[ControlsSearch] init complete") end
end

init()
