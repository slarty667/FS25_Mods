--[[
  Settings.lua
  Configurable parameters for FS25_CruiseControlPlus.
  Settings are persisted to XML in the modSettings folder.
]]

CruiseControlPlusSettings = {}

---------------------------------------------------------------------------
-- Defaults
---------------------------------------------------------------------------
local DEFAULTS = {
    doubleTapWindowMs   = 300,
    roundingStepKmh     = 1,
    minKmh              = 1,
    maxKmh              = 0,   -- 0 = use vehicle max
    showHudNotification  = 1,   -- 1 = on, 0 = off
}

---------------------------------------------------------------------------
-- Apply defaults
---------------------------------------------------------------------------
local function applyDefaults()
    for k, v in pairs(DEFAULTS) do
        if CruiseControlPlusSettings[k] == nil then
            CruiseControlPlusSettings[k] = v
        end
    end
end

applyDefaults()

---------------------------------------------------------------------------
-- XML persistence
---------------------------------------------------------------------------
local XML_TAG = "CruiseControlPlusSettings"

function CruiseControlPlusSettings:getSettingsPath()
    local path = getUserProfileAppPath()
    if path then
        return path .. "modSettings/FS25_CruiseControlPlus.xml"
    end
    return nil
end

function CruiseControlPlusSettings:loadFromXML()
    local path = self:getSettingsPath()
    if not path then return end

    local ok, xmlId = pcall(function()
        return loadXMLFile("CruiseControlPlusSettings", path)
    end)
    if not ok or not xmlId or xmlId == 0 then return end

    for k, def in pairs(DEFAULTS) do
        local xmlKey = XML_TAG .. "." .. k
        local ok2, val = pcall(function()
            return getXMLFloat(xmlId, xmlKey)
        end)
        if ok2 and val ~= nil then
            self[k] = val
        end
    end

    pcall(function() delete(xmlId) end)

    if Logging and Logging.info then
        Logging.info("[CruiseControlPlus] Settings loaded from %s", path)
    end
end

function CruiseControlPlusSettings:saveToXML()
    local path = self:getSettingsPath()
    if not path then return end

    local ok, xmlId = pcall(function()
        return createXMLFile("CruiseControlPlusSettings", path, XML_TAG)
    end)
    if not ok or not xmlId or xmlId == 0 then return end

    for k, _ in pairs(DEFAULTS) do
        local xmlKey = XML_TAG .. "." .. k
        pcall(function()
            setXMLFloat(xmlId, xmlKey, self[k] or DEFAULTS[k])
        end)
    end

    pcall(function() saveXMLFile(xmlId) end)
    pcall(function() delete(xmlId) end)

    if Logging and Logging.info then
        Logging.info("[CruiseControlPlus] Settings saved to %s", path)
    end
end
