--[[
  CruiseControlPlusHook.lua
  Wraps the game's TOGGLE_CRUISE_CONTROL handler so we run first: double-tap -> set speed
  and suppress original; single tap -> call original. Pattern like VehicleCameraExtension.
]]

CruiseControlPlusHook = {}
CruiseControlPlusHook.overwrittenFunctions = {}
CruiseControlPlusHook.installed = false

local LOG = "[CruiseControlPlus][Hook] "

-- Diagnostic path: profile first so install and runtime (setCruiseTarget) write to same file; mod dir can be symlink (learned.md).
local function getDiagnosePath()
    local profile = getUserProfileAppPath and getUserProfileAppPath()
    if profile and type(profile) == "string" then
        if profile:sub(-1) ~= "/" and profile:sub(-1) ~= "\\" then profile = profile .. "/" end
        return profile .. "FS25_CruiseControlPlus_diagnose.txt"
    end
    if g_currentModDirectory then
        return Utils.getFilename("CruiseControlPlus_diagnose.txt", g_currentModDirectory)
    end
    return nil
end

local function writeDiagnose(blockName, lines)
    local path = getDiagnosePath()
    if not path then return end
    pcall(function()
        local f = io.open(path, "a")
        if f then
            f:write("\n=== " .. tostring(blockName) .. " ===\n")
            for _, line in ipairs(lines) do f:write(tostring(line) .. "\n") end
            f:close()
        end
    end)
end

local function logInfo(fmt, ...)
    if Logging and Logging.info then
        Logging.info(LOG .. fmt, ...)
    end
end

-- Our own globals: must not wrap these (they contain "Cruise" and "Toggle" in method names).
local EXCLUDE_NAMES = {
    ["CruiseControlPlus"] = true,
    ["CruiseControlPlusHook"] = true,
    ["CruiseControlPlusVehicle"] = true,
    ["CruiseControlPlusRegister"] = true,
    ["CruiseControlPlusSettings"] = true,
}

--- Find a class and method that likely handle TOGGLE_CRUISE_CONTROL (e.g. Drivable.actionEventToggleCruiseControl).
--- Returns classNameOrSpec, methodName, oldFunc, diagnoseLines (table of strings for one-shot file).
local function findCruiseControlHandler()
    local diagnoseLines = {}
    -- 1) Try known names first (FS22/FS25 pattern)
    local candidates = {
        { "Drivable", "actionEventToggleCruiseControl" },
        { "Drivable", "actionEventCruiseControlToggle" },
    }
    local installLines = {}
    for _, c in ipairs(candidates) do
        local cls = _G[c[1]]
        if c[1] == "Drivable" then
            diagnoseLines[#diagnoseLines + 1] = string.format("_G.Drivable: inG=%s type=%s hasMethod=%s", cls ~= nil, type(cls), type(cls) == "table" and type(cls[c[2]]) == "function")
        end
        if type(cls) == "table" and type(cls[c[2]]) == "function" then
            return c[1], c[2], cls[c[2]], diagnoseLines
        end
    end
    -- 1b) _G.Drivable exists but method name differs: discover methods containing "cruise", prefer action-event (toggle)
    local drivable = _G.Drivable
    if type(drivable) == "table" then
        local cruiseMethods = {}
        for k, v in pairs(drivable) do
            if type(k) == "string" and type(v) == "function" and string.lower(k):find("cruise") then
                cruiseMethods[#cruiseMethods + 1] = k
            end
        end
        for _, m in ipairs(cruiseMethods) do
            diagnoseLines[#diagnoseLines + 1] = "Drivable cruise method: " .. m
        end
        -- Prefer action-event for TOGGLE (KEY_3). Not officially documented; by naming convention
        -- (State=on/off, Value=speed). Verify: if KEY_3 triggers WRAPPER CALLED in diagnose file, we hooked the right one.
        local preferOrder = { "actionEventCruiseControlState", "actionEventToggleCruiseControl", "actionEventCruiseControlValue" }
        for _, methodName in ipairs(preferOrder) do
            if type(drivable[methodName]) == "function" then
                return "Drivable", methodName, drivable[methodName], diagnoseLines
            end
        end
        for _, methodName in ipairs(cruiseMethods) do
            if type(drivable[methodName]) == "function" then
                return "Drivable", methodName, drivable[methodName], diagnoseLines
            end
        end
    end
    -- 2) Try Drivable spec from specialization manager (FS25 may not put Drivable in _G)
    if g_specializationManager then
        local drivableSpec = g_specializationManager:getSpecializationByName("Drivable")
        if type(drivableSpec) == "table" then
            do
                local names = {}
                for k, v in pairs(drivableSpec) do
                    if type(k) == "string" and type(v) == "function" then
                        local lower = string.lower(k)
                        if lower:find("cruise") or lower:find("action") then
                            names[#names + 1] = k
                        end
                    end
                end
                diagnoseLines[#diagnoseLines + 1] = string.format("DrivableSpec methods(cruise/action): count=%d list=%s", #names, (#names > 0) and table.concat(names, ",") or "none")
            end
            for _, methodName in ipairs({ "actionEventToggleCruiseControl", "actionEventCruiseControlToggle" }) do
                if type(drivableSpec[methodName]) == "function" then
                    return drivableSpec, methodName, drivableSpec[methodName], diagnoseLines
                end
            end
        else
            diagnoseLines[#diagnoseLines + 1] = string.format("DrivableSpec from manager: hasSpec=false specType=%s", type(drivableSpec))
        end
    end
    -- 3) Scan _G for any class with cruise+toggle method, excluding our mod
    for name, obj in pairs(_G) do
        if type(name) == "string" and not EXCLUDE_NAMES[name] and type(obj) == "table" then
            for methodName, fn in pairs(obj) do
                if type(methodName) == "string" and type(fn) == "function" then
                    local lower = string.lower(methodName)
                    if (lower:find("cruise") and lower:find("toggle")) or (lower:find("toggle") and lower:find("cruise")) then
                        return name, methodName, fn, diagnoseLines
                    end
                end
            end
        end
    end
    diagnoseLines[#diagnoseLines + 1] = "findCruiseControlHandler: no handler found"
    return nil, nil, nil, diagnoseLines
end

--- Create wrapper: first arg is vehicle (self). Check context, call CruiseControlPlus; if consumed skip original.
local function makeCruiseWrapper(oldFunc, className, methodName)
    return function(vehicle, ...)
        -- #region agent log - one-shot: append when wrapper is called (KEY_3 pressed)
        do
            local mission = g_currentMission
            local same = (mission and mission.controlledVehicle == vehicle)
            writeDiagnose("WRAPPER CALLED (KEY_3)", {
                "hasVehicle=" .. tostring(vehicle ~= nil),
                "controlledSame=" .. tostring(same),
                "hasSpecDrivable=" .. tostring(vehicle and vehicle.spec_drivable ~= nil),
                "menuOpen=" .. tostring(g_inGameMenu and g_inGameMenu.isOpen),
                "getIsControlled=" .. tostring(vehicle and vehicle.getIsControlled and vehicle:getIsControlled()),
            })
        end
        -- #endregion
        if not vehicle or not CruiseControlPlus then
            return oldFunc(vehicle, ...)
        end
        if g_inGameMenu and g_inGameMenu.isOpen then
            return oldFunc(vehicle, ...)
        end
        if not vehicle.spec_drivable then
            return oldFunc(vehicle, ...)
        end
        -- Always run our logic so we see both key events (first sets lastToggleTime). Do NOT early-return on
        -- getIsControlled(): on first KEY_3 it can be false so we'd never record the tap and double-tap would never trigger.
        local consumed = CruiseControlPlus:onToggleCruiseControlKey(vehicle)
        if consumed and logInfo then logInfo("consumed=true (double-tap), see CruiseControlPlus log for kmh") end
        local td = CruiseControlPlus.lastToggleDiagnose
        writeDiagnose("AFTER onToggleCruiseControlKey", {
            "consumed=" .. tostring(consumed),
            td and ("isDoubleTap=" .. tostring(td.isDoubleTap) .. " t=" .. tostring(td.t) .. " last=" .. tostring(td.last) .. " windowMs=" .. tostring(td.windowMs)) or "no timing"
        })
        if consumed then
            -- Write setCruiseTarget diagnose from Hook (CruiseControlPlus io may not work in this context).
            local diag = CruiseControlPlus.lastSetCruiseDiagnose
            if diag and diag.blocks then
                for _, b in ipairs(diag.blocks) do
                    if b.blockName and b.lines then writeDiagnose(b.blockName, b.lines) end
                end
            end
            return -- do not call original (double-tap: we set speed)
        end
        return oldFunc(vehicle, ...)
    end
end

--- Install overwrites. Returns true if at least one overwrite was applied.
function CruiseControlPlusHook:install()
    if self.installed then
        return true
    end

    local classNameOrSpec, methodName, oldFunc, diagnoseLines = findCruiseControlHandler()
    -- One-shot diagnostic file (learned.md, ONE_SHOT_DEBUG_STRATEGY): mod directory = project when symlinked
    if diagnoseLines and #diagnoseLines > 0 then
        pcall(function()
            local path = getDiagnosePath()
            if path then
                local f = io.open(path, "w")
                if f then
                    f:write("=== CruiseControlPlus INSTALL (findCruiseControlHandler) ===\n")
                    for _, line in ipairs(diagnoseLines) do f:write(line .. "\n") end
                    f:write("found=" .. tostring(methodName ~= nil and oldFunc ~= nil) .. " methodName=" .. tostring(methodName) .. "\n")
                    f:close()
                end
            end
        end)
    end
    if not methodName or not oldFunc then
        logInfo("install: could not find cruise control handler (Drivable.actionEventToggleCruiseControl or similar)")
        return false
    end

    -- classNameOrSpec is either a string (global name) or the spec table (from g_specializationManager)
    local cls = (type(classNameOrSpec) == "table") and classNameOrSpec or _G[classNameOrSpec]
    if not cls then
        logInfo("install: class/spec not found")
        return false
    end

    local wrapper = makeCruiseWrapper(oldFunc, "Drivable", methodName)
    cls[methodName] = wrapper
    table.insert(self.overwrittenFunctions, { object = cls, funcName = methodName, oldFunc = oldFunc })
    self.installed = true
    local tag = (type(classNameOrSpec) == "table") and "Drivable(spec)" or tostring(classNameOrSpec)
    logInfo("install: wrapped %s.%s", tag, methodName)
    return true
end

--- Restore original functions.
function CruiseControlPlusHook:uninstall()
    for i = #self.overwrittenFunctions, 1, -1 do
        local info = self.overwrittenFunctions[i]
        if info.object and info.funcName and info.oldFunc then
            info.object[info.funcName] = info.oldFunc
        end
        self.overwrittenFunctions[i] = nil
    end
    self.installed = false
    logInfo("uninstall done")
end
