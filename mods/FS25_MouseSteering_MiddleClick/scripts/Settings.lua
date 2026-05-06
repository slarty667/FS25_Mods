--[[
  Settings.lua
  Configurable parameters for FS25_MouseSteering_MiddleClick.
  Values are persisted globally per user profile in
    modSettings/FS25_MouseSteering_MiddleClick.xml
  UI integration hooks into the vanilla General Settings page via UIHelper.lua.
]]

-- Split into two tables by design:
--   MouseSteeringSettings    — pure data values + persistence + the injectMenu entry point.
--   MouseSteeringSettingsUI  — owns the UI control objects created by UIHelper.
-- Keeping them separate is mandatory: UIHelper writes control objects into
-- owningTable[name], which would otherwise overwrite our numeric values
-- (then setXMLFloat blows up at save-time, and `deadzone < x` blows up at read-time).
MouseSteeringSettings = {}
MouseSteeringSettingsUI = {}
MouseSteeringSettingsUI.controls = {}

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local DEFAULTS = {
    -- Steering sensitivity
    rateSensitivity    = 9.0,    -- how fast mouse displacement accumulates into steering
    deadzone           = 0.02,   -- steering output below this is clamped to zero
    mouseDeadzone      = 0.003,  -- mouse displacement below this is ignored
    -- Visual feedback
    hudBarEnabled      = true,   -- show the top-of-screen steering bar
    pathIndicatorMode  = 2,      -- path projection visibility: 1=off, 2=on steering, 3=only mouse, 4=always
    trailerPathEnabled = true,   -- show a second (yellow) path for the trailer rear axle when reversing
    -- Steering-linked camera yaw (look into the corner) while LMB steering
    steeringHeadTurnEnabled   = true,
    steeringHeadTurnMaxDeg    = 85,   -- max extra yaw at full steer (each side); ~90 suits hard shoulder-check
    steeringHeadTurnResponse  = 14,   -- higher = snappier follow (decay uses same scale)
    steeringHeadTurnInvert    = false, -- flip direction if it feels wrong for a vehicle
    -- Smooth return of mouse steering after LMB release (matches keyboard feel)
    steeringReleaseUseGameSetting = true, -- read game steering return % when available
    steeringReleasePercent       = 80,   -- fallback / manual % (higher = faster recentre)
    -- NOTE: the old servoSpeedHigh/servoFactorLow settings were removed.
    -- Servo damping now scales against the vehicle's own top speed (see MouseSteering:update).
}

---------------------------------------------------------------------------
-- Apply defaults (only where not set yet)
---------------------------------------------------------------------------
local function applyDefaults()
    for k, v in pairs(DEFAULTS) do
        if MouseSteeringSettings[k] == nil then
            MouseSteeringSettings[k] = v
        end
    end
end

applyDefaults()

---------------------------------------------------------------------------
-- Control descriptors used by UIHelper to build the UI
-- For ranges:  { name, min, max, step, autoBind=true }
-- For bools:   { name, autoBind=true }
-- Each name has two l10n keys: "ms_<name>_short" and "ms_<name>_long"
---------------------------------------------------------------------------
MouseSteeringSettings.controlProperties = {
    { name = "rateSensitivity",     min = 0.5,  max = 25.0, step = 0.5,   autoBind = true },
    { name = "deadzone",            min = 0.0,  max = 0.20, step = 0.005, autoBind = true },
    { name = "mouseDeadzone",       min = 0.0,  max = 0.05, step = 0.001, autoBind = true },
    { name = "hudBarEnabled",       autoBind = true },
    -- Choice control with four modes: off / on-steering / only-mouse / always
    { name = "pathIndicatorMode",
      values = { "ms_pathMode_off", "ms_pathMode_steering", "ms_pathMode_mouse", "ms_pathMode_always" },
      autoBind = true },
    { name = "trailerPathEnabled", autoBind = true },
    { name = "steeringHeadTurnEnabled", autoBind = true },
    { name = "steeringHeadTurnMaxDeg",   min = 10, max = 110, step = 1,  autoBind = true },
    { name = "steeringHeadTurnResponse", min = 4,  max = 35, step = 1,   autoBind = true },
    { name = "steeringHeadTurnInvert",   autoBind = true },
    { name = "steeringReleaseUseGameSetting", autoBind = true },
    { name = "steeringReleasePercent", min = 5, max = 200, step = 1, autoBind = true },
}

---------------------------------------------------------------------------
-- XML persistence (global per user profile)
---------------------------------------------------------------------------
local XML_TAG = "MouseSteeringSettings"

local function log(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[MouseSteering] " .. fmt, ...)
    end
end

function MouseSteeringSettings:getSettingsPath()
    local path = getUserProfileAppPath()
    if path then
        return path .. "modSettings/FS25_MouseSteering_MiddleClick.xml"
    end
    return nil
end

function MouseSteeringSettings:loadFromXML()
    local path = self:getSettingsPath()
    if not path then return end

    local ok, xmlId = pcall(function()
        return loadXMLFile("MouseSteeringSettings", path)
    end)
    if not ok or not xmlId or xmlId == 0 then return end

    for k, def in pairs(DEFAULTS) do
        local xmlKey = XML_TAG .. "." .. k
        if type(def) == "boolean" then
            local ok2, val = pcall(function() return getXMLBool(xmlId, xmlKey) end)
            if ok2 and val ~= nil then self[k] = val end
        else
            local ok2, val = pcall(function() return getXMLFloat(xmlId, xmlKey) end)
            if ok2 and val ~= nil then self[k] = val end
        end
    end

    pcall(function() delete(xmlId) end)
    log("Settings loaded from %s", path)
end

function MouseSteeringSettings:saveToXML()
    local path = self:getSettingsPath()
    if not path then return end

    local ok, xmlId = pcall(function()
        return createXMLFile("MouseSteeringSettings", path, XML_TAG)
    end)
    if not ok or not xmlId or xmlId == 0 then return end

    for k, def in pairs(DEFAULTS) do
        local xmlKey = XML_TAG .. "." .. k
        if type(def) == "boolean" then
            pcall(function() setXMLBool(xmlId, xmlKey, self[k] and true or false) end)
        else
            pcall(function() setXMLFloat(xmlId, xmlKey, self[k] or def) end)
        end
    end

    pcall(function() saveXMLFile(xmlId) end)
    pcall(function() delete(xmlId) end)
    log("Settings saved to %s", path)
end

---------------------------------------------------------------------------
-- Inject our settings group into the vanilla General Settings page.
-- Uses UIHelper.lua (Farmsim Tim / Shad0wlife) for the heavy lifting.
-- Call this once after g_gui.screenControllers[InGameMenu] is ready.
---------------------------------------------------------------------------
function MouseSteeringSettings:injectMenu()
    if self._menuInjected then return end

    local inGameMenu = g_gui and g_gui.screenControllers and g_gui.screenControllers[InGameMenu]
    if not inGameMenu then
        log("injectMenu: InGameMenu screenController not ready, will retry")
        return false
    end

    local settingsPage = inGameMenu.pageSettings
    if not settingsPage or not settingsPage.generalSettingsLayout then
        log("injectMenu: pageSettings not ready, will retry")
        return false
    end

    -- UIHelper pulls current values out of the targetTable on every
    -- InGameMenuSettingsFrame:onFrameOpen, and writes changes back as they happen.
    -- owningTable = MouseSteeringSettingsUI (holds the control objects)
    -- targetTable = MouseSteeringSettings   (holds the actual numeric/bool values)
    UIHelper.createControlsDynamically(
        settingsPage,
        "ms_section_title",                 -- i18n key for the "Mouse Steering" section header
        MouseSteeringSettingsUI,            -- owningTable
        self.controlProperties,
        "ms_"                               -- l10n key prefix
    )

    UIHelper.setupAutoBindControls(MouseSteeringSettingsUI, self, function(_, _control)
        self:saveToXML()
    end)

    self._menuInjected = true
    log("Menu injected into General Settings page")
    return true
end
