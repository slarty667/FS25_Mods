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

-- Returns closest waypoint id to world (x, z), or nil
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
    return bestId
end

-- Get path from world position to world position. Returns list of {x,y,z} or nil.
function NaviHelperAD.getPathFromToWorld(startX, startZ, destX, destZ)
    if not NaviHelperAD.isAvailable() then return nil end
    if startX == nil or startZ == nil or destX == nil or destZ == nil then return nil end
    local gm = NaviHelperAD.cachedGraph
    if not gm then return nil end

    local ok, startId = pcall(closestNodeToWorld, gm, startX, startZ)
    if not ok or not startId then return nil end
    local ok2, destId = pcall(closestNodeToWorld, gm, destX, destZ)
    if not ok2 or not destId then return nil end

    local path
    ok, path = pcall(gm.pathFromTo, gm, startId, destId, {})
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
