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
local DEFAULT_NUM_SAMPLES   = 80        -- short segments: each flat tile spans little ground, so the
                                        -- chord can't sink far under a convex bump/slope (no per-segment pitch)
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
---@param minLengthM number|nil metres at standstill / low speed (default 10)
---@param maxLengthM number|nil metres at full vehicle top speed (default 40)
---@return number length in meters
function PathGeometry.computeLength(speedKmh, maxSpeedKmh, minLengthM, maxLengthM)
    local minL = minLengthM or DEFAULT_MIN_LENGTH_M
    local maxL = maxLengthM or DEFAULT_MAX_LENGTH_M
    if minL < 2 then minL = 2 end
    if maxL < minL + 2 then maxL = minL + 2 end
    if maxL > 120 then maxL = 120 end

    local s = math.abs(speedKmh or 0)
    local maxS = maxSpeedKmh or FALLBACK_MAX_SPEED_KMH
    if maxS < 10 then maxS = FALLBACK_MAX_SPEED_KMH end  -- sanity clamp
    local ratio = math.min(1, s / maxS)
    return minL + ratio * (maxL - minL)
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
---@param minLengthM number|nil see computeLength
---@param maxLengthM number|nil see computeLength
---@param fixedAxleZ number|nil z of the NON-steered (rolling) axle the turn circle is
---  anchored to, in the same frame where the rear axle ~ 0. Front-wheel steering: 0
---  (default, behaviour unchanged). Rear-wheel steering (combines): the front axle,
---  i.e. wheelbase. 4WS: roughly the centre, wheelbase/2.
---@param steerInvert boolean|nil if true (rear-wheel steering) the body yaws the
---  opposite way for the same steering value, so the input sign is flipped.
---@return table leftPoints array of {x=..., z=...}
---@return table rightPoints array of {x=..., z=...}
function PathGeometry.computePath(steeringValue, speedKmh, maxSpeedKmh, wheelbase, trackWidth, maxSteerAngle, isReverse, startDist, numSamples, minLengthM, maxLengthM, fixedAxleZ, steerInvert)
    numSamples = numSamples or DEFAULT_NUM_SAMPLES
    startDist = startDist or 0  -- distance from vehicle origin to start the path (nose or tail)
    fixedAxleZ = fixedAxleZ or 0  -- 0 = front-wheel steering (turn circle on the rear axle)
    if steerInvert then
        steeringValue = -(steeringValue or 0)  -- rear-steer yaws the other way for the same input
    end
    local length = PathGeometry.computeLength(speedKmh, maxSpeedKmh, minLengthM, maxLengthM)
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

    -- Curved path: circle centered at (sign * radius, fixedAxleZ). The instantaneous
    -- centre of rotation lies on the perpendicular through the NON-steered (rolling)
    -- axle. Front-wheel steering anchors it at the rear axle (fixedAxleZ = 0, the
    -- original behaviour); rear-wheel steering anchors it at the FRONT axle
    -- (fixedAxleZ = wheelbase), which is why a combine's body swings the other way.
    -- Arc-length is measured from that fixed axle, so we offset the start by it.
    local cx = sign * radius

    for i = 0, numSamples do
        -- Arc-length from the fixed (pivot) axle to the drawing-start end, measured in
        -- the travel direction: forward starts at the nose (startDist - fixedAxleZ),
        -- reverse starts at the tail going backward (startDist + fixedAxleZ). The
        -- fixedAxleZ term therefore flips sign with direction. (Card #147.)
        local s = (startDist - zDir * fixedAxleZ) + length * (i / numSamples)
        local theta = s / radius

        local cosT = math.cos(theta)
        local sinT = math.sin(theta)

        local cx_point = cx - sign * radius * cosT
        local arcZ = radius * sinT  -- z-offset of the arc point from the pivot row

        -- Right-pointing unit normal at this arc point.
        local nx = cosT
        local nz = -sign * sinT

        -- Reverse mirrors the ARC across the pivot row z = fixedAxleZ (the ICR's z),
        -- NOT across z = 0. Otherwise a rear-steered vehicle's pivot (fixedAxleZ > 0)
        -- would jump to the wrong side when reversing. x is unchanged either way, so
        -- the turning circle stays centred at (sign*R, fixedAxleZ) in both directions.
        -- (Card #147.)
        local px = cx_point
        local pz = fixedAxleZ + zDir * arcZ
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
