--[[
  CruiseControlPlus.lua
  Shared logic for FS25_CruiseControlPlus: getCurrentSpeedKmh (vehicle.lastSpeed m/s -> km/h),
  HUD notification. Set-cruise-to-current is triggered by Vehicle action CRUISECONTROLPLUS_SET_TO_CURRENT.
]]

CruiseControlPlus = {}
CruiseControlPlus.MOD_NAME = "FS25_CruiseControlPlus"
CruiseControlPlus.LOG_PREFIX = "[CruiseControlPlus]"

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info(CruiseControlPlus.LOG_PREFIX .. " " .. fmt, ...)
    end
end

---------------------------------------------------------------------------
-- Get current speed in km/h.
-- IMPORTANT unit facts (GIANTS engine, verified against GDN "Vehicle Speed"):
--   * vehicle:getLastSpeed() returns km/h directly (== self.lastSpeed * 3600). AUTHORITATIVE.
--   * vehicle.lastSpeed / motor.lastSpeed are in m/ms (metres per millisecond), NOT m/s.
--     To get km/h from them you multiply by 3600, never by 3.6.
-- The old code preferred vehicle.lastSpeed and multiplied by 3.6 (off by 1000x), so above
-- ~36 km/h (lastSpeed >= 0.01) it produced ~0 and clamped the cruise target to 1 km/h.
-- Fix: trust getLastSpeed(); only fall back to lastSpeed * 3600 if the method is missing.
---------------------------------------------------------------------------
function CruiseControlPlus.getCurrentSpeedKmh(vehicle, config)
    if not vehicle then return nil end
    local kmh = nil
    if type(vehicle.getLastSpeed) == "function" then
        local gs = vehicle:getLastSpeed()
        if type(gs) == "number" then kmh = math.abs(gs) end
    end
    if kmh == nil and type(vehicle.lastSpeed) == "number" then
        kmh = math.abs(vehicle.lastSpeed) * 3600  -- m/ms -> km/h
    end
    if kmh == nil then return nil end

    config = config or CruiseControlPlusSettings or {}
    local step = (config.roundingStepKmh and config.roundingStepKmh > 0) and config.roundingStepKmh or 1
    local minKmh = (config.minKmh ~= nil and config.minKmh >= 0) and config.minKmh or 1
    local maxKmh = (config.maxKmh ~= nil and config.maxKmh > 0) and config.maxKmh or nil

    kmh = math.floor(kmh / step + 0.5) * step
    -- Below the minimum is treated as "too low" so the caller can show the warning,
    -- instead of silently locking the cruise target to a bogus 1 km/h.
    if kmh < minKmh then return nil end
    if maxKmh and kmh > maxKmh then kmh = maxKmh end
    return math.floor(kmh + 0.5)
end

function CruiseControlPlus:loadMap(name)
    log("loadMap %s", tostring(name))
end

-- HUD notification display duration (ms)
local HUD_NOTIFY_DURATION_MS = 2000

function CruiseControlPlus:draw(dt)
    if not CruiseControlPlusSettings or CruiseControlPlusSettings.showHudNotification == 0 then return end
    if not self.lastSetSpeedKmh or not self.lastSetSpeedTime then return end
    local now = (g_currentMission and g_currentMission.time) or (getTickCount and getTickCount()) or 0
    if now - self.lastSetSpeedTime > HUD_NOTIFY_DURATION_MS then return end

    pcall(function()
        local msg
        if g_i18n and g_i18n.getText then
            msg = g_i18n:getText("CRUISECONTROLPLUS_HUD_SET")
            if msg then msg = string.format(msg, self.lastSetSpeedKmh) end
        end
        if not msg then msg = string.format("Cruise set to %d km/h", self.lastSetSpeedKmh) end
        local x, y, fontSize = 0.5, 0.12, 0.022
        if setTextAlignment then setTextAlignment(RenderText and RenderText.ALIGN_CENTER or 1) end
        if setTextColor then setTextColor(0.3, 1, 0.5, 1) end
        if renderText then renderText(x, y, fontSize, msg) end
    end)
end
