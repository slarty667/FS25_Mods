--[[
  AutoTramlineOff.lua

  Goal: contract/mission fields should never carry tramlines ("Fahrgassen").
  Fields spawned for field missions (fertilize, spray/herbicide, hoe, weed) come
  with tramlines the player never asked for and that trigger recurring mission
  bugs (e.g. roller/field missions stuck near 100%). This mod strips those
  tramlines automatically, with zero interaction:

    * new missions  -> hooked via AbstractMission:finishedPreparing() (server side,
                       fires once the mission has its field data ready).
    * existing ones -> swept on load (MissionManager:loadFromXMLFile + an immediate
                       sweep in loadMap), plus an on-demand console command.

  Standalone: it uses Precision Farming's own tramline API directly, so the only
  dependency is FS25_precisionFarming. The reset mirrors how Precision Farming
  itself clears a farmland's tramlines:
      - enqueue a TramlineMapDensityMapTask for the farmland (wipes the tramlines),
      - then refresh the field foliage over the field polygon so the strips fill in
        with the current crop again.

  Fail-safe by design: every step is nil-guarded and pcall-wrapped; if the PF API
  is missing the mod simply does nothing and logs once. Single-player correct
  (g_server present); multiplayer clients are not separately synced in this version.
]]

AutoTramlineOff = {}

AutoTramlineOff.MOD_NAME = "FS25_AutoTramlineOffForMissions"
AutoTramlineOff.installed = false

-- Mission types that carry tramlines on their (already grown) field. Resolved to
-- their .NAME values at install time; unknown/absent classes are skipped safely.
AutoTramlineOff.CANDIDATE_CLASSES = { "FertilizeMission", "HerbicideMission", "HoeMission", "WeedMission" }
AutoTramlineOff.tramlineMissionNames = nil

-- Above this field completion we leave the field alone (the player is already
-- working it); mirrors the guard Precision Farming tooling uses.
AutoTramlineOff.MAX_COMPLETION_FOR_RESET = 0.0005

AutoTramlineOff._warnedNoPF = false

--- Minimal logger wrappers (English, prefixed). Fall back silently if Logging is absent.
local function logInfo(fmt, ...)
    if Logging ~= nil and Logging.info ~= nil then
        Logging.info("[AutoTramlineOff] " .. fmt, ...)
    end
end

local function logWarn(fmt, ...)
    if Logging ~= nil and Logging.warning ~= nil then
        Logging.warning("[AutoTramlineOff] " .. fmt, ...)
    end
end

--- Build the set of tramline-carrying mission type names from whatever classes exist.
local function buildTramlineMissionNames()
    local names = {}
    for _, className in ipairs(AutoTramlineOff.CANDIDATE_CLASSES) do
        local cls = _G[className]
        if cls ~= nil and cls.NAME ~= nil then
            names[cls.NAME] = true
        end
    end
    return names
end

--- True if the Precision Farming API needed for the reset is available.
function AutoTramlineOff.isPrecisionFarmingReady()
    if FS25_precisionFarming == nil
        or FS25_precisionFarming.TramlineMapDensityMapTask == nil
        or g_fieldManager == nil then
        if not AutoTramlineOff._warnedNoPF then
            logWarn("Precision Farming API not available - tramline reset disabled")
            AutoTramlineOff._warnedNoPF = true
        end
        return false
    end
    return true
end

--- Turn off Precision Farming's tramline generation for NPC / AI fields at the source.
--- PF decides which fruit types get tramlines on non-player fields via
--- tramlineMap.npcFieldFruitTypes (an entry that is nil or false => no tramlines).
--- Emptying it means no *new* NPC/contract tramlines are ever generated, while the
--- player's own seeder-created tramlines are unaffected (they do not use this table).
--- Returns true if the table was found and neutralised.
function AutoTramlineOff.disableNpcTramlineGeneration()
    if FS25_precisionFarming == nil then
        return false
    end
    local pf = FS25_precisionFarming.g_precisionFarming
    if pf == nil or pf.tramlineMap == nil or pf.tramlineMap.npcFieldFruitTypes == nil then
        return false
    end

    local n = 0
    for fruitTypeIndex in pairs(pf.tramlineMap.npcFieldFruitTypes) do
        pf.tramlineMap.npcFieldFruitTypes[fruitTypeIndex] = false
        n = n + 1
    end
    logInfo("disabled NPC-field tramline generation for %d fruit type(s)", n)
    return true
end

--- Clear all tramlines of one farmland and refresh its field foliage.
--- Uses Precision Farming's own density-map task + the base field update task.
--- Server side only (guarded by callers). Returns true on success.
local function resetFarmlandTramlines(farmlandId)
    local field = g_fieldManager:getFieldById(farmlandId)
    if field == nil or field.getFieldState == nil or field.getDensityMapPolygon == nil then
        return false
    end

    local fieldState = field:getFieldState()
    if fieldState == nil then
        return false
    end

    -- 1) wipe the tramline density map for this farmland
    local tramlineTask = FS25_precisionFarming.TramlineMapDensityMapTask.new()
    tramlineTask:setData(farmlandId)
    tramlineTask:enqueue(true)

    -- 2) refresh the field foliage over the field polygon so the strips fill back in
    local fieldTask = fieldState:createFieldUpdateTask()
    fieldTask:setArea(field:getDensityMapPolygon())
    g_fieldManager:addFieldUpdateTask(fieldTask)

    return true
end

--- Resolve the farmland id a mission's field belongs to.
local function getMissionFarmlandId(mission)
    if mission == nil then
        return nil
    end
    if mission.field ~= nil and mission.field.farmland ~= nil and mission.field.farmland.id ~= nil then
        return mission.field.farmland.id
    end
    if mission.getFarmlandId ~= nil then
        return mission:getFarmlandId()
    end
    return nil
end

--- True if this mission is a tramline-carrying field mission that is still untouched.
local function shouldResetMission(mission)
    if mission == nil or mission.getMissionTypeName == nil then
        return false
    end

    local ok, typeName = pcall(mission.getMissionTypeName, mission)
    if not ok or typeName == nil then
        return false
    end
    if AutoTramlineOff.tramlineMissionNames == nil or AutoTramlineOff.tramlineMissionNames[typeName] ~= true then
        return false
    end

    -- Do not touch a field the player has already started working.
    if mission.completionPartitions ~= nil and mission.getFieldCompletion ~= nil then
        local okC, completion = pcall(mission.getFieldCompletion, mission)
        if okC and type(completion) == "number" and completion > AutoTramlineOff.MAX_COMPLETION_FOR_RESET then
            return false
        end
    end

    return true
end

--- Try to strip tramlines from a single mission's field. Returns true if a reset was issued.
function AutoTramlineOff.tryResetMission(mission)
    if g_server == nil then
        return false
    end
    if not AutoTramlineOff.isPrecisionFarmingReady() then
        return false
    end
    if mission._samAutoTramlineDone then
        return false
    end
    if not shouldResetMission(mission) then
        return false
    end

    local farmlandId = getMissionFarmlandId(mission)
    if farmlandId == nil then
        return false
    end

    local ok, result = pcall(resetFarmlandTramlines, farmlandId)
    if not ok then
        logWarn("reset failed for farmland %s: %s", tostring(farmlandId), tostring(result))
        return false
    end
    if result ~= true then
        return false
    end

    mission._samAutoTramlineDone = true
    logInfo("cleared tramlines on contract field (farmland %s, %s)", tostring(farmlandId), tostring(mission:getMissionTypeName()))
    return true
end

--- Hook body: appended to AbstractMission:finishedPreparing() (server only).
function AutoTramlineOff.onMissionFinishedPreparing(mission)
    if g_server == nil then
        return
    end
    AutoTramlineOff.tryResetMission(mission)
end

--- Sweep every currently-known mission once (used on load and via console command).
function AutoTramlineOff.sweepAllMissions()
    if g_server == nil then
        return 0
    end
    if g_missionManager == nil or g_missionManager.missions == nil then
        return 0
    end

    local count = 0
    for _, mission in ipairs(g_missionManager.missions) do
        if AutoTramlineOff.tryResetMission(mission) then
            count = count + 1
        end
    end
    if count > 0 then
        logInfo("sweep processed %d contract field(s)", count)
    end
    return count
end

--- One-time clear of tramlines on ALL farmlands NOT owned by the player (NPC / AI
--- fields, including contract fields and idle NPC fields like the ones shown as
--- "Gehoert: <name>"). This complements lever 1 by removing tramlines that were
--- already baked into the current savegame before generation was disabled.
--- Player-owned farmland is left untouched (the player may want their own tramlines).
--- Ownership API verified from FS25_FarmlandOverview / FS25_FarmlandMarket:
---   g_farmlandManager.farmlands (list), farmland.id, farmland.farmId,
---   FarmlandManager.NO_OWNER_FARM_ID (unowned).
function AutoTramlineOff.sweepAllNpcFarmlands()
    if g_server == nil then
        return 0
    end
    if not AutoTramlineOff.isPrecisionFarmingReady() then
        return 0
    end
    if g_farmlandManager == nil or g_farmlandManager.farmlands == nil then
        return 0
    end

    local noOwner = (FarmlandManager ~= nil and FarmlandManager.NO_OWNER_FARM_ID) or 0
    local count = 0
    for _, farmland in pairs(g_farmlandManager.farmlands) do
        if farmland ~= nil and farmland.id ~= nil and farmland.farmId == noOwner then
            local ok, result = pcall(resetFarmlandTramlines, farmland.id)
            if ok and result == true then
                count = count + 1
            end
        end
    end
    if count > 0 then
        logInfo("cleared tramlines on %d NPC/unowned field(s)", count)
    end
    return count
end

--- Console command handler: force a full re-sweep (clears the per-mission done flag first).
function AutoTramlineOff:consoleCommandSweep()
    if g_missionManager ~= nil and g_missionManager.missions ~= nil then
        for _, mission in ipairs(g_missionManager.missions) do
            mission._samAutoTramlineDone = nil
        end
    end
    local contractCount = AutoTramlineOff.sweepAllMissions()
    local npcCount = AutoTramlineOff.sweepAllNpcFarmlands()
    return string.format("AutoTramlineOff: reset tramlines on %d contract field(s) + %d NPC field(s)", contractCount, npcCount)
end

--- Install all hooks. Idempotent.
function AutoTramlineOff.install()
    if AutoTramlineOff.installed then
        return
    end

    AutoTramlineOff.tramlineMissionNames = buildTramlineMissionNames()

    -- Lever 1: stop PF from generating tramlines on NPC / contract fields at all.
    AutoTramlineOff.disableNpcTramlineGeneration()

    -- Lever 2 (below): still strip tramlines from contract fields, so already-baked
    -- fields and any that slip past lever 1 are handled with a verified API path.

    -- New missions: fires once the mission has finished preparing its field data.
    if AbstractMission ~= nil and AbstractMission.finishedPreparing ~= nil then
        AbstractMission.finishedPreparing = Utils.appendedFunction(AbstractMission.finishedPreparing, AutoTramlineOff.onMissionFinishedPreparing)
    else
        logWarn("AbstractMission.finishedPreparing not found - new missions only caught by load sweep / console")
    end

    -- Existing missions on a loaded savegame: sweep once after the mission list is read.
    if MissionManager ~= nil and MissionManager.loadFromXMLFile ~= nil then
        MissionManager.loadFromXMLFile = Utils.appendedFunction(MissionManager.loadFromXMLFile, function()
            AutoTramlineOff.sweepAllMissions()
        end)
    end

    -- Manual fallback / verification.
    if addConsoleCommand ~= nil then
        addConsoleCommand("samAutoTramlineSweep", "Reset tramlines on all current contract fields", "consoleCommandSweep", AutoTramlineOff)
    end

    AutoTramlineOff.installed = true
    logInfo("installed (targets: %s)", table.concat(AutoTramlineOff.CANDIDATE_CLASSES, ", "))
end

--- Mod event listener entry point. FS calls this once the map is loaded and every
--- base gameplay class exists; a safe, early-enough install point (before missions
--- are generated). Also performs one immediate sweep as a belt-and-suspenders catch
--- for missions that may already be present depending on load order.
function AutoTramlineOff:loadMap(filename)
    AutoTramlineOff.install()
    AutoTramlineOff.sweepAllMissions()
    -- NOTE: the mass NPC-field clear is intentionally NOT run here. It is a one-time
    -- migration for savegames that already have baked-in tramlines; re-running it every
    -- load would re-enqueue a field-foliage rebuild for every unowned field (a heavy
    -- load-time hitch) for no benefit, since existing ones are cleared + saved and
    -- lever 1 prevents new ones. Trigger it on demand via the console command
    -- "samAutoTramlineSweep" if a stray tramline ever shows up.
end

addModEventListener(AutoTramlineOff)
