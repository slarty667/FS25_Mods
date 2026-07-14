--[[
  register.lua
  Bootstrap for FS25_AutoTramlineOffForMissions.

  Only loads the main script. The script registers itself as a mod event listener
  and installs its hooks in loadMap(), where all base gameplay classes
  (AbstractMission, MissionManager, ...) are guaranteed to exist and missions have
  not been generated yet.
]]

source(Utils.getFilename("scripts/AutoTramlineOff.lua", g_currentModDirectory))
