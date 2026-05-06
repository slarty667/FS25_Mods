--[[
  MouseSteering.lua
  FS25_MouseSteering_MiddleClick: realistic mouse steering for keyboard+mouse.
  Armed by default when entering a vehicle; Ctrl+M or middle-click toggles armed off/on.
  Hold LMB to steer with mouse movement. Steering returns smoothly to center when LMB is released.
  With a frontloader: stays armed; mouse handling pauses only while the loader arm or a tool
  on that arm is selected (see VehicleIntrospection:isFrontloaderBranchSelected).
  
  Key difference from original FS25_mouseSteering:
  - LMB is mandatory for steering (original: always on when activated).
  - Uses mouseEvent posX displacement-from-center as a steering RATE input.
    FS25 recenters the cursor to 0.5 when LMB is held (relative mouse mode),
    so delta-accumulation would self-cancel. The rate model handles this:
    cursor away from center → steer; cursor at center → hold.
  - Steering is written directly to spec_drivable.lastInputValues.axisSteer
    (like the original mod) to prevent the game from overwriting the value.
  - Optional steering-linked camera yaw (look into the corner) while LMB steering;
    applied after VehicleCamera:update (see afterVehicleCameraUpdate).
  - After LMB release, steering (and head-turn) decay smoothly toward centre,
    scaled by the game's steering return / mod fallback (see getSteeringReleasePercent).
]]

MouseSteering = {}
MouseSteering.MOD_NAME = "FS25_MouseSteering_MiddleClick"
MouseSteering.LOG_PREFIX = "[MouseSteering]"

-- State
MouseSteering.armed = false
MouseSteering.active = false        -- true while LMB held
MouseSteering.steeringValue = 0     -- accumulated steering [-1, 1]
MouseSteering.lmbDown = false
MouseSteering.drawVehicle = nil
MouseSteering.lastActiveVehicle = nil
MouseSteering._lastControlVehicle = nil
MouseSteering._steeringCoast = false
MouseSteering._syncTakeoverFramesLeft = 0

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(MouseSteering.LOG_PREFIX .. " " .. fmt, ...)
    end
end

local function getConfig()
    return MouseSteeringSettings or {}
end

--- Steering return speed percent (higher = faster recentre after LMB release).
--- Tries GameSettings first (names vary by patch); falls back to mod setting.
local function getSteeringReleasePercent()
    local cfg = getConfig()
    if cfg.steeringReleaseUseGameSetting ~= false
        and g_gameSettings and GameSettings and GameSettings.SETTING then
        local names = {
            "STEERING_BACK_SPEED",
            "INPUT_STEERING_BACK_SPEED",
            "STEERING_RETURN_SPEED",
            "STEERING_INPUT_RETURN_SPEED",
            "STEERING_INPUT_HELP_SPEED",
        }
        for _, n in ipairs(names) do
            local id = GameSettings.SETTING[n]
            if id ~= nil then
                local ok, v = pcall(function() return g_gameSettings:getValue(id) end)
                if ok and type(v) == "number" and v == v then
                    local p = v
                    if p <= 2 and p >= 0 then
                        p = p * 100
                    end
                    return math.max(5, math.min(200, p))
                end
            end
        end
    end
    local p = cfg.steeringReleasePercent or 80
    return math.max(5, math.min(200, p))
end

--- Normalised steering [-1,1] for LMB takeover: pick strongest plausible signal
--- (physical wheel, Drivable axisSide, last axisSteer). Matches path-indicator logic.
local function readSteeringTakeoverNormalized(vehicle)
    if not vehicle then return 0 end
    local rt, ax, ins = nil, nil, nil
    pcall(function()
        if type(vehicle.rotatedTime) == "number"
            and type(vehicle.rotatedTimeMax) == "number"
            and vehicle.rotatedTimeMax > 0 then
            rt = vehicle.rotatedTime / vehicle.rotatedTimeMax
        end
    end)
    pcall(function()
        local d = vehicle.spec_drivable
        if d and type(d.axisSide) == "number" then
            ax = d.axisSide
        end
    end)
    pcall(function()
        local d = vehicle.spec_drivable
        if d and d.lastInputValues and type(d.lastInputValues.axisSteer) == "number" then
            ins = d.lastInputValues.axisSteer
        end
    end)
    local function clamp1(x)
        if x == nil or x ~= x then return nil end
        if x > 1 then return 1 end
        if x < -1 then return -1 end
        return x
    end
    rt, ax, ins = clamp1(rt), clamp1(ax), clamp1(ins)
    local best = 0
    local function consider(c)
        if c == nil or c ~= c then return end
        if math.abs(c) > math.abs(best) then
            best = c
        end
    end
    consider(rt)
    consider(ax)
    consider(ins)
    return best
end

---------------------------------------------------------------------------
-- Steering allowed?
---------------------------------------------------------------------------
function MouseSteering:isSteeringAllowed(vehicle)
    if not g_currentMission or not vehicle then return false end

    -- Check if the vehicle itself reports being entered and controlled.
    -- (g_currentMission.controlledVehicle is nil in many FS25 contexts.)
    if vehicle.getIsEntered and not vehicle:getIsEntered() then return false end
    if vehicle.getIsControlled and not vehicle:getIsControlled() then return false end

    if g_inGameMenu and g_inGameMenu.isOpen then return false end
    if vehicle.getIsMotorStarted then
        local ok, running = pcall(function() return vehicle:getIsMotorStarted() end)
        if ok and not running then return false end
    end
    return true
end

---While the frontloader arm or a tool on that arm is the selected implement,
---vanilla uses the mouse for the loader — we must not consume mouse movement.
---@param vehicle table|nil
---@return boolean
function MouseSteering:isFrontloaderSelectionSuppressingMouse(vehicle)
    if not vehicle then return false end
    if not VehicleIntrospection or not VehicleIntrospection.isFrontloaderBranchSelected then
        return false
    end
    local ok, v = pcall(function()
        return VehicleIntrospection:isFrontloaderBranchSelected(vehicle)
    end)
    return ok and v == true
end

---Zero frontloader hydraulic lastInputValues while LMB mouse-steering (cab focus).
---@param vehicle table|nil controlled vehicle (tractor)
---@param phase string|nil debug tag: missionUpdate | vehiclePost | modDraw
function MouseSteering:tryZeroFrontloaderHydraulics(vehicle, phase)
    if not self.armed or not self.active then return end
    if not vehicle then return end
    if self:isFrontloaderSelectionSuppressingMouse(vehicle) then return end
    if VehicleIntrospection and VehicleIntrospection.zeroMouseHydraulicAxesOnFrontloaderHardware then
        pcall(function()
            VehicleIntrospection:zeroMouseHydraulicAxesOnFrontloaderHardware(vehicle.rootVehicle or vehicle, phase)
        end)
    end
end

---------------------------------------------------------------------------
-- Toggle Armed
---------------------------------------------------------------------------
function MouseSteering:onToggleArmed(vehicle)
    if not vehicle then
        vehicle = self:getControlledVehicle()
    end
    if not vehicle then
        log("onToggleArmed: no vehicle, ignoring")
        return
    end
    self.lastActiveVehicle = vehicle
    local wantArmed = not self.armed
    log("onToggleArmed: wantArmed=%s vehicle=%s", tostring(wantArmed), tostring(vehicle.getName and vehicle:getName() or "?"))
    -- Require engine running
    if wantArmed and vehicle.getIsMotorStarted then
        local ok, running = pcall(function() return vehicle:getIsMotorStarted() end)
        if ok and not running then
            local msg = (g_i18n and g_i18n.getText and g_i18n:getText("MOUSESTEERING_WARNING_MOTOR_NOT_STARTED"))
                or "Start the engine first"
            if g_currentMission and g_currentMission.showBlinkingWarning then
                g_currentMission:showBlinkingWarning(msg, 2000)
            end
            return
        end
    end
    self.armed = wantArmed
    if not self.armed then
        self:clearSteeringHeadTurn()
        self.active = false
        self.lmbDown = false
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
        self.steeringValue = 0
        self._mouseSteerRate = nil
        self.drawVehicle = nil
    else
        self.drawVehicle = vehicle
    end
    log("Armed %s", self.armed and "ON" or "OFF")
end

---------------------------------------------------------------------------
-- Default armed when the controlled vehicle instance changes (enter / switch)
---------------------------------------------------------------------------
function MouseSteering:armByDefault(vehicle)
    if not vehicle then return end
    self.lastActiveVehicle = vehicle
    self.active = false
    self.lmbDown = false
    self._steeringCoast = false
    self._syncTakeoverFramesLeft = 0
    self.steeringValue = 0
    self._mouseSteerRate = nil
    self.drawVehicle = vehicle

    -- Frontloader: mouse steering stays armed by default; input is suppressed only
    -- while the loader arm or a tool on that arm is selected (see isFrontloaderSelectionSuppressingMouse).
    self.armed = true
    log("Armed ON (default on enter; frontloader mouse share only when FL/tool selected)")
end

function MouseSteering:onControlledVehicleChanged(vehicle)
    if vehicle == self._lastControlVehicle then return end
    self:clearSteeringHeadTurn()
    self._lastControlVehicle = vehicle
    if vehicle then
        self:armByDefault(vehicle)
    else
        -- Player left the vehicle: explicit disarm + state clear, so the next
        -- enter goes through armByDefault from a known-clean baseline.
        self.armed = false
        self.active = false
        self.lmbDown = false
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
        self.steeringValue = 0
        self._mouseSteerRate = nil
        self.drawVehicle = nil
        log("Armed OFF (left vehicle)")
    end
end

---------------------------------------------------------------------------
-- Helper: find the vehicle the player currently controls
---------------------------------------------------------------------------
function MouseSteering:getControlledVehicle()
    local m = g_currentMission
    if not m then return nil end
    return m.controlledVehicle
        or (m.mouseSteering and m.mouseSteering.controlledVehicle)
        or self.drawVehicle
        or self.lastActiveVehicle
end

---------------------------------------------------------------------------
-- keyEvent: no key handling here anymore. Ctrl+M (and Ctrl+Shift+M and MMB)
-- are all wired through the MOUSESTEERING_TOGGLE_ARMED action event bound in
-- MouseSteeringVehicle.lua. The previous keyEvent + update() polling + mouseEvent
-- MMB path combined with the action event caused 2-3 simultaneous triggers per
-- press, which cancelled each other out.
---------------------------------------------------------------------------
function MouseSteering:keyEvent(unicode, sym, modifier, isDown)
    -- intentionally empty; kept for API symmetry.
end

---------------------------------------------------------------------------
-- mouseEvent: LMB controls the "active" steering state. MMB toggle is now
-- handled exclusively by the MOUSESTEERING_TOGGLE_ARMED action event
-- (binding in modDesc.xml covers MOUSE_BUTTON_2).
---------------------------------------------------------------------------
function MouseSteering:mouseEvent(posX, posY, isDown, isUp, button)
    if not self.armed then return end
    local vehicle = self:getControlledVehicle()
    if self:isFrontloaderSelectionSuppressingMouse(vehicle) then return end

    -- Extra (non-LMB) button tracking. Design goal: LMB keeps steering (wheel
    -- stays at its current angle), LMB+RMB additionally enables free-look
    -- (camera rotates with mouse). Like a real driver: hands on the wheel,
    -- head turning. Implementation:
    --   - On extra-button DOWN: freeze our rate (hold current steering value,
    --     no more accumulation). active stays true so axisSteer keeps being
    --     written each frame, so the wheel doesn't self-centre.
    --   - On extra-button UP: mark "awaiting recenter" — don't resume rate
    --     accumulation until the cursor has come back near 0.5. This avoids
    --     a full-lock swing if FS25's mouse mode got toggled during the hold.
    --   - VehicleCameraExtension checks _otherMouseButtonDown and lets the
    --     camera-look action pass through while set (i.e. while RMB is held).
    if button ~= nil and button ~= 1 then
        if isDown then
            self._otherMouseButtonDown = true
            self._mouseSteerRate = nil  -- freeze; hold current steering value
        end
        if isUp then
            self._otherMouseButtonDown = false
            self._awaitingRecenter = true
        end
    end

    -- LMB = button 1
    if button == 1 then
        if isDown and not self.lmbDown then
            self.lmbDown = true
            self.active = true
            self._steeringCoast = false
            -- Keep head-turn smoothing continuous with what is already on the camera
            -- (avoids a jump when grabbing LMB during coast / return).
            self._headTurnSmoothed = self._headTurnOffsetRad or self._headTurnSmoothed or 0
            self._mouseSteerRate = 0
            -- Wait for the cursor to come near 0.5 before accepting steering
            -- input. This protects against starting a session with the cursor
            -- somewhere on the screen edge — e.g. right after the user
            -- toggled mouse mode with RMB and then re-grips LMB.
            self._awaitingRecenter = true
            self._otherMouseButtonDown = false

            -- Hand-over: grab the wheel at the current angle (keyboard coast,
            -- mid-turn, etc.). readSteeringTakeoverNormalized matches path-indicator
            -- sources; update() runs one sync same/next tick if vehicle was not ready.
            self._syncTakeoverFramesLeft = 2
            self.steeringValue = readSteeringTakeoverNormalized(vehicle)
            log("Active ON (LMB down, takeover steer=%+.3f)", self.steeringValue or 0)
        end
        if isUp and self.lmbDown then
            self.lmbDown = false
            self.active = false
            self._mouseSteerRate = nil
            self._awaitingRecenter = false
            self._otherMouseButtonDown = false
            local dz = (MouseSteeringSettings and MouseSteeringSettings.deadzone) or 0.02
            if math.abs(self.steeringValue or 0) > dz then
                self._steeringCoast = true
            else
                self._steeringCoast = false
                self.steeringValue = 0
            end
            log("Active OFF (LMB up, coast=%s)", tostring(self._steeringCoast))
        end
    end

    -- Rate calculation:
    --   - Skip entirely if not active, or while an extra button is held.
    --   - After an extra-button release, wait for the cursor to come near
    --     0.5 before resuming rate updates. If FS25's mouse mode didn't
    --     flip during the hold, this clears within a frame (the game keeps
    --     recentering). If it did flip, the user notices the steering is
    --     frozen, releases LMB, and re-grips from a clean state.
    if self.armed and self.active and not self._otherMouseButtonDown then
        local offset = posX - 0.5

        if self._awaitingRecenter then
            if math.abs(offset) < 0.05 then
                self._awaitingRecenter = false
            else
                self._mouseSteerRate = 0  -- hold, don't accumulate
                return
            end
        end

        local mDz = (MouseSteeringSettings and MouseSteeringSettings.mouseDeadzone) or 0.003
        if math.abs(offset) > mDz then
            self._mouseSteerRate = offset
        else
            self._mouseSteerRate = 0
        end
    else
        self._mouseSteerRate = nil
    end
end

---------------------------------------------------------------------------
-- Ensure VehicleCamera overwrite is installed (retry pattern)
---------------------------------------------------------------------------
function MouseSteering:ensureCameraExtensionInstalled()
    if self._cameraExtInstalled then return end
    if VehicleCameraExtension and VehicleCameraExtension.install then
        if VehicleCameraExtension:install() then
            self._cameraExtInstalled = true
        end
    end
end

---------------------------------------------------------------------------
-- Steering-linked camera yaw (after VehicleCamera:update; see VehicleCameraExtension)
---------------------------------------------------------------------------
function MouseSteering:clearSteeringHeadTurn()
    local cam = self._headTurnCameraRef
    local off = self._headTurnOffsetRad or 0
    if cam and off ~= 0 then
        pcall(function()
            if cam.rotY ~= nil then
                cam.rotY = cam.rotY - off
            end
        end)
    end
    self._headTurnOffsetRad = 0
    self._headTurnSmoothed = 0
    self._headTurnCameraRef = nil
end

function MouseSteering:afterVehicleCameraUpdate(camera, dt)
    if not camera or not camera.vehicle then return end
    local vehicle = camera.vehicle
    local spec = vehicle.spec_enterable
    if not spec or camera ~= spec.activeCamera then return end
    if camera.isRotatable == false then return end

    local cfg = getConfig()
    local enabled = cfg.steeringHeadTurnEnabled ~= false
    local prev = self._headTurnOffsetRad or 0

    local should = enabled
        and self.armed
        and (self.active or self._steeringCoast)
        and not self._otherMouseButtonDown
        and self:isSteeringAllowed(vehicle)
        and not self:isFrontloaderSelectionSuppressingMouse(vehicle)

    local dti = dt or g_currentDt or 16
    local target = 0
    if should then
        local sv = self.steeringValue or 0
        local deadzone = cfg.deadzone or 0.02
        if math.abs(sv) < deadzone then sv = 0 end
        local maxDeg = cfg.steeringHeadTurnMaxDeg or 85
        if maxDeg < 0.5 then maxDeg = 0.5 end
        if maxDeg > 110 then maxDeg = 110 end
        local maxRad = math.rad(maxDeg)
        local sign = cfg.steeringHeadTurnInvert and 1 or -1
        -- Reverse travel: steering axis is still "left wheel" but the cabin faces
        -- the rear — flip head-turn so "steer left" looks left along the path of travel.
        local reverseMul = 1
        if VehicleIntrospection and VehicleIntrospection.getMotion then
            local ok, _, isRev = pcall(function()
                return VehicleIntrospection:getMotion(vehicle)
            end)
            if ok and isRev then
                reverseMul = -1
            end
        end
        target = sign * sv * maxRad * reverseMul
        local response = cfg.steeringHeadTurnResponse or 14
        local alpha = 1 - math.exp(-dti * 0.001 * response)
        if alpha > 1 then alpha = 1 elseif alpha < 0 then alpha = 0 end
        local sm = self._headTurnSmoothed or 0
        self._headTurnSmoothed = sm + (target - sm) * alpha
    else
        local response = cfg.steeringHeadTurnResponse or 14
        local alpha = 1 - math.exp(-dti * 0.001 * response * 0.65)
        if alpha > 1 then alpha = 1 elseif alpha < 0 then alpha = 0 end
        local sm = self._headTurnSmoothed or 0
        self._headTurnSmoothed = sm * (1 - alpha)
        if math.abs(self._headTurnSmoothed) < 0.0001 then self._headTurnSmoothed = 0 end
    end

    local new = self._headTurnSmoothed or 0
    local useAnchoredCoast = self._steeringCoast and not self.active and should

    pcall(function()
        if useAnchoredCoast then
            -- During coast: steer the cabin view back toward the interior default
            -- (origRotY) while the steering-linked offset decays — same "null" as on enter.
            local origY = camera.origRotY
            if origY ~= nil then
                local desired = origY + new
                local vk = (cfg.steeringHeadTurnResponse or 14) * 0.55
                local k = 1 - math.exp(-dti * 0.001 * vk)
                if k > 1 then k = 1 elseif k < 0 then k = 0 end
                camera.rotY = camera.rotY + (desired - camera.rotY) * k
            else
                camera.rotY = camera.rotY - prev + new
            end
        else
            -- LMB steering: incremental head-turn overlay (unchanged).
            camera.rotY = camera.rotY - prev + new
        end
    end)
    self._headTurnOffsetRad = new
    self._headTurnCameraRef = camera
end

---------------------------------------------------------------------------
-- update: accumulate while LMB active; smooth decay ("coast") after release
---------------------------------------------------------------------------
function MouseSteering:update(dt)
    self:ensureCameraExtensionInstalled()
    if VehicleCameraExtension and VehicleCameraExtension.deferredLoaderLookWrapScan then
        VehicleCameraExtension:deferredLoaderLookWrapScan()
    end

    -- Inject our settings group into the General Settings page.
    -- injectMenu() is idempotent (sets _menuInjected) and safe to retry until the UI is ready.
    if MouseSteeringSettings and not MouseSteeringSettings._menuInjected and MouseSteeringSettings.injectMenu then
        MouseSteeringSettings:injectMenu()
    end

    -- Try to wrap RMB-bound vanilla actions so that pressing RMB while LMB
    -- is held doesn't toggle cursor/zoom. Idempotent and retried until the
    -- input binding has all its events registered.
    if RmbSuppression and not RmbSuppression.installed and RmbSuppression.install then
        RmbSuppression:install()
    end

    if VehicleCameraExtension and VehicleCameraExtension.tickLateGlobalSpecHooks then
        pcall(function()
            VehicleCameraExtension:tickLateGlobalSpecHooks(dt)
        end)
    end

    local vehicle = self:getControlledVehicle()
    if not vehicle then
        if self.armed then
            self.armed = false
            self.active = false
            self.lmbDown = false
            self._steeringCoast = false
            self._syncTakeoverFramesLeft = 0
            self.steeringValue = 0
        end
        self:clearSteeringHeadTurn()
        self._lastControlVehicle = nil
        return
    end

    -- (Old Ctrl+M / MMB polling removed: those were legacy trigger paths that
    --  fired in parallel with the MOUSESTEERING_TOGGLE_ARMED action event,
    --  causing double-toggles. Single source of truth now is the action event.)

    if not self.armed then return end

    -- Frontloader / fork selected: release our grab so vanilla loader mouse works.
    if self:isFrontloaderSelectionSuppressingMouse(vehicle) then
        self.active = false
        self.lmbDown = false
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
        self.steeringValue = 0
        self._mouseSteerRate = nil
        self._otherMouseButtonDown = false
        self._awaitingRecenter = false
        if SteeringPathIndicator and SteeringPathIndicator.update then
            SteeringPathIndicator:update(dt, vehicle)
        end
        return
    end

    -- Menu? force inactive
    if g_inGameMenu and g_inGameMenu.isOpen then
        self.active = false
        self.lmbDown = false
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
        self.steeringValue = 0
    end

    if not self:isSteeringAllowed(vehicle) then
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
        if not self.active then
            self.steeringValue = 0
        end
        if SteeringPathIndicator and SteeringPathIndicator.update then
            SteeringPathIndicator:update(dt, vehicle)
        end
        return
    end

    local cfg = getConfig()
    local deadzone = cfg.deadzone or 0.02

    -- Re-sample takeover once at the start of steering (after physics/input),
    -- so LMB "hand on wheel" matches the real wheel even when mouseEvent ran early.
    if self.active and (self._syncTakeoverFramesLeft or 0) > 0 then
        self.steeringValue = readSteeringTakeoverNormalized(vehicle)
        self._syncTakeoverFramesLeft = self._syncTakeoverFramesLeft - 1
    end

    -----------------------------------------------------------------
    -- Consume mouse steering rate (displacement from center = steering rate)
    -- Adaptive servo: sensitivity scales with speed (low speed = direct, high speed = heavier)
    -----------------------------------------------------------------
    if self.active and self._mouseSteerRate and self._mouseSteerRate ~= 0 then
        local rateSens = cfg.rateSensitivity or 9.0

        -- Adaptive servo: reduce sensitivity relative to the current vehicle's top speed.
        -- speedHigh is no longer a global setting — it's the vehicle's own max speed, so a
        -- tractor at full throttle gets the same relative damping as a truck at full throttle.
        local speedKmh = 0
        if vehicle.lastSpeed then
            speedKmh = math.abs(vehicle.lastSpeed) * 3.6
        elseif vehicle.spec_motorized and vehicle.spec_motorized.motor and vehicle.spec_motorized.motor.lastSpeed then
            speedKmh = math.abs(vehicle.spec_motorized.motor.lastSpeed) * 3.6
        end
        local speedHigh = 40  -- fallback (mid-size tractor)
        if VehicleIntrospection and VehicleIntrospection.getMaxSpeed then
            speedHigh = VehicleIntrospection:getMaxSpeed(vehicle)
        end
        local factorLow = 0.25  -- felt right across classes; no longer user-configurable
        local speedFactor = 1 - (1 - factorLow) * math.min(speedKmh / speedHigh, 1)
        rateSens = rateSens * speedFactor

        local rate = self._mouseSteerRate * rateSens * (dt / 1000)
        self.steeringValue = self.steeringValue + rate
        self.steeringValue = math.max(-1, math.min(1, self.steeringValue))
    end

    -----------------------------------------------------------------
    -- Apply steering: while LMB held, or while "coasting" decay after release.
    -- Coast speed follows getSteeringReleasePercent() (game option when found).
    -----------------------------------------------------------------
    if self.active or self._steeringCoast then
        if self._steeringCoast and not self.active then
            -- Time constant ~ keyboard return: old 520*100/p was far too slow.
            -- Higher in-game % => smaller tau => faster decay.
            local p = math.max(12, getSteeringReleasePercent())
            local baseTau = 24
            local tauMs = baseTau * (100 / p)
            local dti = dt or g_currentDt or 16
            if tauMs < 5 then tauMs = 5 elseif tauMs > 320 then tauMs = 320 end
            self.steeringValue = (self.steeringValue or 0) * math.exp(-dti / tauMs)
            if math.abs(self.steeringValue) < math.max(deadzone * 0.5, 0.003) then
                self.steeringValue = 0
                self._steeringCoast = false
            end
        end

        local out = self.steeringValue
        if math.abs(out) < deadzone then out = 0 end

        local drivable = vehicle.spec_drivable
        if drivable and drivable.lastInputValues then
            drivable.lastInputValues.axisSteer = out
            drivable.lastInputValues.axisSteerIsAnalog = true
            if drivable.lastInputValues.axisSteerDeviceCategory == nil then
                local ok, cat = pcall(function() return InputDevice.CATEGORY.WHEEL end)
                if ok and cat then
                    drivable.lastInputValues.axisSteerDeviceCategory = cat
                end
            end
        end

        -- Frontloader fork / arm hydraulics still read mouse while the cab is selected;
        -- clear their axis* lastInputValues after we wrote steering (mission update order).
        if self.active then
            self:tryZeroFrontloaderHydraulics(vehicle, "missionUpdate")
        end
    else
        self.steeringValue = 0
        self._steeringCoast = false
        self._syncTakeoverFramesLeft = 0
    end

    -- Projected driving path: the indicator gates itself internally
    -- (pathIndicatorMode + vehicle validity + axisSteer threshold).
    if SteeringPathIndicator and SteeringPathIndicator.update then
        SteeringPathIndicator:update(dt, vehicle)
    end
end

---------------------------------------------------------------------------
-- loadMap
---------------------------------------------------------------------------
function MouseSteering:loadMap(name)
    -- Load persisted settings (global per user profile).
    if MouseSteeringSettings and MouseSteeringSettings.loadFromXML then
        MouseSteeringSettings:loadFromXML()
    end
    -- Inject our settings group into the vanilla General Settings page.
    -- May be too early on first call; retried from update() until successful.
    if MouseSteeringSettings and MouseSteeringSettings.injectMenu then
        MouseSteeringSettings:injectMenu()
    end
    -- Initialise the projected driving path indicator (loads I3D asset or falls back).
    if SteeringPathIndicator and SteeringPathIndicator.init then
        SteeringPathIndicator:init()
    end
    log("loaded — armed by default in vehicles; Ctrl+M or middle-click to toggle off/on; hold LMB to steer")
end

---------------------------------------------------------------------------
-- Draw graphical steering bar (drawFilledRect-based, Original-Mod style)
-- Only shown when armed and active (LMB held).
-- Fallback: renderText with block chars if drawFilledRect unavailable.
---------------------------------------------------------------------------
function MouseSteering:drawForVehicle(vehicle)
    if not vehicle or not g_currentMission then return end
    if not self.armed or not (self.active or self._steeringCoast) then return end
    if self:isFrontloaderSelectionSuppressingMouse(vehicle) then return end

    -- Gate: hudBarEnabled flag from settings (default true)
    local cfgGate = getConfig()
    if cfgGate.hudBarEnabled == false then return end

    local cfg = cfgGate
    local x = cfg.hudX or 0.5
    local y = cfg.hudY or 0.18
    local sv = math.max(-1, math.min(1, self.steeringValue or 0))

    pcall(function()
        local barWidthNorm = 0.15
        local barHeightNorm = 0.008
        local halfW = barWidthNorm / 2
        local left = x - halfW
        local top = y
        local centerX = x
        local fillEndX = centerX + sv * halfW

        if drawFilledRect then
            -- Background (dark)
            drawFilledRect(left, top, barWidthNorm, barHeightNorm, 0.1, 0.1, 0.1, 0.85)

            -- Fill (colored bar from center to current steering)
            if math.abs(sv) > 0.01 then
                local fillLeft = math.min(centerX, fillEndX)
                local fillRight = math.max(centerX, fillEndX)
                local fillW = fillRight - fillLeft
                drawFilledRect(fillLeft, top, fillW, barHeightNorm, 0.2, 0.7, 0.3, 0.9)
            end

            -- Center line (white, thin)
            local lineW = 0.002
            drawFilledRect(centerX - lineW / 2, top, lineW, barHeightNorm, 1, 1, 1, 1)
        elseif renderText then
            -- Fallback: graphic-style bar with block chars
            local w = 17
            local half = (w - 1) / 2
            local pos = math.floor(0.5 + half + sv * half)
            pos = math.max(1, math.min(w, pos))
            local chars = {}
            for i = 1, w do
                chars[i] = (i == pos) and "\226\150\136" or "\226\150\132"  -- full vs light block
            end
            if setTextAlignment then setTextAlignment(RenderText and RenderText.ALIGN_CENTER or 1) end
            if setTextColor then setTextColor(0.25, 0.85, 0.35, 1) end
            renderText(x, y, 0.024, table.concat(chars))
        end
    end)
end

function MouseSteering:draw()
    -- Steering bar (when armed and active, and hudBarEnabled)
    local vehicle = self.drawVehicle or (g_currentMission and g_currentMission.controlledVehicle)
    if vehicle then self:drawForVehicle(vehicle) end

    -- Path indicator draw-phase (only does work in drawDebugLine fallback mode).
    if SteeringPathIndicator and SteeringPathIndicator.draw then
        SteeringPathIndicator:draw()
    end
end
