--[[
  Desk unit tests for PathGeometry (engine-free, pure math).
  Run from the mod root:   lua tests/test_path_geometry.lua
  Exit code 0 = all passed.

  Focus: the rear-wheel-steering generalisation.
    - front-steer (fixedAxleZ = 0) must be unchanged (regression).
    - rear-steer  (fixedAxleZ = wheelbase, steerInvert = true) must anchor the
      turn circle at the FRONT axle and curve the opposite way.
    - 4WS pivot sits at the centre.
]]

dofile("scripts/PathGeometry.lua")

local failures = 0
local function check(cond, msg)
    if cond then
        print("  ok  " .. msg)
    else
        failures = failures + 1
        print("  FAIL " .. msg)
    end
end
local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- Common inputs: steer hard right, mid speed, 3 m wheelbase, centreline only.
local SV, SPEED, MAXSPD = 0.8, 20, 40
local WB, TRACK, MAXSTEER = 3.0, 0.0, math.rad(40)
local START, NSAMP = 2.0, 40

-- Expected turn radius from Ackermann (used to verify the circle the path lies on).
local R = WB / math.tan(SV * MAXSTEER)
print(string.format("turn radius R = %.3f m (WB=%.1f, delta=%.1f deg)", R, WB, math.deg(SV * MAXSTEER)))

-- Helper: every centreline point must lie on the circle of radius R about (cx, cz).
local function pointsOnCircle(pts, cx, cz, r, eps)
    for _, p in ipairs(pts) do
        local d = math.sqrt((p.x - cx) ^ 2 + (p.z - cz) ^ 2)
        if not approx(d, r, eps or 1e-3) then return false, d end
    end
    return true
end

----------------------------------------------------------------------
print("\n[1] front-steer: turn circle anchored at the rear axle (z = 0)")
local fL = select(1, PathGeometry.computePath(SV, SPEED, MAXSPD, WB, TRACK, MAXSTEER,
    false, START, NSAMP, nil, nil))               -- fixedAxleZ/steerInvert omitted -> defaults
-- right turn -> sign +1 -> centre at (+R, 0)
local ok, d = pointsOnCircle(fL, R, 0, R)
check(ok, "all points lie on circle centred at (+R, 0)" .. (ok and "" or (" (got d=" .. tostring(d) .. ")")))
check(fL[1].x >= 0, "near point bends to the right (x >= 0 for right steer)")

----------------------------------------------------------------------
print("\n[2] front-steer regression: matches the original formula exactly")
-- Reproduce the pre-change math independently and compare.
local len = PathGeometry.computeLength(SPEED, MAXSPD)
local refOk = true
for i = 0, NSAMP do
    local s = START + len * (i / NSAMP)
    local theta = s / R
    local refx = R - 1 * R * math.cos(theta)   -- sign = +1
    local refz = R * math.sin(theta)
    local p = fL[i + 1]
    if not (approx(p.x, refx) and approx(p.z, refz)) then refOk = false; break end
end
check(refOk, "generalised code reproduces the original front-steer path")

----------------------------------------------------------------------
print("\n[3] rear-steer: turn circle anchored at the FRONT axle (z = wheelbase)")
local rL = select(1, PathGeometry.computePath(SV, SPEED, MAXSPD, WB, TRACK, MAXSTEER,
    false, START, NSAMP, nil, nil, WB, true))     -- fixedAxleZ = WB, steerInvert = true
-- steerInvert flips the sign -> centre at (-R, WB)
local ok3, d3 = pointsOnCircle(rL, -R, WB, R)
check(ok3, "all points lie on circle centred at (-R, wheelbase)" .. (ok3 and "" or (" (got d=" .. tostring(d3) .. ")")))

----------------------------------------------------------------------
print("\n[4] rear-steer curves OPPOSITE to front-steer for the same input")
-- Compare a forward sample well past the start.
local idx = math.floor(NSAMP * 0.6)
check(fL[idx].x > 0 and rL[idx].x < 0,
    string.format("front x=%.2f (right) vs rear x=%.2f (left)", fL[idx].x, rL[idx].x))

----------------------------------------------------------------------
print("\n[5] 4WS: pivot at the vehicle centre (z = wheelbase/2)")
local qL = select(1, PathGeometry.computePath(SV, SPEED, MAXSPD, WB, TRACK, MAXSTEER,
    false, START, NSAMP, nil, nil, WB * 0.5, false))
local ok5 = pointsOnCircle(qL, R, WB * 0.5, R)
check(ok5, "all points lie on circle centred at (+R, wheelbase/2)")

----------------------------------------------------------------------
print("\n[6] straight path unchanged (steer = 0): parallel lines at +/- halfTrack")
local sL, sR = PathGeometry.computePath(0, SPEED, MAXSPD, WB, 2.0, MAXSTEER,
    false, START, NSAMP, nil, nil, WB, true)       -- even rear-steer must stay straight
local straightOk = approx(sL[1].x, -1.0) and approx(sR[1].x, 1.0)
    and sL[NSAMP + 1].z > sL[1].z
check(straightOk, "zero steering yields straight parallel tracks regardless of axle mode")

----------------------------------------------------------------------
print("\n[7] front-steer REVERSE: pivot stays at the rear axle (z = 0), arc behind")
local rvFL = select(1, PathGeometry.computePath(SV, SPEED, MAXSPD, WB, TRACK, MAXSTEER,
    true, START, NSAMP, nil, nil))                -- isReverse = true, fixedAxleZ = 0
local ok7 = pointsOnCircle(rvFL, R, 0, R)
check(ok7, "reverse front-steer: points on circle centred at (+R, 0)")
-- The path leaves the vehicle going BACKWARD: the near end sits behind the
-- rear-axle pivot row (z < 0) and the next sample goes further behind. (The far
-- end can wrap forward again on a tight circle, so only the start is checked.)
check(rvFL[1].z < 0, string.format("reverse front-steer starts behind the rear axle (near z=%.2f < 0)", rvFL[1].z))
check(rvFL[2].z < rvFL[1].z, "reverse front-steer initially extends further behind")

----------------------------------------------------------------------
print("\n[8] rear-steer REVERSE: pivot stays at the FRONT axle (z = wheelbase) — card #147")
local rvRL = select(1, PathGeometry.computePath(SV, SPEED, MAXSPD, WB, TRACK, MAXSTEER,
    true, START, NSAMP, nil, nil, WB, true))      -- reverse + rear-steer (fixedAxleZ = WB)
local ok8, d8 = pointsOnCircle(rvRL, -R, WB, R)
check(ok8, "reverse rear-steer: points on circle centred at (-R, wheelbase)"
    .. (ok8 and "" or (" (got d=" .. tostring(d8) .. ")")))
-- the bug signature was the pivot row landing at -wheelbase (behind the vehicle):
local centredBehind = pointsOnCircle(rvRL, -R, -WB, R)
check(not centredBehind, "reverse rear-steer pivot is NOT mirrored to -wheelbase (old bug)")
-- Reversing a combine, the arc leaves the front-axle pivot heading backward, so
-- the near end is behind that pivot row (z < wheelbase).
check(rvRL[1].z < WB, string.format("reverse rear-steer starts behind the front pivot (near z=%.2f < %.1f)", rvRL[1].z, WB))

----------------------------------------------------------------------
print(string.format("\n%d failure(s).", failures))
os.exit(failures == 0 and 0 or 1)
