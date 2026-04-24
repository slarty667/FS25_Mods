--[[
  MouseSteering.lua
  FS25_MouseSteering_MiddleClick: realistic mouse steering for keyboard+mouse.
  Armed by default when entering a vehicle; Ctrl+M or middle-click toggles armed off/on.
  Hold LMB to steer with mouse movement. Steering returns smoothly to center when LMB is released.
  
  Key difference from original FS25_mouseSteering:
  - LMB is mandatory for steering (original: always on when activated).
  - Uses mouseEvent posX displacement-from-center as a steering RATE input.
    FS25 recenters the cursor to 0.5 when LMB is held (relative mouse mode),
    so delta-accumulation would self-cancel. The rate model handles this:
    cursor away from center → steer; cursor at center → hold.
  - Steering is written directly to spec_drivable.lastInputValues.axisSteer
    (like the original mod) to prevent the game from overwriting the value.
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

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(MouseSteering.LOG_PREFIX .. " " .. fmt, ...)
    end
end

local function getConfig()
    return MouseSteeringSettings or {}
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
        self.active = false
        self.lmbDown = false
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
    self.steeringValue = 0
    self._mouseSteerRate = nil
    self.drawVehicle = vehicle

    -- Auto-disarm when a frontloader is attached: mouse steering and
    -- frontloader-arm control would both grab the mouse, which makes
    -- pallet work miserable. User can still flip MS on manually with
    -- Ctrl+M / middle-click if they really want.
    local hasFL = false
    if VehicleIntrospection and VehicleIntrospection.hasFrontloader then
        local ok, v = pcall(function() return VehicleIntrospection:hasFrontloader(vehicle) end)
        if ok then hasFL = v end
    end
    if hasFL then
        self.armed = false
        log("Armed OFF (default on enter — frontloader detected, MS suppressed; toggle with Ctrl+M)")
    else
        self.armed = true
        log("Armed ON (default on enter)")
    end
end

function MouseSteering:onControlledVehicleChanged(vehicle)
    if vehicle == self._lastControlVehicle then return end
    self._lastControlVehicle = vehicle
    if vehicle then
        self:armByDefault(vehicle)
    else
        -- Player left the vehicle: explicit disarm + state clear, so the next
        -- enter goes through armByDefault from a known-clean baseline.
        self.armed = false
        self.active = false
        self.lmbDown = false
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
-- press, which cancelled each other out (on vehicles with frontloader, where
-- armed started =false, the cancel-out kept it stuck off).
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
            self._mouseSteerRate = 0
            -- Wait for the cursor to come near 0.5 before accepting steering
            -- input. This protects against starting a session with the cursor
            -- somewhere on the screen edge — e.g. right after the user
            -- toggled mouse mode with RMB and then re-grips LMB.
            self._awaitingRecenter = true
            self._otherMouseButtonDown = false
            log("Active ON (LMB down)")
        end
        if isUp and self.lmbDown then
            self.lmbDown = false
            self.active = false
            self._mouseSteerRate = nil
            self._awaitingRecenter = false
            self._otherMouseButtonDown = false
            log("Active OFF (LMB up)")
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
-- update: accumulate steering while active, let game physics handle centering
---------------------------------------------------------------------------
function MouseSteering:update(dt)
    self:ensureCameraExtensionInstalled()

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

    local vehicle = self:getControlledVehicle()
    if not vehicle then
        if self.armed then
            self.armed = false
            self.active = false
            self.lmbDown = false
            self.steeringValue = 0
        end
        self._lastControlVehicle = nil
        return
    end

    -- (Old Ctrl+M / MMB polling removed: those were legacy trigger paths that
    --  fired in parallel with the MOUSESTEERING_TOGGLE_ARMED action event,
    --  causing double-toggles. Single source of truth now is the action event.)

    if not self.armed then return end

    -- Menu? force inactive
    if g_inGameMenu and g_inGameMenu.isOpen then
        self.active = false
        self.lmbDown = false
    end

    if not self:isSteeringAllowed(vehicle) then return end

    local cfg = getConfig()
    local deadzone = cfg.deadzone or 0.02

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
    -- Apply steering: only while LMB is held (active).
    -- When LMB is released, we stop writing to axisSteer entirely.
    -- The game's vehicle physics (caster/self-centering) will return
    -- the wheels to center naturally, speed-dependent — just like
    -- releasing A/D keys. No artificial software centering needed.
    -----------------------------------------------------------------
    if self.active then
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
    else
        -- LMB released: reset our internal value for the next steering session.
        -- The game physics handles the actual wheel centering.
        self.steeringValue = 0
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
    if not self.armed or not self.active then return end

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
