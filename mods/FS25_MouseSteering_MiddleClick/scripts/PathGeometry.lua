--[[
  PathGeometry.lua
  Pure Ackermann-path math with no engine dependency. Given steering input,
  vehicle geometry and speed, produces two polylines (left and right track)
  in vehicle-local coordinates.

  Local coordinate convention (matches FS25 vehicle frame):
    +X = right of vehicle
    +Z = forward of vehicle (or backward if isReverse)
    Y is left at 0; terrain raycasts are applied later in SegmentPool.

  The module is purely numeric so it can be unit-tested at the desk without
  running the game.
]]

PathGeometry = {}

-- Tunable constants (intentionally not exposed as user settings).
local DEFAULT_NUM_SAMPLES   = 20
local DEFAULT_MIN_LENGTH_M  = 10.0        -- at 0 km/h relative speed; anything shorter is visually lost in perspective
local DEFAULT_MAX_LENGTH_M  = 40.0        -- at 100 % of vehicle top speed
local FALLBACK_MAX_SPEED_KMH = 40.0       -- used when vehicle max speed is unknown (mid-size tractor)
local STEER_EPSILON         = 1e-4

---Compute the target path length for the current speed, scaled to this vehicle's top speed.
---A tractor at 40 km/h max that drives 20 km/h gets roughly half the max length;
---a truck at 80 km/h max that drives 20 km/h gets about a quarter. That way the line
---length always feels proportional to "how fast am I going for this vehicle".
---@param speedKmh number current speed (km/h)
---@param maxSpeedKmh number|nil vehicle top speed (km/h); falls back to 40 km/h
---@return number length in meters
function PathGeometry.computeLength(speedKmh, maxSpeedKmh)
    local s = math.abs(speedKmh or 0)
    local maxS = maxSpeedKmh or FALLBACK_MAX_SPEED_KMH
    if maxS < 10 then maxS = FALLBACK_MAX_SPEED_KMH end  -- sanity clamp
    local ratio = math.min(1, s / maxS)
    return DEFAULT_MIN_LENGTH_M + ratio * (DEFAULT_MAX_LENGTH_M - DEFAULT_MIN_LENGTH_M)
end

---Compute the turning radius from Ackermann geometry.
---@param steeringValue number in [-1, 1]
---@param wheelbase number in meters
---@param maxSteerAngle number in radians (maximum wheel rotation)
---@return number|nil radius in meters, or nil if the path is effectively straight
---@return number sign +1 = turning right, -1 = turning left, 0 = straight
function PathGeometry.computeRadius(steeringValue, wheelbase, maxSteerAngle)
    local delta = (steeringValue or 0) * (maxSteerAngle or 0)
    if math.abs(delta) < STEER_EPSILON then
        return nil, 0
    end
    local sign = (delta > 0) and 1 or -1
    local radius = (wheelbase or 2.5) / math.tan(math.abs(delta))
    return radius, sign
end

---Compute left and right track polylines in vehicle-local coordinates.
---@param steeringValue number in [-1, 1]
---@param speedKmh number current vehicle speed in km/h
---@param maxSpeedKmh number|nil vehicle top speed (km/h); used to scale path length
---@param wheelbase number in meters
---@param trackWidth number in meters (use vehicle width + padding, not wheel track)
---@param maxSteerAngle number in radians
---@param isReverse boolean if true, the path projects behind the vehicle
---@param startDist number|nil arc-length offset where samples begin (e.g. vehicle nose z); default 0
---@param numSamples number|nil optional override (default 20)
---@return table leftPoints array of {x=..., z=...}
---@return table rightPoints array of {x=..., z=...}
function PathGeometry.computePath(steeringValue, speedKmh, maxSpeedKmh, wheelbase, trackWidth, maxSteerAngle, isReverse, startDist, numSamples)
    numSamples = numSamples or DEFAULT_NUM_SAMPLES
    startDist = startDist or 0  -- distance from vehicle origin to start the path (nose or tail)
    local length = PathGeometry.computeLength(speedKmh, maxSpeedKmh)
    local halfTrack = (trackWidth or 1.8) * 0.5
    local zDir = isReverse and -1 or 1

    local leftPoints = {}
    local rightPoints = {}

    local radius, sign = PathGeometry.computeRadius(steeringValue, wheelbase, maxSteerAngle)

    if radius == nil then
        -- Straight path: two parallel lines starting at startDist, extending by length.
        for i = 0, numSamples do
            local s = startDist + length * (i / numSamples)
            local z = zDir * s
            leftPoints[i + 1]  = { x = -halfTrack, z = z }
            rightPoints[i + 1] = { x =  halfTrack, z = z }
        end
        return leftPoints, rightPoints
    end

    -- Curved path: circle centered at (sign * radius, 0). Arc-length parameter s
    -- runs from startDist (at vehicle nose/tail) to startDist + length.
    -- The arc itself is still anchored at the vehicle's rotation centre — that's
    -- physically correct: the turning circle doesn't move when we just skip the
    -- first few metres of drawing.
    local cx = sign * radius

    for i = 0, numSamples do
        local s = startDist + length * (i / numSamples)
        local theta = s / radius

        local cosT = math.cos(theta)
        local sinT = math.sin(theta)

        local cx_point = cx - sign * radius * cosT
        local cz_point = radius * sinT

        -- Right-pointing unit normal at this arc point.
        local nx = cosT
        local nz = -sign * sinT

        -- Apply reverse flip to z-axis only (path extends behind the vehicle).
        local px = cx_point
        local pz = zDir * cz_point
        local normalZ = zDir * nz

        leftPoints[i + 1]  = { x = px - halfTrack * nx, z = pz - halfTrack * normalZ }
        rightPoints[i + 1] = { x = px + halfTrack * nx, z = pz + halfTrack * normalZ }
    end

    return leftPoints, rightPoints
end

---Transform a point from vehicle-local (X lateral, Z longitudinal) to world coordinates,
---given the vehicle's world position and yaw (Y-axis rotation).
---Used by the caller (SteeringPathIndicator) to feed the SegmentPool.
---@param localX number
---@param localZ number
---@param vehicleWorldX number
---@param vehicleWorldY number  (the y height — caller decides whether to use it or ignore in favor of raycast)
---@param vehicleWorldZ number
---@param vehicleYawRad number  rotation around the world Y axis (radians)
---@return number worldX, number worldY, number worldZ
function PathGeometry.localToWorld(localX, localZ, vehicleWorldX, vehicleWorldY, vehicleWorldZ, vehicleYawRad)
    local cosY = math.cos(vehicleYawRad)
    local sinY = math.sin(vehicleYawRad)
    -- Standard Y-axis rotation in a right-handed system (Giants uses left-handed Y-up,
    -- but this sign convention matches what getWorldRotation returns for vehicles).
    local worldX = vehicleWorldX + localX * cosY + localZ * sinY
    local worldZ = vehicleWorldZ - localX * sinY + localZ * cosY
    return worldX, vehicleWorldY, worldZ
end
