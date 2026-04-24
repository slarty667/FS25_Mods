--[[
  TrailerKinematics.lua
  Models how a towed trailer will swing when the tractor reverses.
  Pure math — no engine dependency, so the whole thing is unit-testable.

  Model: single-track kingpin hitch (a.k.a. bicycle trailer model).
  For each step along the tractor's predicted path we:
    1. Advance the hitch position by one step on the tractor's arc.
    2. Roll the trailer axle along its current longitudinal direction only
       (no side slip — that's the rolling constraint).
    3. Re-project the trailer axle onto the circle of radius tongueLength
       around the new hitch (to keep the tongue rigid).
    4. Recompute the trailer direction.

  For a two-axle trailer with turntable we approximate the tongue length
  as the distance from hitch to the REAR axle (so the rear axle's swing
  is what we visualise — which is what matters for "will the corner of the
  trailer clear the gate post").

  Coordinate convention matches PathGeometry:
    +X = right of tractor (flipped to world inside SteeringPathIndicator)
    +Z = forward of tractor
    vehicle rootNode is the tractor origin
]]

TrailerKinematics = {}

---Approximate the tongue length (hitch → trailer rear axle) from a trailer's
---overall length and whether it has a turntable. These are the best-guess
---numbers from eyeballing real-world trailers; we can calibrate later if
---the visual doesn't match.
---@param trailerLength number meters
---@param hasTurntable boolean true = two-axle with front turntable
---@return number tongueLength meters
function TrailerKinematics.approxTongueLength(trailerLength, hasTurntable)
    local L = math.max(1.0, trailerLength or 6.0)
    -- Single-axle trailers: axle sits ~65% from the front (hitch).
    -- Two-axle w/ turntable: rear axle sits ~80-85% from the hitch.
    local frac = hasTurntable and 0.80 or 0.65
    return L * frac
end

---Simulate trailer path for N steps, starting from an initial hitch angle.
---Returns two polylines (left + right edge of the trailer rear axle) in
---vehicle-local coordinates, ready to be flipped and raycasted.
---
---@param tractorPath table array of {x, z} — pre-computed tractor hitch path (use a CENTRE line, not the outer rails)
---@param tongueLength number distance hitch → trailer rear axle (meters)
---@param trailerHalfWidth number half the trailer width (meters)
---@param initialHitchAngle number current trailer yaw relative to tractor (radians); 0 = aligned
---@param isReverse boolean when true, trailer is behind and we project backward
---@return table leftPoints array of {x, z}
---@return table rightPoints array of {x, z}
function TrailerKinematics.simulate(tractorPath, tongueLength, trailerHalfWidth, initialHitchAngle, isReverse)
    local left, right = {}, {}
    if type(tractorPath) ~= "table" or #tractorPath < 2 then return left, right end

    -- Initial trailer axle position: sits tongueLength away from the first hitch
    -- point, along the direction (hitch → axle). Direction depends on hitchAngle.
    -- We express axle position as (hx, hz) - tongueLength * (trailerForward).
    -- trailerForward points "ahead" of the trailer (i.e. toward the hitch when
    -- looking at the trailer). Its angle in the tractor frame at step 0 is
    -- the hitchAngle. "Behind the hitch" = opposite direction.

    local h0 = tractorPath[1]
    -- Trailer direction in vehicle-local frame: from axle toward hitch (forward of trailer).
    -- When isReverse=true and hitchAngle=0, the trailer is behind → trailerForward points -Z.
    -- Let "behind vector" b = -Z when aligned; rotated by hitchAngle around Y.
    local bx0 = math.sin(initialHitchAngle)
    local bz0 = -math.cos(initialHitchAngle)
    -- axle position = hitch + tongueLength * b (b points from hitch to axle)
    local ax, az = h0.x + tongueLength * bx0, h0.z + tongueLength * bz0

    -- For each subsequent hitch point, roll the axle forward along the trailer's
    -- own longitudinal direction by the projection of the hitch-movement onto it.
    -- Then re-project to maintain tongueLength (soft constraint).
    local function pushSegment(hx, hz, axX, azZ)
        -- Trailer longitudinal direction: from axle to hitch (points "forward" of trailer).
        local fx = hx - axX
        local fz = hz - azZ
        local len = math.sqrt(fx * fx + fz * fz)
        if len < 1e-4 then fx, fz = 0, 1; len = 1 end
        fx, fz = fx / len, fz / len
        -- Lateral (right-hand perpendicular in X-Z plane): rotate forward by -90° around Y
        local rx, rz = fz, -fx
        -- Edge points at axle ± half-width along lateral.
        table.insert(left,  { x = axX - trailerHalfWidth * rx, z = azZ - trailerHalfWidth * rz })
        table.insert(right, { x = axX + trailerHalfWidth * rx, z = azZ + trailerHalfWidth * rz })
    end

    pushSegment(h0.x, h0.z, ax, az)

    for i = 2, #tractorPath do
        local h = tractorPath[i]
        local hPrev = tractorPath[i - 1]
        local dhx, dhz = h.x - hPrev.x, h.z - hPrev.z

        -- Trailer forward direction (axle → hitch), from previous step state.
        local fx = hPrev.x - ax
        local fz = hPrev.z - az
        local flen = math.sqrt(fx * fx + fz * fz)
        if flen < 1e-4 then fx, fz = 0, isReverse and -1 or 1; flen = 1 end
        fx, fz = fx / flen, fz / flen

        -- Rolling constraint: axle only moves along its current longitudinal axis.
        -- The projection of the hitch displacement onto the trailer's forward
        -- direction is how far the axle rolls.
        local proj = dhx * fx + dhz * fz
        ax = ax + proj * fx
        az = az + proj * fz

        -- Soft constraint: re-project axle onto a circle of radius tongueLength
        -- around the new hitch, so the tongue stays rigid. Slight correction each step.
        local bx = ax - h.x
        local bz = az - h.z
        local blen = math.sqrt(bx * bx + bz * bz)
        if blen > 1e-4 then
            ax = h.x + (tongueLength * bx / blen)
            az = h.z + (tongueLength * bz / blen)
        end

        pushSegment(h.x, h.z, ax, az)
    end

    return left, right
end
