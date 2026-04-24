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
-- Get current speed in km/h. lastSpeed/motor.lastSpeed are m/s (kmh = speed * 3.6).
-- getLastSpeed() in FS25 returns km/h, so use raw value as kmh when that source is used.
---------------------------------------------------------------------------
function CruiseControlPlus.getCurrentSpeedKmh(vehicle, config)
    if not vehicle then return nil end
    local speedMs = nil
    local speedSource = "none"
    if vehicle.lastSpeed ~= nil then
        speedMs = math.abs(vehicle.lastSpeed)
        speedSource = "lastSpeed"
    end
    if (speedMs == nil or speedMs < 0.01) and vehicle.spec_motorized and vehicle.spec_motorized.motor and vehicle.spec_motorized.motor.lastSpeed ~= nil then
        speedMs = math.abs(vehicle.spec_motorized.motor.lastSpeed)
        speedSource = "motor"
    end
    if (speedMs == nil or speedMs < 0.01) and vehicle.getLastSpeed and type(vehicle.getLastSpeed) == "function" then
        local gs = vehicle:getLastSpeed()
        if gs ~= nil and type(gs) == "number" then
            speedMs = math.abs(gs)
            speedSource = "getLastSpeed"
        end
    end
    if speedMs == nil or speedMs < 0.01 then return nil end
    -- getLastSpeed() in FS25 returns km/h; lastSpeed/motor.lastSpeed are m/s (GDN). Do not * 3.6 when source is getLastSpeed.
    local kmh = (speedSource == "getLastSpeed") and speedMs or (speedMs * 3.6)
    config = config or CruiseControlPlusSettings or {}
    local step = (config.roundingStepKmh and config.roundingStepKmh > 0) and config.roundingStepKmh or 1
    local minKmh = (config.minKmh ~= nil and config.minKmh >= 0) and config.minKmh or 0.5
    local maxKmh = (config.maxKmh ~= nil and config.maxKmh > 0) and config.maxKmh or nil

    kmh = math.floor(kmh / step + 0.5) * step
    if kmh < minKmh then
        if speedMs > 0 then kmh = math.max(1, minKmh) else return nil end
    end
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
