--[[
  ControlsSearch.lua
  Search overlay in Settings: F toggles overlay, filter actions by text (Phase 3).
  Spike dump (Phase 2) runs when F pressed and overlay was closed; overlay only when in menu.
]]

ControlsSearch = {}

local KEY_F = 102
local KEY_ESCAPE = 27
local KEY_BACKSPACE = 8

local overlayOpen = false
local searchText = ""
local lastSpikeLogTime = 0
local SPIKELOG_INTERVAL_MS = 2000

local function logInfo(fmt, ...)
    if Logging and Logging.info then
        Logging.info("[ControlsSearch] " .. fmt, ...)
    end
end

local function isInMenu(mission)
    return mission and mission.hud and mission.hud.isMenuVisible
end

-- Build set of action names that share a key with another action. Uses g_inputBinding.actionEvents if present.
local function buildConflictSet()
    local conflictSet = {}
    local ib = g_inputBinding
    if not ib or type(ib.nameActions) ~= "table" then return conflictSet end
    local idToName = {}
    for name, id in pairs(ib.nameActions) do idToName[id] = name end
    local actionEvents = ib.actionEvents
    if type(actionEvents) ~= "table" then return conflictSet end
    local keyToNames = {}
    for _, ev in pairs(actionEvents) do
        if type(ev) == "table" and ev.actionId and idToName[ev.actionId] then
            local key = tostring(ev.keyId or ev.input or ev.deviceId or ev.key or "")
            if key ~= "" then
                keyToNames[key] = keyToNames[key] or {}
                local name = idToName[ev.actionId]
                if not keyToNames[key][name] then
                    keyToNames[key][name] = true
                end
            end
        end
    end
    for _, names in pairs(keyToNames) do
        local count = 0
        for _ in pairs(names) do count = count + 1 end
        if count > 1 then
            for name in pairs(names) do conflictSet[name] = true end
        end
    end
    return conflictSet
end

-- Build flat list of actions: { actionName, displayName, hasConflict }. Uses g_inputBinding.nameActions and g_i18n.
local function buildActionList()
    local list = {}
    if not g_inputBinding or type(g_inputBinding.nameActions) ~= "table" then return list end
    local conflictSet = buildConflictSet()
    for actionName, _ in pairs(g_inputBinding.nameActions) do
        local display = actionName
        if g_i18n and g_i18n.getText then
            local t = g_i18n:getText("input_" .. actionName)
            if t and t ~= "" then display = t end
        end
        list[#list + 1] = {
            actionName = actionName,
            displayName = display,
            hasConflict = conflictSet[actionName] or false,
        }
    end
    table.sort(list, function(a, b) return (a.displayName or a.actionName) < (b.displayName or b.actionName) end)
    return list
end

-- Filter list by search string (case-insensitive match on displayName and actionName).
local function filterActions(list, query)
    if not query or query == "" then return list end
    local q = query:lower()
    local out = {}
    for _, row in ipairs(list) do
        local d = (row.displayName or ""):lower()
        local a = (row.actionName or ""):lower()
        if d:find(q, 1, true) or a:find(q, 1, true) then
            out[#out + 1] = row
        end
    end
    return out
end

local function tr(key, fallback)
    if g_i18n and g_i18n.getText then
        local t = g_i18n:getText(key)
        if t and t ~= "" then return t end
    end
    return fallback or key
end

-- Spike: dump g_gui and g_inputBinding to log for API discovery.
local function spikeDumpToLog()
    local t = os.clock() * 1000
    if t - lastSpikeLogTime < SPIKELOG_INTERVAL_MS then return end
    lastSpikeLogTime = t
    logInfo("=== Spike dump (F pressed) ===")
    if g_gui and type(g_gui) == "table" then
        for k, v in pairs(g_gui) do
            if k == "currentGui" or k == "currentGuiName" or k:find("Screen") or k:find("Gui") then
                logInfo("  g_gui.%s = %s (%s)", tostring(k), tostring(v), type(v))
            end
        end
    end
    if g_inputBinding and type(g_inputBinding) == "table" then
        for k, v in pairs(g_inputBinding) do
            if type(v) == "table" then
                local n = 0
                for _ in pairs(v) do n = n + 1 end
                logInfo("  g_inputBinding.%s = table (%d)", tostring(k), n)
            else
                logInfo("  g_inputBinding.%s = %s", tostring(k), tostring(v))
            end
        end
    end
    logInfo("=== End spike dump ===")
end

function ControlsSearch.keyEvent(self, unicode, sym, modifier, isDown)
    if not isDown then return end

    local mission = self.mission or g_currentMission

    if overlayOpen then
        if sym == KEY_F or sym == KEY_ESCAPE then
            overlayOpen = false
            return
        end
        if sym == KEY_BACKSPACE then
            searchText = searchText:sub(1, -2)
            return
        end
        if unicode and unicode >= 32 and unicode <= 126 then
            searchText = searchText .. string.char(unicode)
            return
        end
        return
    end

    if sym == KEY_F and isInMenu(mission) then
        overlayOpen = true
        spikeDumpToLog()
        return
    end
end

function ControlsSearch.update(self, dt)
end

function ControlsSearch.draw(self)
    if not overlayOpen then return end

    local mission = self.mission or g_currentMission
    if not isInMenu(mission) then
        overlayOpen = false
        return
    end

    pcall(function()
        local list = buildActionList()
        local filtered = filterActions(list, searchText)

        local x = 0.02
        local y = 0.92
        local fontSize = 0.018
        local lineH = fontSize * 1.4

        if setTextColor then setTextColor(1, 0.95, 0.3, 1) end
        if renderText then renderText(x, y, fontSize * 1.2, tr("CONTROLSSEARCH_TITLE", "Controls Search (F to close)")) end
        y = y - lineH * 1.2

        if setTextColor then setTextColor(0.85, 0.85, 0.85, 1) end
        local searchLabel = tr("CONTROLSSEARCH_SEARCH", "Search:") .. " " .. (searchText == "" and tr("CONTROLSSEARCH_ALL", "(all)") or searchText)
        if renderText then renderText(x, y, fontSize, searchLabel) end
        y = y - lineH

        if setTextColor then setTextColor(0.7, 0.7, 0.7, 1) end
        if renderText then renderText(x, y, fontSize, string.format("%d / %d", #filtered, #list)) end
        y = y - lineH

        if #filtered == 0 and searchText ~= "" then
            if setTextColor then setTextColor(0.8, 0.6, 0.4, 1) end
            if renderText then renderText(x, y, fontSize, tr("CONTROLSSEARCH_NO_MATCHES", "No matches")) end
            y = y - lineH
        end

        local maxLines = 35
        for i = 1, math.min(#filtered, maxLines) do
            local row = filtered[i]
            if row.hasConflict and setTextColor then setTextColor(1, 0.4, 0.3, 1) end
            local text = (row.displayName or row.actionName) .. "  [" .. (row.actionName or "") .. "]"
            if row.hasConflict then text = text .. "  [" .. tr("CONTROLSSEARCH_CONFLICT", "Conflict") .. "]" end
            if renderText then renderText(x, y, fontSize * 0.95, text) end
            if row.hasConflict and setTextColor then setTextColor(0.7, 0.7, 0.7, 1) end
            y = y - lineH
        end
        if #filtered > maxLines then
            if setTextColor then setTextColor(0.6, 0.6, 0.6, 1) end
            if renderText then renderText(x, y, fontSize * 0.9, "... " .. (#filtered - maxLines) .. " more") end
        end
    end)
end
