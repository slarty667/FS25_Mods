--[[
  HoldToDetach.lua  (variant C: speed-lock)

  Goal: stop accidental detaching mid-field. Detaching an implement is blocked while
  the vehicle is MOVING (faster than SPEED_LIMIT km/h). When (nearly) stopped,
  detaching works normally and instantly.

  Mechanism: we gate the vanilla `AttacherJoints:isDetachAllowed` -- the engine's own
  "may this be detached right now?" check (returns allowed, optionalWarning). No input
  internals, no hold timing, no per-frame polling. Fail-open: if speed can't be read,
  detaching is allowed -- the mod can never make detaching impossible.
]]

HoldToDetach = {}

-- Below this speed (km/h) detaching is allowed; above it, it's blocked.
HoldToDetach.SPEED_LIMIT = 1.0

HoldToDetach.enabled = true
HoldToDetach.installed = false

local function logInfo(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[HoldToDetach] " .. fmt, ...)
    end
end

--- Localized hint shown when a detach is blocked because the vehicle is moving.
local function getWarningText()
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText("HOLDTODETACH_STOP_FIRST") then
        return g_i18n:getText("HOLDTODETACH_STOP_FIRST")
    end
    return "Zum Abkuppeln anhalten"
end

--- Overwrite for AttacherJoints.isDetachAllowed.
--- Signature from Utils.overwrittenFunction: (self, superFunc, ...originalArgs).
--- Vanilla returns (isAllowed[, warning]); we keep that contract.
function HoldToDetach.isDetachAllowed(self, superFunc, ...)
    if not HoldToDetach.enabled then
        return superFunc(self, ...)
    end

    -- Current speed in km/h; fail open if the method isn't available on this object.
    local speed = nil
    if self ~= nil and type(self.getLastSpeed) == "function" then
        local ok, v = pcall(self.getLastSpeed, self)
        if ok and type(v) == "number" then
            speed = v
        end
    end

    if speed ~= nil and speed > HoldToDetach.SPEED_LIMIT then
        -- Moving -> block detaching and surface a hint.
        return false, getWarningText()
    end

    -- Stopped (or speed unknown) -> behave exactly like vanilla.
    return superFunc(self, ...)
end

--- Replace the global AttacherJoints.isDetachAllowed once, before vehicle types are
--- validated (so the per-type overwritten-function registration picks up our version).
function HoldToDetach.install()
    if HoldToDetach.installed then
        return true
    end
    if AttacherJoints == nil or type(AttacherJoints.isDetachAllowed) ~= "function" then
        return false
    end
    AttacherJoints.isDetachAllowed = Utils.overwrittenFunction(AttacherJoints.isDetachAllowed, HoldToDetach.isDetachAllowed)
    HoldToDetach.installed = true
    logInfo("installed (speed-lock, limit=%.1f km/h)", HoldToDetach.SPEED_LIMIT)
    return true
end
