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

-- Probe the AI navigationMap: is it a readable bit-vector/density map, at what
-- resolution, and what does a sample point near the player read? This decides
-- whether we can A* over the drivability grid (full coverage) instead of splines.
function RoadStats.probeNav()
    local m = g_currentMission
    local ai = m and m.aiSystem
    if ai == nil then log("NAVPROBE: no aiSystem"); return "no aiSystem" end
    log("NAVPROBE cellSizeMeters=%s navigationMap=%s infoLayerName=%s infoLayerChannel=%s terrainSize=%s",
        tostring(ai.cellSizeMeters), tostring(ai.navigationMap), tostring(ai.infoLayerName),
        tostring(ai.infoLayerChannel), tostring(m.terrainSize))
    log("NAVPROBE masks: aiDrivable=%s obstacle=%s maxSlope=%s",
        tostring(ai.aiDrivableCollisionMask), tostring(ai.obstacleCollisionMask), tostring(ai.maxSlopeAngle))

    local fns = { "getBitVectorMapPoint", "getBitVectorMapSize", "getBitVectorMapNumChannels",
        "getDensityMapData", "getBitVectorMapPointsInRange", "getDensityMapHeightAtWorldPos" }
    local f = {}
    for _, n in ipairs(fns) do f[#f + 1] = n .. "=" .. tostring(_G[n] ~= nil) end
    log("NAVPROBE fns: %s", table.concat(f, ", "))

    local nav = ai.navigationMap
    local cs = ai.cellSizeMeters or 1
    local ts = m.terrainSize or 2048
    if _G.getBitVectorMapPoint == nil or nav == nil then
        log("NAVPROBE: getBitVectorMapPoint/nav fehlt — nicht lesbar")
        return "navigationMap nicht lesbar"
    end

    local okC, numCh = pcall(getBitVectorMapNumChannels, nav)
    log("NAVPROBE numChannels ok=%s val=%s (cellSize=%s terrain=%s -> grid~%dx%d)",
        tostring(okC), tostring(numCh), tostring(cs), tostring(ts), math.floor(ts / cs), math.floor(ts / cs))
    numCh = (okC and numCh) or 1

    -- Find the correct getBitVectorMapPoint signature: try several call shapes at a
    -- center cell and log the actual error / returned value for each.
    local cx = math.floor((0 + ts / 2) / cs)
    local cz = math.floor((0 + ts / 2) / cs)
    local function try(label, ...)
        local res = { pcall(getBitVectorMapPoint, ...) }
        local ok = res[1]
        if ok then
            log("NAVPROBE try %s -> OK val=%s", label, tostring(res[2]))
        else
            log("NAVPROBE try %s -> ERR %s", label, tostring(res[2]))
        end
        return ok, res[2]
    end
    log("NAVPROBE center cell = %d,%d", cx, cz)
    try("(id,x,z)", nav, cx, cz)
    try("(id,x,z,0,1)", nav, cx, cz, 0, 1)

    -- navigationMap is collision geometry, not a readable bitmap. Last hope: does the
    -- AISystem class (or globals) expose a drivability/pathfinding method we can use?
    local function fnKeys(t)
        local out = {}
        if type(t) == "table" then
            for k, v in pairs(t) do if type(v) == "function" then out[#out + 1] = tostring(k) end end
            table.sort(out)
        end
        return out
    end
    if _G.AISystem ~= nil then
        log("NAVPROBE AISystem methods: %s", table.concat(fnKeys(AISystem), ", "))
    end
    local mt = getmetatable(ai)
    if mt ~= nil and type(mt.__index) == "table" then
        log("NAVPROBE ai instance methods: %s", table.concat(fnKeys(mt.__index), ", "))
    end
    -- collision-based drivability primitives that a grid-bake could (slowly) use
    local prims = { "overlapBox", "overlapSphere", "collisionRaycast", "raycastClosest", "AIVehicleUtil" }
    local p = {}
    for _, n in ipairs(prims) do p[#p + 1] = n .. "=" .. tostring(_G[n] ~= nil) end
    log("NAVPROBE collision prims: %s", table.concat(p, ", "))
    return "NavProbe-Methodendump ins Log"
end

function RoadStats:consoleProbeNav()
    return RoadStats.probeNav()
end

-- G0 spike: is AISystem:getIsPositionReachable a usable, cheap drivability oracle?
-- Find its signature, sanity-check at the player's spot, then sweep the map and tally
-- reachable vs. not — and time it to pick a bake resolution.
function RoadStats.probeReach()
    local m = g_currentMission
    local ai = m and m.aiSystem
    if ai == nil or ai.getIsPositionReachable == nil then
        log("REACH: getIsPositionReachable fehlt"); return "getIsPositionReachable fehlt"
    end
    local ts = m.terrainSize or 2048
    local function terrainY(x, z)
        if _G.getTerrainHeightAtWorldPos ~= nil and m.terrainRootNode ~= nil then
            local ok, h = pcall(getTerrainHeightAtWorldPos, m.terrainRootNode, x, 0, z)
            if ok and h ~= nil then return h end
        end
        return 0
    end

    local tx, tz = 0, 0
    local v = m.controlledVehicle
    if v ~= nil and v.rootNode ~= nil then local x, _, z = getWorldTranslation(v.rootNode); tx, tz = x, z end
    local ty = terrainY(tx, tz)
    log("REACH testpoint world=%.1f,%.1f,%.1f (im Fahrzeug=%s)", tx, ty, tz, tostring(v ~= nil))

    -- candidate signatures -> a (x,z)->value caller each
    local callers = {
        { "(x,z)",     function(x, z) return ai:getIsPositionReachable(x, z) end },
        { "(x,y,z)",   function(x, z) return ai:getIsPositionReachable(x, terrainY(x, z), z) end },
        { "(x,z,0)",   function(x, z) return ai:getIsPositionReachable(x, z, 0) end },
        { "(x,y,z,0)", function(x, z) return ai:getIsPositionReachable(x, terrainY(x, z), z, 0) end },
    }
    local caller = nil
    for _, c in ipairs(callers) do
        local r = { pcall(c[2], tx, tz) }
        if r[1] then
            log("REACH sig %s -> OK %s", c[1], tostring(r[2]))
            if caller == nil then caller = c end
        else
            log("REACH sig %s -> ERR %s", c[1], tostring(r[2]))
        end
    end
    if caller == nil then return "REACH: keine Signatur funktioniert" end

    -- sweep + time it
    local step = 64
    local half = ts / 2
    local total, reach, errs = 0, 0, 0
    local t0 = (_G.getTimeSec ~= nil) and getTimeSec() or nil
    local wx = -half
    while wx <= half do
        local wz = -half
        while wz <= half do
            local ok, val = pcall(caller[2], wx, wz)
            if ok then
                total = total + 1
                if val == true or (type(val) == "number" and val ~= 0) then reach = reach + 1 end
            else
                errs = errs + 1
            end
            wz = wz + step
        end
        wx = wx + step
    end
    local dt = t0 and (getTimeSec() - t0) or nil
    log("REACH sweep sig=%s: %d Punkte, %d reachable (%.0f%%), %d Fehler%s",
        caller[1], total, reach, (total > 0 and reach / total * 100 or 0), errs,
        dt and string.format(", %.1f ms gesamt (~%.3f ms/Abfrage)", dt * 1000, total > 0 and dt * 1000 / total or 0) or "")
    return string.format("REACH: %d/%d reachable, sig=%s", reach, total, caller[1])
end

function RoadStats:consoleProbeReach()
    return RoadStats.probeReach()
end

-- Scan the scene graph (+ ai/traffic systems) for spline nodes — the WayPointGPS way.
-- Reports how much real road-spline data this map actually exposes, by name category,
-- so we know (before committing) whether non-traffic streets exist as splines here.
function RoadStats.probeSplines()
    local found = {}        -- {name, len}
    local total, scanned = 0, 0
    local cat = { road = 0, field = 0, water = 0, other = 0 }
    local sumLen = 0

    local function isSplineShape(node)
        if type(node) ~= "number" or node <= 0 then return false end
        if entityExists ~= nil then local ok, e = pcall(entityExists, node); if not ok or not e then return false end end
        if getHasClassId ~= nil and ClassIds ~= nil and ClassIds.SHAPE ~= nil then
            local ok, isShape = pcall(getHasClassId, node, ClassIds.SHAPE)
            if not ok or not isShape then return false end
        end
        if getSplineLength == nil then return false end
        local ok, len = pcall(getSplineLength, node)
        if not ok or type(len) ~= "number" or len <= 0 then return false end
        return true, len
    end

    local function consider(node, path)
        local ok, len = isSplineShape(node)
        if not ok then return end
        total = total + 1; sumLen = sumLen + len
        local p = string.lower(path)
        if p:find("field") or p:find("workarea") then cat.field = cat.field + 1
        elseif p:find("water") or p:find("river") or p:find("rail") then cat.water = cat.water + 1
        elseif p:find("road") or p:find("street") or p:find("drive") or p:find("traffic") or p:find("vehicle") or p:find("ai") then cat.road = cat.road + 1
        else cat.other = cat.other + 1 end
        if #found < 30 then found[#found + 1] = string.format("%s(%.0fm)", path, len) end
    end

    local function walk(node, path, depth)
        if node == nil or depth > 14 or scanned > 60000 then return end
        scanned = scanned + 1
        local name = (getName ~= nil and select(1, pcall(getName, node))) and getName(node) or "?"
        local np = (path ~= "" and (path .. "/" .. name)) or name
        consider(node, np)
        if getNumOfChildren == nil or getChildAt == nil then return end
        local ok, n = pcall(getNumOfChildren, node)
        if not ok or type(n) ~= "number" then return end
        for i = 0, n - 1 do
            local okc, c = pcall(getChildAt, node, i)
            if okc and c ~= nil then walk(c, np, depth + 1) end
        end
    end

    local m = g_currentMission
    for _, r in ipairs({ m and m.terrainRootNode, m and m.rootNode, m and m.mapRootNode }) do
        if r ~= nil then walk(r, "", 0) end
    end
    log("SPLINES (Szenen-Scan): %d gesamt, ~%.0fm | road/street=%d field=%d water/rail=%d other=%d (gescannt=%d)",
        total, sumLen, cat.road, cat.field, cat.water, cat.other, scanned)

    -- Direct table scan (bypass SHAPE check) of aiSystem.roadSplines + trafficSystem,
    -- so we know the real spline inventory independent of the scene walk.
    local function tableSplineStats(tbl)
        local c, l = 0, 0
        if type(tbl) ~= "table" or getSplineLength == nil then return c, l end
        for _, node in pairs(tbl) do
            if type(node) == "number" then
                local ok, len = pcall(getSplineLength, node)
                if ok and type(len) == "number" and len > 0 then c = c + 1; l = l + len end
            end
        end
        return c, l
    end
    if m ~= nil and m.aiSystem ~= nil then
        local c, l = tableSplineStats(m.aiSystem.roadSplines)
        log("  aiSystem.roadSplines direkt: %d Splines, %.0fm", c, l)
    end
    if m ~= nil and m.trafficSystem ~= nil then
        local ts = m.trafficSystem
        for _, key in ipairs({ "splines", "roadSplines", "paths", "spline" }) do
            local c, l = tableSplineStats(ts[key])
            if c > 0 then log("  trafficSystem.%s: %d Splines, %.0fm", key, c, l) end
        end
        -- list trafficSystem table keys for orientation
        local keys = {}
        for k, v in pairs(ts) do keys[#keys + 1] = tostring(k) .. "(" .. type(v) .. ")" end
        table.sort(keys)
        log("  trafficSystem keys: %s", table.concat(keys, ", "))
    end
    for i = 1, math.min(#found, 30) do log("  spline: %s", found[i]) end
    return string.format("SPLINES: %d gesamt, road=%d field=%d other=%d -> Log", total, cat.road, cat.field, cat.other)
end

function RoadStats:consoleProbeSplines()
    return RoadStats.probeSplines()
end

if addConsoleCommand ~= nil then
    addConsoleCommand("nhRoadStats", "NaviHelper R0: Vanilla-Strassennetz vermessen", "consoleRoadStats", RoadStats)
    addConsoleCommand("nhProbe", "NaviHelper: aiSystem/Feld-Datenquellen dumpen", "consoleProbe", RoadStats)
    addConsoleCommand("nhProbeNav", "NaviHelper: navigationMap lesbar? Aufloesung + Sample", "consoleProbeNav", RoadStats)
    addConsoleCommand("nhProbeReach", "NaviHelper G0: getIsPositionReachable als Drivability-Orakel testen", "consoleProbeReach", RoadStats)
    addConsoleCommand("nhSplines", "NaviHelper: Szenen-Graph nach Strassen-Splines scannen (WayPointGPS-Weg)", "consoleProbeSplines", RoadStats)
end
