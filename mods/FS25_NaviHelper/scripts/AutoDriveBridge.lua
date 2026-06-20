--[[
  AutoDriveBridge.lua
  Safe bridge to FS25_AutoDrive for routing. Does not assume global name;
  discovers AD/ADGraphManager dynamically. Uses only verified APIs from
  ADGraphManager and ADPathCalculator (pathFromTo, getWayPoints, getWayPointsInRange).
]]

NaviHelperAD = {}
NaviHelperAD.cachedAD = nil
NaviHelperAD.cachedGraph = nil
NaviHelperAD.version = nil
NaviHelperAD._fieldCache = {}   -- per-waypoint "on field ground?" memo (static per map)

local LOG_PREFIX = "[NaviHelper]"

-- Identify AutoDrive by presence of ADGraphManager (required for routing)
local function findADGraphManager()
    if _G.ADGraphManager and type(_G.ADGraphManager) == "table" then
        local gm = _G.ADGraphManager
        if type(gm.getWayPoints) == "function" and type(gm.pathFromTo) == "function" then
            return gm
        end
    end
    local tryNames = { "FS25_AutoDrive", "AutoDrive" }
    for _, name in ipairs(tryNames) do
        local t = _G[name]
        if type(t) == "table" and t.ADGraphManager and type(t.ADGraphManager.getWayPoints) == "function" then
            return t.ADGraphManager
        end
    end
    for k, v in pairs(_G) do
        if type(v) == "table" and type(k) == "string" and (k:find("AutoDrive") or k:find("AD")) then
            if v.getWayPoints and type(v.getWayPoints) == "function" and v.pathFromTo and type(v.pathFromTo) == "function" then
                return v
            end
            if v.ADGraphManager and type(v.ADGraphManager) == "table" then
                local gm = v.ADGraphManager
                if type(gm.getWayPoints) == "function" and type(gm.pathFromTo) == "function" then
                    return gm
                end
            end
        end
    end
    return nil
end

-- Optional: get AutoDrive table for version string
local function findAutoDriveTable()
    if _G.AutoDrive and type(_G.AutoDrive) == "table" and type(_G.AutoDrive.version) == "string" then
        return _G.AutoDrive
    end
    for k, v in pairs(_G) do
        if type(v) == "table" and type(v.version) == "string" and (v.GetPath or v.GetClosestPointToLocation) then
            return v
        end
    end
    return nil
end

function NaviHelperAD.isAvailable()
    if NaviHelperAD.cachedGraph ~= nil then
        return NaviHelperAD.cachedGraph ~= false
    end
    local ok, gm = pcall(findADGraphManager)
    if ok and gm then
        NaviHelperAD.cachedGraph = gm
        local ad = findAutoDriveTable()
        NaviHelperAD.cachedAD = ad
        NaviHelperAD.version = ad and ad.version or "unknown"
        return true
    end
    NaviHelperAD.cachedGraph = false
    return false
end

-- Returns closest waypoint id to world (x, z) and its distance in metres, or nil.
local function closestNodeToWorld(gm, x, z, maxDist)
    maxDist = maxDist or 500
    local network = gm:getWayPoints()
    if not network or type(network) ~= "table" then return nil end
    local bestId, bestDist = nil, maxDist * maxDist
    for id, wp in pairs(network) do
        if wp and wp.x and wp.z then
            local dx, dz = wp.x - x, wp.z - z
            local d2 = dx * dx + dz * dz
            if d2 < bestDist then
                bestDist = d2
                bestId = id
            end
        end
    end
    if bestId == nil then return nil end
    return bestId, math.sqrt(bestDist)
end

-- Is a world point on cultivable field ground? (engine field data via FSDensityMapUtil)
local function isFieldAtWorld(wx, wz)
    local m = g_currentMission
    if m == nil then return false end
    local wy = 0
    if m.terrainRootNode ~= nil and getTerrainHeightAtWorldPos ~= nil then
        local ok, ty = pcall(getTerrainHeightAtWorldPos, m.terrainRootNode, wx, 0, wz)
        if ok and ty then wy = ty end
    end
    if FSDensityMapUtil ~= nil and type(FSDensityMapUtil.getFieldDataAtWorldPosition) == "function" then
        local ok, onField = pcall(FSDensityMapUtil.getFieldDataAtWorldPosition, wx, wy, wz)
        if ok and onField ~= nil then return onField == true end
    end
    return false
end

-- When the click is inside a field, AutoDrive's "F<NN>" field markers sit on the entrance the
-- course author placed. Return the waypoint id of the nearest such marker, so the route ends AT
-- the entrance instead of crawling the field-boundary loop. nil if not in a field / no markers.
local function fieldEntranceWaypointId(gm, x, z)
    if not isFieldAtWorld(x, z) then return nil end
    if type(gm.getMapMarkers) ~= "function" then return nil end
    local ok, markers = pcall(gm.getMapMarkers, gm)
    if not ok or type(markers) ~= "table" then return nil end
    local wps = gm:getWayPoints()
    if type(wps) ~= "table" then return nil end
    local bestId, bestName, bestD2 = nil, nil, math.huge
    for _, mk in pairs(markers) do
        if mk and mk.id and type(mk.name) == "string" and mk.name:match("^[Ff]%d") then
            local wp = wps[mk.id]
            if wp and wp.x and wp.z then
                local dx, dz = wp.x - x, wp.z - z
                local d2 = dx * dx + dz * dz
                if d2 < bestD2 then bestD2 = d2; bestId = mk.id; bestName = mk.name end
            end
        end
    end
    if bestId ~= nil and Logging and Logging.info then
        Logging.info("%s field-entrance -> marker %s (wp %s)", LOG_PREFIX, tostring(bestName), tostring(bestId))
    end
    return bestId
end

-- Nearest waypoint that is NOT on cultivable field ground. Field-boundary harvest loops sit on
-- the field (isFieldAtWorld), roads and field tracks do not — so this avoids snapping onto a
-- harvest loop (which makes AD spiral around the field). nil if none found. NOTE: this is the
-- correct discriminator; the earlier flags=0 filter was wrong (flags=1 covers BOTH harvest loops
-- AND drivable field tracks, so it also excluded the tracks and threw endpoints ~150 m off).
local function closestNonFieldNodeToWorld(gm, x, z, maxDist)
    maxDist = maxDist or 500
    local network = gm:getWayPoints()
    if type(network) ~= "table" then return nil end
    local bestId, bestD2 = nil, maxDist * maxDist
    for id, wp in pairs(network) do
        if wp and wp.x and wp.z then
            local dx, dz = wp.x - x, wp.z - z
            local d2 = dx * dx + dz * dz
            if d2 < bestD2 and not isFieldAtWorld(wp.x, wp.z) then
                bestD2 = d2; bestId = id
            end
        end
    end
    return bestId
end

-- Destination node: a click inside a field -> nearest "F.." field-entrance marker; otherwise the
-- nearest ROAD/TRACK waypoint (off cultivable ground), so the route doesn't snap onto a field
-- harvest loop and spiral around the field. Falls back to plain nearest node if needed.
local function resolveRoutingNode(gm, x, z, maxDist)
    local entranceId = fieldEntranceWaypointId(gm, x, z)
    if entranceId ~= nil then return entranceId end
    local nonField = closestNonFieldNodeToWorld(gm, x, z, maxDist)
    if nonField ~= nil then return nonField end
    return (closestNodeToWorld(gm, x, z, maxDist))
end

-- Heading-aware START node: prefer the nearest waypoint that lies AHEAD of the vehicle, so the
-- route continues in the current driving direction instead of opening with a U-turn (and starts
-- on the track the vehicle is already on). Falls back to the plain nearest node when no heading
-- is given or nothing suitable lies ahead.
local function startNodeToWorld(gm, x, z, headX, headZ, maxDist)
    maxDist = maxDist or 500
    if headX == nil or headZ == nil then return closestNodeToWorld(gm, x, z, maxDist) end
    local hl = math.sqrt(headX * headX + headZ * headZ)
    if hl < 1e-4 then return closestNodeToWorld(gm, x, z, maxDist) end
    local network = gm:getWayPoints()
    if not network or type(network) ~= "table" then return nil end
    local aheadId, aheadD2 = nil, maxDist * maxDist
    for id, wp in pairs(network) do
        if wp and wp.x and wp.z then
            local dx, dz = wp.x - x, wp.z - z
            local d2 = dx * dx + dz * dz
            if d2 > 0.01 and d2 < aheadD2 then
                local fwd = (dx * headX + dz * headZ) / hl   -- forward component along heading (m)
                if fwd > 0 then aheadD2 = d2; aheadId = id end  -- only consider nodes ahead
            end
        end
    end
    return aheadId or closestNodeToWorld(gm, x, z, maxDist)
end

-- ---------------------------------------------------------------------------------------------
-- Own UNDIRECTED A* over the AD waypoints. AutoDrive's pathFromTo is directed (obeys one-way
-- lanes) and freely traverses field harvest-loop nodes, so routes take the long way and spiral
-- around fields. A human driving manually ignores lane direction, so we route undirected
-- (neighbours = out ∪ incoming) and add a heavy cost to waypoints on cultivable field ground, so
-- roads/tracks win and harvest loops are avoided unless unavoidable. A start-turn penalty keeps
-- the route from opening with a U-turn.
-- ---------------------------------------------------------------------------------------------
local FIELD_COST_FACTOR = 8.0       -- multiply step cost when the target node sits on a field
local START_TURN_PENALTY = 2000.0   -- added to a first hop that points behind the vehicle
local REVERSE_LANE_FACTOR = 1.20    -- mild penalty for an edge only reachable via `incoming`
                                    -- (the wrong-way lane) -> prefer the right lane on 2-lane
                                    -- roads, but small enough to never detour a one-way field track
local ASTAR_MAX_ITER = 200000

-- per-waypoint cache of "is on cultivable field ground" (static per map; cleared on cache reset)
local function nodeOnField(id, wp)
    local c = NaviHelperAD._fieldCache[id]
    if c == nil then
        c = isFieldAtWorld(wp.x, wp.z)
        NaviHelperAD._fieldCache[id] = c
    end
    return c
end

local function heapPush(h, item)
    h[#h + 1] = item
    local i = #h
    while i > 1 do
        local p = math.floor(i / 2)
        if h[p].f <= h[i].f then break end
        h[p], h[i] = h[i], h[p]
        i = p
    end
end

local function heapPop(h)
    local top = h[1]
    local n = #h
    h[1] = h[n]; h[n] = nil; n = n - 1
    local i = 1
    while true do
        local l, r = 2 * i, 2 * i + 1
        local s = i
        if l <= n and h[l].f < h[s].f then s = l end
        if r <= n and h[r].f < h[s].f then s = r end
        if s == i then break end
        h[s], h[i] = h[i], h[s]
        i = s
    end
    return top
end

local function undirectedAStar(gm, startId, destId, headX, headZ)
    local wps = gm:getWayPoints()
    if type(wps) ~= "table" or wps[startId] == nil or wps[destId] == nil then return nil end
    if startId == destId then return { { x = wps[startId].x, y = wps[startId].y or 0, z = wps[startId].z } } end
    local dest = wps[destId]
    local hl = (headX ~= nil and headZ ~= nil) and math.sqrt(headX * headX + headZ * headZ) or 0
    local function heur(wp) local dx, dz = wp.x - dest.x, wp.z - dest.z; return math.sqrt(dx * dx + dz * dz) end

    local g = { [startId] = 0 }
    local cameFrom = {}
    local closed = {}
    local heap = {}
    heapPush(heap, { id = startId, f = heur(wps[startId]) })
    local iter = 0
    local found = false
    while #heap > 0 do
        iter = iter + 1
        if iter > ASTAR_MAX_ITER then return nil end
        local cur = heapPop(heap)
        local cid = cur.id
        if cid == destId then found = true; break end
        if not closed[cid] then
            closed[cid] = true
            local cwp = wps[cid]
            local fwd = {}   -- neighbours reachable in the legal (forward) direction
            if type(cwp.out) == "table" then for _, o in pairs(cwp.out) do fwd[o] = true end end
            local nb = {}
            for o in pairs(fwd) do nb[o] = true end
            if type(cwp.incoming) == "table" then for _, o in pairs(cwp.incoming) do nb[o] = true end end
            for nid in pairs(nb) do
                local nwp = wps[nid]
                if nwp and nwp.x and nwp.z and not closed[nid] then
                    local dx, dz = nwp.x - cwp.x, nwp.z - cwp.z
                    local step = math.sqrt(dx * dx + dz * dz)
                    if nodeOnField(nid, nwp) then step = step * FIELD_COST_FACTOR end
                    if not fwd[nid] then step = step * REVERSE_LANE_FACTOR end  -- wrong-way lane
                    if cid == startId and hl > 1e-4 and (dx * headX + dz * headZ) < 0 then
                        step = step + START_TURN_PENALTY     -- first hop points backwards
                    end
                    local ng = g[cid] + step
                    if g[nid] == nil or ng < g[nid] then
                        g[nid] = ng
                        cameFrom[nid] = cid
                        heapPush(heap, { id = nid, f = ng + heur(nwp) })
                    end
                end
            end
        end
    end
    if not found or g[destId] == nil then return nil end
    local path = {}
    local c = destId
    while c ~= nil do
        local wp = wps[c]
        table.insert(path, 1, { x = wp.x, y = wp.y or 0, z = wp.z })
        c = cameFrom[c]
    end
    return path
end

-- Forward out-neighbours of the start node (those ahead of the vehicle). Passed to AutoDrive's
-- pathFromTo as "preferred neighbours": AD applies a large turn-around penalty to any first step
-- NOT in this list, so the route leaves in the driving direction instead of demanding a U-turn.
local function forwardPreferredNeighbors(gm, startId, headX, headZ)
    local pref = {}
    if headX == nil or headZ == nil then return pref end
    local wps = gm:getWayPoints()
    if type(wps) ~= "table" then return pref end
    local s = wps[startId]
    if not s or not s.x or type(s.out) ~= "table" then return pref end
    for _, oid in pairs(s.out) do
        local o = wps[oid]
        if o and o.x and o.z then
            local dx, dz = o.x - s.x, o.z - s.z
            if dx * headX + dz * headZ > 0 then pref[#pref + 1] = oid end  -- neighbour is ahead
        end
    end
    return pref
end

-- Get path from world position to world position. Returns list of {x,y,z} or nil.
-- headX/headZ (optional) = vehicle forward vector, used to avoid an opening U-turn.
function NaviHelperAD.getPathFromToWorld(startX, startZ, destX, destZ, headX, headZ)
    if not NaviHelperAD.isAvailable() then return nil end
    if startX == nil or startZ == nil or destX == nil or destZ == nil then return nil end
    local gm = NaviHelperAD.cachedGraph
    if not gm then return nil end

    -- Start resolves heading-aware (prefer a node ahead of the vehicle).
    local ok, startId = pcall(startNodeToWorld, gm, startX, startZ, headX, headZ)
    if not ok or not startId then return nil end
    -- Destination resolves to the field ENTRANCE when the click is inside a field.
    local ok2, destId = pcall(resolveRoutingNode, gm, destX, destZ)
    if not ok2 or not destId then return nil end

    -- Primary: our own UNDIRECTED, field-avoiding A* — handles one-way lanes and field spirals
    -- that AutoDrive's directed pathfinder cannot.
    local okA, aPath = pcall(undirectedAStar, gm, startId, destId, headX, headZ)
    if okA and type(aPath) == "table" and #aPath > 0 then
        return aPath
    end

    -- Fallback: AutoDrive's own (directed) pathfinder, biased away from an opening U-turn.
    local preferred = {}
    local okp, p = pcall(forwardPreferredNeighbors, gm, startId, headX, headZ)
    if okp and type(p) == "table" then preferred = p end

    local path
    ok, path = pcall(gm.pathFromTo, gm, startId, destId, preferred)
    if not ok or not path or type(path) ~= "table" or #path == 0 then
        return nil
    end

    local out = {}
    for i, wp in ipairs(path) do
        if wp and wp.x and wp.z then
            out[#out + 1] = { x = wp.x, y = wp.y or 0, z = wp.z }
        end
    end
    return #out > 0 and out or nil
end

function NaviHelperAD.getVersion()
    if NaviHelperAD.version then return NaviHelperAD.version end
    NaviHelperAD.isAvailable()
    return NaviHelperAD.version or "unknown"
end

function NaviHelperAD.invalidateCache()
    NaviHelperAD.cachedAD = nil
    NaviHelperAD.cachedGraph = nil
    NaviHelperAD.version = nil
    NaviHelperAD._fieldCache = {}
end

-- Get current drive-to destination from vehicle's AutoDrive state (active path).
-- Returns destX, destZ, destinationName or nil.
function NaviHelperAD.getCurrentDestinationFromVehicle(vehicle)
    if vehicle == nil then return nil, nil, nil end
    local ad = vehicle.ad
    if not ad or type(ad) ~= "table" then return nil, nil, nil end
    local dm = ad.drivePathModule
    if not dm or type(dm) ~= "table" then return nil, nil, nil end
    if not dm.wayPoints or type(dm.wayPoints) ~= "table" or #dm.wayPoints == 0 then return nil, nil, nil end
    local getLast = dm.getLastWayPoint
    if type(getLast) ~= "function" then return nil, nil, nil end
    local ok, last = pcall(getLast, dm)
    if not ok or not last or not last.x or not last.z then return nil, nil, nil end
    local name = nil
    if ad.stateModule and type(ad.stateModule.getCurrentDestination) == "function" then
        local ok2, dest = pcall(ad.stateModule.getCurrentDestination, ad.stateModule)
        if ok2 and dest and dest.name then name = dest.name end
    end
    return last.x, last.z, name
end

-- Get selected destination from AutoDrive UI (firstMarker) even before route is started.
-- Returns destX, destZ, destinationName or nil. Uses NaviHelperAD.cachedGraph (same as ADGraphManager).
function NaviHelperAD.getSelectedDestinationFromVehicle(vehicle)
    -- vehicle can be table or userdata (FS25 vehicle object)
    if vehicle == nil then
        if Logging and not NaviHelperAD._loggedNoVehicle then
            Logging.info("[NaviHelper] getSelectedDest: vehicle nil")
            NaviHelperAD._loggedNoVehicle = true
        end
        return nil, nil, nil
    end
    local ad = vehicle.ad
    if not ad or type(ad) ~= "table" then
        if Logging and not NaviHelperAD._loggedNoAd then
            Logging.info("[NaviHelper] getSelectedDest: vehicle.ad missing")
            NaviHelperAD._loggedNoAd = true
        end
        return nil, nil, nil
    end
    if not ad.stateModule then
        if Logging and not NaviHelperAD._loggedNoState then
            Logging.info("[NaviHelper] getSelectedDest: vehicle.ad.stateModule missing")
            NaviHelperAD._loggedNoState = true
        end
        return nil, nil, nil
    end
    if not NaviHelperAD.isAvailable() then return nil, nil, nil end
    local gm = NaviHelperAD.cachedGraph
    if not gm or type(gm.getWayPointById) ~= "function" then return nil, nil, nil end
    local sm = ad.stateModule
    local getFirst = sm.getFirstMarker
    if type(getFirst) ~= "function" then
        if Logging and not NaviHelperAD._loggedNoGetFirst then
            Logging.info("[NaviHelper] getSelectedDest: stateModule.getFirstMarker not a function")
            NaviHelperAD._loggedNoGetFirst = true
        end
        return nil, nil, nil
    end
    local ok, marker = pcall(getFirst, sm)
    if not ok or not marker then
        if Logging and not NaviHelperAD._loggedNoMarker then
            Logging.info("[NaviHelper] getSelectedDest: getFirstMarker failed ok=%s marker=%s", tostring(ok), tostring(marker))
            NaviHelperAD._loggedNoMarker = true
        end
        return nil, nil, nil
    end
    local wayPointId = marker.id
    if wayPointId == nil or (type(wayPointId) == "number" and wayPointId < 0) then
        if type(sm.getFirstWayPoint) == "function" then
            local okId, id = pcall(sm.getFirstWayPoint, sm)
            if okId and id and type(id) == "number" and id >= 0 then wayPointId = id end
        end
    end
    if wayPointId == nil or (type(wayPointId) == "number" and wayPointId < 0) then
        if Logging and not NaviHelperAD._loggedNoWpId then
            Logging.info("[NaviHelper] getSelectedDest: marker.id invalid (id=%s name=%s)", tostring(marker.id), tostring(marker.name))
            NaviHelperAD._loggedNoWpId = true
        end
        return nil, nil, nil
    end
    local ok2, wp = pcall(gm.getWayPointById, gm, wayPointId)
    if not ok2 or not wp or not wp.x or not wp.z then
        if Logging and not NaviHelperAD._loggedNoWp then
            Logging.info("[NaviHelper] getSelectedDest: getWayPointById failed ok=%s wp=%s (wayPointId=%s)", tostring(ok2), wp and "table" or "nil", tostring(wayPointId))
            NaviHelperAD._loggedNoWp = true
        end
        return nil, nil, nil
    end
    if Logging and not NaviHelperAD._loggedSelectedOk then
        Logging.info("[NaviHelper] getSelectedDest: ok dest=%s x=%.0f z=%.0f", tostring(marker.name), wp.x, wp.z)
        NaviHelperAD._loggedSelectedOk = true
    end
    return wp.x, wp.z, marker.name
end

-- Get current path from vehicle (wayPoints table and current index) for distance/next-node display.
-- Returns wayPointsTable, currentIndex or nil.
function NaviHelperAD.getCurrentPathFromVehicle(vehicle)
    if not vehicle or not vehicle.ad or not vehicle.ad.drivePathModule then return nil, nil end
    local dm = vehicle.ad.drivePathModule
    if not dm.wayPoints or #dm.wayPoints == 0 then return nil, nil end
    local idx = (dm.getCurrentWayPointIndex and dm:getCurrentWayPointIndex()) or dm.currentWayPoint or 1
    return dm.wayPoints, idx
end
