--[[
  Settings.lua
  Persistent tuning values for NaviHelper. Loaded at mod start, saved on unload.
  Config file: <user profile>/modSettings/FS25_NaviHelper.xml

  Lets the route line and caching be tweaked without editing the Lua source.
  Values are applied onto the NaviHelper table in NaviHelper:loadMap().
]]

NaviHelperSettings = {}

local XML_TAG = "naviHelper"
local SETTINGS_FILE = "FS25_NaviHelper.xml"

-- key -> { default, type }. type: "bool" | "float" | "int"
local DEFAULTS = {
    drawRouteOnGround        = { true,  "bool"  },
    routeLineColorR          = { 0.10,  "float" },
    routeLineColorG          = { 0.42,  "float" },
    routeLineColorB          = { 0.20,  "float" },
    routeLineColorA          = { 0.25,  "float" },  -- emissive strength (rgb*a); low = calm, no bloom
    routeLineThickness       = { 0.40,  "float" },  -- width scale; lower = thinner stripe
    routeLineMaxSegments     = { 50,    "int"   },
    effectiveTargetCacheTime = { 4000,  "int"   },
    distanceCacheTime        = { 500,   "int"   },
    hudCenterX               = { 0.5,   "float" },
    hudCenterY               = { 0.12,  "float" },
}

-- List of the keys this module manages (so NaviHelper can copy them in one loop).
function NaviHelperSettings:keys()
    local out = {}
    for k in pairs(DEFAULTS) do out[#out + 1] = k end
    return out
end

local function settingsPath()
    if not getUserProfileAppPath then return nil end
    local base = getUserProfileAppPath()
    if not base then return nil end
    return base .. "modSettings/" .. SETTINGS_FILE
end

-- Ensure every managed value exists on self (defaults), even without a config file.
function NaviHelperSettings:applyDefaults()
    for k, spec in pairs(DEFAULTS) do
        if self[k] == nil then self[k] = spec[1] end
    end
end

function NaviHelperSettings:loadFromXML()
    self:applyDefaults()
    local path = settingsPath()
    if not path then return end
    if fileExists and not fileExists(path) then return end

    local xmlId
    local ok = pcall(function() xmlId = loadXMLFile("NaviHelperSettings", path) end)
    if not ok or not xmlId then return end

    for k, spec in pairs(DEFAULTS) do
        local key = XML_TAG .. "." .. k
        if spec[2] == "bool" then
            local ok2, v = pcall(function() return getXMLBool(xmlId, key) end)
            if ok2 and v ~= nil then self[k] = v end
        else
            local ok2, v = pcall(function() return getXMLFloat(xmlId, key) end)
            if ok2 and v ~= nil then
                self[k] = (spec[2] == "int") and math.floor(v + 0.5) or v
            end
        end
    end
    pcall(function() delete(xmlId) end)
end

function NaviHelperSettings:saveToXML()
    self:applyDefaults()
    local path = settingsPath()
    if not path then return end

    local xmlId
    local ok = pcall(function() xmlId = createXMLFile("NaviHelperSettings", path, XML_TAG) end)
    if not ok or not xmlId then return end

    for k, spec in pairs(DEFAULTS) do
        local key = XML_TAG .. "." .. k
        if spec[2] == "bool" then
            pcall(function() setXMLBool(xmlId, key, self[k] and true or false) end)
        else
            pcall(function() setXMLFloat(xmlId, key, self[k] or spec[1]) end)
        end
    end
    pcall(function() saveXMLFile(xmlId) end)
    pcall(function() delete(xmlId) end)
end

---------------------------------------------------------------------------
-- In-game settings UI (vanilla General Settings page) via UIHelper.lua.
-- Owner table holds the control objects; the actual values live on
-- NaviHelperSettings and, on change, are pushed onto the live NaviHelper
-- table (which the drawing reads) and persisted to XML.
-- Each control needs l10n keys "nh_<name>_short" and "nh_<name>_long".
---------------------------------------------------------------------------
NaviHelperSettingsUI = { controls = {} }

NaviHelperSettings.controlProperties = {
    { name = "drawRouteOnGround",  autoBind = true },
    { name = "routeLineThickness", min = 0.2,  max = 1.5, step = 0.1,  autoBind = true },
    { name = "routeLineColorA",    min = 0.05, max = 1.0, step = 0.05, autoBind = true },
}

-- Copy the managed settings onto the live NaviHelper table the drawing reads.
function NaviHelperSettings:applyToLive()
    if NaviHelper == nil then return end
    for _, k in ipairs(self:keys()) do
        if self[k] ~= nil then NaviHelper[k] = self[k] end
    end
end

-- Idempotent; safe to retry from update() until the in-game menu is ready.
function NaviHelperSettings:injectMenu()
    if self._menuInjected then return true end
    if UIHelper == nil then return false end
    local inGameMenu = g_gui and g_gui.screenControllers and g_gui.screenControllers[InGameMenu]
    if not inGameMenu then return false end
    local settingsPage = inGameMenu.pageSettings
    if not settingsPage or not settingsPage.generalSettingsLayout then return false end

    self:applyDefaults()
    UIHelper.createControlsDynamically(
        settingsPage,
        "nh_section_title",       -- i18n key for the section header
        NaviHelperSettingsUI,     -- owning table (control objects)
        self.controlProperties,
        "nh_"                     -- l10n key prefix
    )
    UIHelper.setupAutoBindControls(NaviHelperSettingsUI, self, function(_, _control)
        NaviHelperSettings:applyToLive()
        NaviHelperSettings:saveToXML()
    end)

    self._menuInjected = true
    return true
end
