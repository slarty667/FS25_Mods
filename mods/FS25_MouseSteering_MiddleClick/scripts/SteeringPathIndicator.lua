--[[
  SteeringPathIndicator.lua
  Orchestrator for the projected driving path feature.
  Called each frame from MouseSteering:update; decides whether to render,
  pulls geometry from VehicleIntrospection, runs PathGeometry, projects
  points to world coordinates (terrain-following), and feeds SegmentPool.

  Lifecycle: init() once when the map is loaded, update(vehicle) per frame,
  draw() from the main draw-pass (needed only for the debug-line fallback),
  shutdown() when the mod unloads.
]]

SteeringPathIndicator = {}

-- Small lift so lines don't Z-fight with the ground.
local GROUND_Y_OFFSET = 0.10

-- Green, matching the mockup.
local COLOR_ACTIVE = { 0.15, 0.85, 0.35, 0.92 }

-- Yellow-ish for the trailer's projected path — distinct enough from the
-- tractor's green to tell apart at a glance.
local COLOR_TRAILER = { 0.95, 0.78, 0.18, 0.92 }

-- Extra margin on each side of the vehicle so the lines don't make the player
-- brush literal branches. 15 cm felt right in testing — enough to clear skinny
-- obstacles, not so much that the lines wrap wide around narrow gates.
local SIDE_PADDING_M = 0.15

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[MouseSteering][Path] " .. fmt, ...)
    end
end

---Initialise the pool. Idempotent.
function SteeringPathIndicator:init()
    if self._initialised then return end
    if SegmentPool and SegmentPool.init then
        SegmentPool:init()
    end
    self._initialised = true
    log("initialised (SegmentPool mode=%s)", SegmentPool and SegmentPool.mode or "nil")
end

---Tear down. Safe to call multiple times.
function SteeringPathIndicator:shutdown()
    if SegmentPool and SegmentPool.shutdown then SegmentPool:shutdown() end
    self._initialised = false
end

---Look up the terrain-following world Y for a horizontal (x, z) position.
---FS25 signature: getTerrainHeightAtWorldPos(terrainNode, x, y, z) — 4 args.
---The y arg is an input placeholder and ignored for the lookup.
---Prefer the canonical g_terrainNode (NaviHelper pattern), fall back to the
---mission's terrainRootNode if it's not yet global.
---@return number y meters
local function groundY(worldX, worldZ, fallbackY)
    local y = nil
    local node = g_terrainNode or (g_currentMission and g_currentMission.terrainRootNode)
    if node and getTerrainHeightAtWorldPos then
        pcall(function()
            y = getTerrainHeightAtWorldPos(node, worldX, 0, worldZ)
        end)
    end
    if type(y) ~= "number" then y = fallbackY or 0 end
    return y + GROUND_Y_OFFSET
end

---Transform a list of vehicle-local points {x, z} into world-space points {x, y, z}
---using the vehicle's rootNode transform and terrain-following Y.
---Note on sign convention: PathGeometry uses intuitive "+X = right of vehicle",
---but Giants vehicle rootNodes in FS25 orient +X to the LEFT. We flip X here so
---that the geometry module stays readable and the coordinate mismatch is
---confined to this one spot.
local function localPointsToWorld(localPoints, vehicleRoot, fallbackY)
    local out = {}
    for i, p in ipairs(localPoints) do
        local wx, _, wz = 0, 0, 0
        pcall(function()
            wx, _, wz = localToWorld(vehicleRoot, -p.x, 0, p.z)  -- X flipped for Giants convention
        end)
        out[i] = { x = wx, y = groundY(wx, wz, fallbackY), z = wz }
    end
    return out
end

-- Path visibility modes (indices match MouseSteeringSettings.controlProperties.values order).
local MODE_OFF      = 1
local MODE_STEERING = 2  -- show when |axisSteer| > threshold, regardless of input source
local MODE_MOUSE    = 3  -- show only during active mouse steering (LMB down)
local MODE_ALWAYS   = 4  -- show whenever the player is in a vehicle

-- Below this absolute steering value the path is considered "straight".
local STEERING_VISIBILITY_THRESHOLD = 0.03

---Read the current authoritative steering angle from the vehicle. Must work
---for ALL input sources (mouse, keyboard A/D, controller, wheel).
---
---The catch: spec_drivable.lastInputValues.axisSteer is only populated while
---our own mouse-steering code writes to it. For keyboard/controller, FS25
---routes the value through other fields. Ordered lookup below:
---
---  1. vehicle.rotatedTime / vehicle.rotatedTimeMax
---     — physical wheel rotation after all input processing; post-ratchet
---       and post-centering. Normalised to [-1, 1]. Most authoritative.
---  2. vehicle.spec_drivable.axisSide
---     — FS22/25 Drivable spec often exposes this as the consolidated
---       side-axis after input processing.
---  3. vehicle.spec_drivable.lastInputValues.axisSteer
---     — works only while we're actively writing it (mouse); kept as a
---       last-resort fallback.
---
---We log once per vehicle which source actually delivered a value, so we can
---see in the logs whether our assumption about rotatedTime holds up.
---@return number in [-1, 1]
local function readAxisSteer(vehicle)
    SteeringPathIndicator._steerSource = SteeringPathIndicator._steerSource or setmetatable({}, { __mode = "k" })

    local v, source = 0, "none"

    -- 1. rotatedTime / rotatedTimeMax → normalised physical angle
    pcall(function()
        if type(vehicle.rotatedTime) == "number" and type(vehicle.rotatedTimeMax) == "number"
            and vehicle.rotatedTimeMax > 0 then
            v = vehicle.rotatedTime / vehicle.rotatedTimeMax
            source = "rotatedTime"
        end
    end)

    -- 2. spec_drivable.axisSide
    if source == "none" then
        pcall(function()
            if vehicle.spec_drivable and type(vehicle.spec_drivable.axisSide) == "number" then
                v = vehicle.spec_drivable.axisSide
                source = "axisSide"
            end
        end)
    end

    -- 3. lastInputValues.axisSteer (mouse-only while we're writing it)
    if source == "none" then
        pcall(function()
            if vehicle.spec_drivable and vehicle.spec_drivable.lastInputValues then
                local x = vehicle.spec_drivable.lastInputValues.axisSteer
                if type(x) == "number" then
                    v = x
                    source = "lastInputValues.axisSteer"
                end
            end
        end)
    end

    -- One-shot diagnostic per vehicle.
    if SteeringPathIndicator._steerSource[vehicle] ~= source then
        SteeringPathIndicator._steerSource[vehicle] = source
        if Logging and Logging.info then
            Logging.info("[MouseSteering][Path] steering source for vehicle=%s -> %s",
                (vehicle.getName and vehicle:getName()) or "?", source)
        end
    end

    -- Clamp to [-1, 1] — rotatedTime can briefly exceed due to interpolation.
    if v > 1 then v = 1 elseif v < -1 then v = -1 end
    return v
end

---Check the gate conditions. Return true if we should render the path right now.
local function shouldRender(vehicle, axisSteer)
    if not vehicle then return false end
    if vehicle.getIsEntered and not vehicle:getIsEntered() then return false end
    if vehicle.getIsControlled and not vehicle:getIsControlled() then return false end
    if not vehicle.rootNode then return false end

    local mode = (MouseSteeringSettings and MouseSteeringSettings.pathIndicatorMode) or MODE_STEERING
    if mode == MODE_OFF then return false end

    if mode == MODE_MOUSE then
        -- Only while mouse steering is driving axisSteer (LMB or release coast).
        if not MouseSteering or not MouseSteering.armed
            or not (MouseSteering.active or MouseSteering._steeringCoast) then
            return false
        end
    elseif mode == MODE_STEERING then
        -- Only while the wheel is actually turned (any input source).
        if math.abs(axisSteer or 0) < STEERING_VISIBILITY_THRESHOLD then
            return false
        end
    end
    -- MODE_ALWAYS: no extra gate beyond the vehicle-validity checks above.
    return true
end

---Per-frame entry point.
---@param dt number delta time (unused today; kept in the signature for future use)
---@param vehicle table the currently controlled vehicle
function SteeringPathIndicator:update(dt, vehicle)
    self:init()

    -- Read steering from the vehicle (works for keyboard, mouse, wheel, controller).
    local axisSteer = vehicle and readAxisSteer(vehicle) or 0

    if not shouldRender(vehicle, axisSteer) then
        if SegmentPool and SegmentPool.hideAll then SegmentPool:hideAll() end
        return
    end

    -- Pull geometry, bounds and motion state.
    local geo = VehicleIntrospection:getGeometry(vehicle)
    local bounds = VehicleIntrospection:getBounds(vehicle)
    local speedKmh, isReverse = VehicleIntrospection:getMotion(vehicle)
    local maxSpeedKmh = VehicleIntrospection:getMaxSpeed(vehicle)

    -- Line width = actual vehicle width + side padding on each side.
    -- This gives the "reverse-camera" feel: the lines mark where the outer
    -- edges of the vehicle will pass, not where the wheel centres are.
    local lineWidth = bounds.width + 2 * SIDE_PADDING_M

    -- Start the path at the vehicle's nose (forward) or tail (reverse),
    -- not at the geometric centre. On combines and long tractors this
    -- matters a lot — the old behaviour had several metres of line hidden
    -- inside the cab.
    local startDist = isReverse and math.abs(bounds.rearZ) or bounds.frontZ

    -- Compute path in vehicle-local coordinates. Path length scales with speed
    -- relative to this vehicle's top speed (tractor at 50% -> ~22 m, truck at
    -- 50% -> ~22 m too; the feel stays consistent across vehicle classes).
    local leftLocal, rightLocal = PathGeometry.computePath(
        axisSteer, speedKmh, maxSpeedKmh,
        geo.wheelbase, lineWidth, geo.maxSteerAngle, isReverse, startDist
    )

    -- Trailer kinematics: only when reversing, a trailer is hitched, and
    -- the feature is enabled in settings.
    local trailerLeftLocal, trailerRightLocal = nil, nil
    local showTrailer = isReverse
        and (MouseSteeringSettings and MouseSteeringSettings.trailerPathEnabled ~= false)
    if showTrailer and VehicleIntrospection.getTrailerKinematics then
        local tk = VehicleIntrospection:getTrailerKinematics(vehicle)
        if tk then
            -- Build a hitch-path: single-lane track starting at the hitch Z,
            -- following the same Ackermann arc as the tractor. halfWidth=0 so
            -- both returned lists coincide — we use the left list as the hitch path.
            local hitchStart = math.abs(tk.hitchOffsetZ)
            local hitchPathA, _hitchPathB = PathGeometry.computePath(
                axisSteer, speedKmh, maxSpeedKmh,
                geo.wheelbase, 0, geo.maxSteerAngle, isReverse, hitchStart
            )
            trailerLeftLocal, trailerRightLocal = TrailerKinematics.simulate(
                hitchPathA, tk.tongueLength, tk.halfWidth, tk.hitchAngle, isReverse
            )
        end
    end

    -- Project to world.
    local fallbackY = 0
    pcall(function() local _, vy, _ = getWorldTranslation(vehicle.rootNode); fallbackY = vy or 0 end)
    local leftWorld  = localPointsToWorld(leftLocal,  vehicle.rootNode, fallbackY)
    local rightWorld = localPointsToWorld(rightLocal, vehicle.rootNode, fallbackY)

    -- Hand off to the pool. If trailer path is present, render BOTH groups.
    if trailerLeftLocal and trailerRightLocal and #trailerLeftLocal > 1 then
        local trailerLeftWorld  = localPointsToWorld(trailerLeftLocal,  vehicle.rootNode, fallbackY)
        local trailerRightWorld = localPointsToWorld(trailerRightLocal, vehicle.rootNode, fallbackY)
        if SegmentPool and SegmentPool.applySegmentGroups then
            SegmentPool:applySegmentGroups({
                { left = leftWorld,        right = rightWorld,        color = COLOR_ACTIVE  },
                { left = trailerLeftWorld, right = trailerRightWorld, color = COLOR_TRAILER },
            })
        end
    else
        if SegmentPool and SegmentPool.applySegments then
            SegmentPool:applySegments(leftWorld, rightWorld, COLOR_ACTIVE)
        end
    end
end

---Draw-phase entry. In i3d mode this is a no-op; in debug mode it flushes
---the collected drawDebugLine calls.
function SteeringPathIndicator:draw()
    if SegmentPool and SegmentPool.drawFallback then SegmentPool:drawFallback() end
end
