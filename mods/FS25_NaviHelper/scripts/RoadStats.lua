--[[
  RoadStats.lua
  R0 spike (NaviHelper Vanilla-Spline-Router): measure the map's built-in AI road
  network (g_currentMission.aiSystem.roadSplines) WITHOUT building any router yet.
  Logging only — this is the go/no-go probe for whether a vanilla-spline router is
  worth building on the small maps the user actually plays.

  Outputs (to log.txt): spline count, total network length, bounding extent vs. the
  terrain size (does the net span the map or just one road?), and field count for
  context. Trigger: auto once a few seconds after load, plus console command
  "nhRoadStats" for on-demand re-measure.
]]

RoadStats = {}
RoadStats.LOG_PREFIX = "[NaviHelper/R0]"
RoadStats._autoLogged = false
RoadStats._autoLogAtMs = nil

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(RoadStats.LOG_PREFIX .. " " .. fmt, ...)
    end
end

-- Count fields defensively across possible FieldManager shapes (for context only).
local function countFields()
    local fm = g_fieldManager
    if fm == nil then return -1 end
    if type(fm.getFields) == "function" then
        local ok, fields = pcall(fm.getFields, fm)
        if ok and type(fields) == "table" then
            local n = 0
            for _ in pairs(fields) do n = n + 1 end
            return n
        end
    end
    if type(fm.fields) == "table" then
        local n = 0
        for _ in pairs(fm.fields) do n = n + 1 end
        return n
    end
    if type(fm.numberOfFields) == "number" then return fm.numberOfFields end
    return -1
end

-- Measure the vanilla AI road-spline network. Returns a stats table or nil + reason.
function RoadStats.compute()
    local mission = g_currentMission
    if mission == nil then return nil, "no g_currentMission" end
    local ai = mission.aiSystem
    if ai == nil then return nil, "no g_currentMission.aiSystem" end
    local splines = ai.roadSplines
    if splines == nil then return nil, "no aiSystem.roadSplines" end

    local count, totalLen, zeroLen = 0, 0, 0
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    local samplePts = 0

    for _, spline in pairs(splines) do
        count = count + 1
        local len = (getSplineLength ~= nil) and getSplineLength(spline) or 0
        len = len or 0
        totalLen = totalLen + len
        if len <= 0 then zeroLen = zeroLen + 1 end
        if getSplinePosition ~= nil then
            for i = 0, 4 do
                local t = i / 4
                local x, _, z = getSplinePosition(spline, t)
                if x ~= nil and z ~= nil then
                    samplePts = samplePts + 1
                    if x < minX then minX = x end
                    if x > maxX then maxX = x end
                    if z < minZ then minZ = z end
                    if z > maxZ then maxZ = z end
                end
            end
        end
    end

    local terrain = mission.terrainSize or 0
    local spanX = (maxX > -math.huge) and (maxX - minX) or 0
    local spanZ = (maxZ > -math.huge) and (maxZ - minZ) or 0

    return {
        count = count,
        totalLen = totalLen,
        zeroLen = zeroLen,
        terrain = terrain,
        spanX = spanX,
        spanZ = spanZ,
        samplePts = samplePts,
        fields = countFields(),
    }
end

function RoadStats.logNow(trigger)
    local s, reason = RoadStats.compute()
    local mapTitle = (g_currentMission and g_currentMission.missionInfo and g_currentMission.missionInfo.mapTitle)
        or (g_currentMission and g_currentMission.mapTitle) or "?"
    if s == nil then
        log("map=%s — KEIN Netz messbar (%s)", tostring(mapTitle), tostring(reason))
        return ("RoadStats: kein Netz (" .. tostring(reason) .. ")")
    end
    -- Coverage hint: how much of the terrain square the network spans.
    local covX = (s.terrain > 0) and (s.spanX / s.terrain * 100) or 0
    local covZ = (s.terrain > 0) and (s.spanZ / s.terrain * 100) or 0
    log("map=%s trigger=%s", tostring(mapTitle), tostring(trigger or "?"))
    log("  splines=%d (davon 0-Laenge=%d)  Gesamtlaenge=%.0f m  Sample-Punkte=%d",
        s.count, s.zeroLen, s.totalLen, s.samplePts)
    log("  Netz-Ausdehnung=%.0f x %.0f m  Terrain=%.0f m  Abdeckung~%.0f%% x %.0f%%  Felder=%d",
        s.spanX, s.spanZ, s.terrain, covX, covZ, s.fields)
    return string.format("RoadStats %s: %d Splines, %.0f m, Abdeckung ~%.0f%%x%.0f%%, %d Felder",
        tostring(mapTitle), s.count, s.totalLen, covX, covZ, s.fields)
end

-- Auto-log once, a few seconds after load (roadSplines may populate after loadMap).
function RoadStats.maybeAutoLog()
    if RoadStats._autoLogged then return end
    local t = g_currentMission and g_currentMission.time
    if t == nil then return end
    if RoadStats._autoLogAtMs == nil then
        RoadStats._autoLogAtMs = t + 6000  -- wait ~6s into the session
        return
    end
    if t >= RoadStats._autoLogAtMs then
        RoadStats._autoLogged = true
        RoadStats.logNow("auto")
    end
end

-- On-demand console command.
function RoadStats:consoleRoadStats()
    return RoadStats.logNow("console")
end

-- ---------------------------------------------------------------------------
-- Data-source probe: dump what FS25 exposes Lua-side beyond roadSplines, to decide
-- whether richer road/field-access data exists (village streets, field tracks).
-- ---------------------------------------------------------------------------

local function tableKeys(t, wantFunctions)
    local out = {}
    for k, v in pairs(t) do
        local ty = type(v)
        if (wantFunctions and ty == "function") or (not wantFunctions and ty ~= "function") then
            local extra = ""
            if ty == "table" then
                local n = 0
                for _ in pairs(v) do n = n + 1 end
                extra = " #" .. n
            end
            out[#out + 1] = tostring(k) .. "(" .. ty .. extra .. ")"
        end
    end
    table.sort(out)
    return out
end

function RoadStats.probe()
    log("PROBE start ----------------------------------------")
    local m = g_currentMission
    local ai = m and m.aiSystem
    if ai ~= nil then
        log("aiSystem fields: %s", table.concat(tableKeys(ai, false), ", "))
        local mt = getmetatable(ai)
        if mt ~= nil and type(mt.__index) == "table" then
            log("aiSystem methods: %s", table.concat(tableKeys(mt.__index, true), ", "))
        end
    else
        log("no aiSystem")
    end

    -- Globals / engine functions of interest (pathfinder, spline, navigation).
    local names = {
        "AIPathFinder", "PathFinderModule", "createPathFinder", "AISystem",
        "AINetwork", "getSplinePosition", "getSplineLength", "getSplineTime",
        "AITargetNode", "AIVehicleUtil", "PathfindingModule", "g_densityMapHeightManager",
    }
    local found = {}
    for _, n in ipairs(names) do found[#found + 1] = n .. "=" .. tostring(_G[n] ~= nil) end
    log("globals: %s", table.concat(found, ", "))

    -- Sample field: does FS25 expose an access point / entrance per field?
    local fm = g_fieldManager
    if fm ~= nil then
        local fields = (type(fm.getFields) == "function" and fm:getFields()) or fm.fields
        if type(fields) == "table" then
            for _, f in pairs(fields) do
                if type(f) == "table" then
                    log("sample field fields: %s", table.concat(tableKeys(f, false), ", "))
                    break
                end
            end
        end
    end
    log("PROBE end ------------------------------------------")
    return "Probe ins Log geschrieben"
end

function RoadStats:consoleProbe()
    return RoadStats.probe()
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhRoadStats", "NaviHelper R0: Vanilla-Strassennetz vermessen", "consoleRoadStats", RoadStats)
    addConsoleCommand("nhProbe", "NaviHelper: aiSystem/Feld-Datenquellen dumpen", "consoleProbe", RoadStats)
end
