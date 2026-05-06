--[[
  VehicleCameraExtension.lua
  Overwrites VehicleCamera.actionEventLookLeftRight AND actionEventLookUpDown
  so that mouse-look input is suppressed (not rotating the camera/mirror) when
  the mod is actively steering with LMB alone.

  Why both axes:
    Steering with LMB held: the user's hand naturally arcs (pivot at the wrist),
    so cursor X-movement is accompanied by a small Y component. Without
    suppressing actionEventLookUpDown, the camera tilts up/down during long
    sustained turns — distracting and not what real-wheel driving feels like.
    Suppressing both gives the steady horizon a real steering wheel offers.

  When LMB+RMB is held (free-look mode), suppression is OFF on both axes so
  the player can look around with the mouse while still steering.

  VehicleCamera.update is also appended (once) so MouseSteering can apply a
  smoothed extra rotY from steering after vanilla camera logic (look into the corner).
]]

VehicleCameraExtension = {}
VehicleCameraExtension.overwrittenFunctions = {}
VehicleCameraExtension._utilsHookKeys = VehicleCameraExtension._utilsHookKeys or {}
VehicleCameraExtension._lateGlobalHooksDone = VehicleCameraExtension._lateGlobalHooksDone or false
VehicleCameraExtension._lateGlobalAttempts = VehicleCameraExtension._lateGlobalAttempts or 0
VehicleCameraExtension._lateGlobalAccMs = VehicleCameraExtension._lateGlobalAccMs or 0
VehicleCameraExtension.installed = false
VehicleCameraExtension._cameraUpdateHooked = false
VehicleCameraExtension._origVehicleCameraUpdate = nil

local LOG = "[MouseSteering][VCE] "

local function logInfo(fmt, ...)
  if Logging and Logging.info then
    Logging.info(LOG .. fmt, ...)
  end
end

--- True when look-style actions should be swallowed (camera uses isMouse; implements may use AXIS_LOOK* without _VEHICLE and isMouse false).
local function shouldSuppressSteeringMouseLook(controllerObj, isMouse, actionName)
  if not controllerObj then return false end
  local armed = MouseSteering and MouseSteering.armed
  local active = MouseSteering and MouseSteering.active
  local otherDown = MouseSteering and MouseSteering._otherMouseButtonDown
  if not (armed and active and not otherDown) then return false end
  local veh = controllerObj.vehicle or controllerObj.rootVehicle or controllerObj
  if MouseSteering and MouseSteering.isFrontloaderSelectionSuppressingMouse and veh then
    local ok, sup = pcall(function() return MouseSteering:isFrontloaderSelectionSuppressingMouse(veh) end)
    if ok and sup then return false end
  end

  local an = type(actionName) == "string" and actionName or ""
  local aNu = an:upper()
  -- FS25: fork / implement hydraulics often bind as AXIS_LOOK_* without isMouse; cabin vehicle look uses *VEHICLE* in the action id.
  if aNu:find("AXIS_LOOK", 1, true) and not aNu:find("VEHICLE", 1, true) then
    if not (aNu:find("PLAYER", 1, true) or aNu:find("CHARACTER", 1, true)) then
      return true
    end
  end

  if not isMouse then return false end
  return true
end

--- Wrap actionEventLook* (VehicleCamera, Vehicle, loader-related specs): same mouse
--- often drives both cabin look and FL tool motion; suppress for LMB-only steering.
local function makeLookWrapper(oldFunc, _tag)
  return function(controllerObj, actionName, inputValue, callbackState, isAnalog, isMouse)
    if shouldSuppressSteeringMouseLook(controllerObj, isMouse, actionName) then
      return
    end
    return oldFunc(controllerObj, actionName, inputValue, callbackState, isAnalog, isMouse)
  end
end

local LOOK_FUNCS = {
  "actionEventLookLeftRight",
  "actionEventLookUpDown",
  "actionEventCameraLookLeftRight",
  "actionEventCameraLookUpDown",
}

local function resolveClassMethod(obj, funcName)
  if type(funcName) ~= "string" then return nil end
  local ot = type(obj)
  if ot ~= "table" and ot ~= "userdata" then return nil end
  local r = ot == "table" and rawget(obj, funcName) or nil
  if type(r) == "function" then return r end
  local ok, v = pcall(function()
    return obj[funcName]
  end)
  if ok and type(v) == "function" then return v end

  local mt = getmetatable(obj)
  if not mt then return nil end
  if type(mt.__index) == "table" then
    local w = mt.__index[funcName]
    if type(w) == "function" then return w end
    local ok2, w2 = pcall(function()
      return mt.__index[funcName]
    end)
    if ok2 and type(w2) == "function" then return w2 end
  elseif type(mt.__index) == "function" then
    local ok3, w3 = pcall(mt.__index, obj, funcName)
    if ok3 and type(w3) == "function" then return w3 end
  end
  return nil
end

--- Discover action handlers Giants may name differently than LOOK_FUNCS (pairs-visible keys only).
local function findAlternateLookActionKeys(obj)
  local out = {}
  pcall(function()
    for k, v in pairs(obj) do
      if type(k) == "string" and type(v) == "function" then
        local kl = k:lower()
        if kl:find("actionevent", 1, true) and kl:find("look", 1, true) then
          table.insert(out, k)
        end
      end
    end
  end)
  return out
end

--- Loader-relevant actionEvent method names discoverable via pairs(specTbl) only (userdata specs skipped).
local function shouldProbeSpecActionEventKey(k)
  if type(k) ~= "string" then return false end
  local kl = k:lower()
  if not kl:find("actionevent", 1, true) then return false end
  if kl:find("tooltip", 1, true) then return false end
  if kl:find("lower", 1, true) and kl:find("implement", 1, true) then return false end
  if kl == "actioneventmouse" or kl == "actioneventtogglemouse" then return false end
  if kl:find("mouse", 1, true) then
    return kl:find("look", 1, true) or kl:find("axis", 1, true) or kl:find("hydraulic", 1, true)
  end
  if kl:find("hydraulic", 1, true) then return true end
  if kl:find("cylinder", 1, true) then return true end
  if kl:find("movingtool", 1, true) then return true end
  if kl:find("implement", 1, true) then
    return kl:find("look", 1, true) or kl:find("axis", 1, true) or kl:find("hydraulic", 1, true)
  end
  if kl:find("attachable", 1, true) and kl:find("axis", 1, true) then return true end
  if kl:find("frontloader", 1, true) or kl:find("front_loader", 1, true) then return true end
  if kl:find("fork", 1, true) and kl:find("axis", 1, true) then return true end
  if kl:find("axis", 1, true) and kl:find("look", 1, true) then return true end
  return false
end

--- Exclude obvious non-gameplay globals from broad look-handler scan.
local function shouldExcludeBroadGlobalName(name)
  if type(name) ~= "string" then return true end
  local n = name:lower()
  if n == "vehiclecameraextension" then return true end
  if n:find("mousesteering", 1, true) then return true end
  if n:sub(1, 2) == "g_" then return true end
  if n:find("xml", 1, true) or n:find("schema", 1, true) then return true end
  if n:find("i18n", 1, true) or n:find("l10n", 1, true) then return true end
  if n:find("ingamemenu", 1, true) or n:find("mainmenu", 1, true) then return true end
  if n:find("tutorial", 1, true) or n:find("achievement", 1, true) then return true end
  return false
end

--- Wrap one look handler if not already wrapped (shared across install + deferred scans).
---@return boolean wrapped
function VehicleCameraExtension:wrapLookIfNeeded(obj, name, funcName)
  if type(obj) ~= "table" then return false end
  local old = resolveClassMethod(obj, funcName)
  if not old then return false end
  VehicleCameraExtension._wrappedMethodKeys = VehicleCameraExtension._wrappedMethodKeys or {}
  local key = tostring(obj) .. "\0" .. funcName
  if VehicleCameraExtension._wrappedMethodKeys[key] then return false end
  local wrappedFn = makeLookWrapper(old, name)
  local okSet = pcall(function()
    obj[funcName] = wrappedFn
  end)
  if not okSet then return false end
  VehicleCameraExtension._wrappedMethodKeys[key] = true
  table.insert(self.overwrittenFunctions, { object = obj, funcName = funcName, oldFunc = old })
  logInfo("also overwrote %s.%s", name, funcName)
  return true
end

--- Hook specialization class methods (runs from TypeManager.validateTypes).
--- FS may expose specs as table or userdata; methods may live behind __index — use resolveClassMethod.
--- Plain wrapper assignment matches CruiseControlPlusHook / VehicleCamera look wraps (not Utils.overwrittenFunction).
---@return integer nHooks
function VehicleCameraExtension:hookSpecLookActionsUtils(specTbl, regLabel)
  local st = type(specTbl)
  if st ~= "table" and st ~= "userdata" then return 0 end
  VehicleCameraExtension._utilsHookKeys = VehicleCameraExtension._utilsHookKeys or {}
  local label = tostring(regLabel or "?")
  local nHooks = 0
  local trySeen = {}
  local tryFns = {}
  local function addTryFn(fn)
    if type(fn) ~= "string" or trySeen[fn] then return end
    trySeen[fn] = true
    table.insert(tryFns, fn)
  end
  for _, fn in ipairs(LOOK_FUNCS) do
    addTryFn(fn)
  end
  if st == "table" then
    for _, ak in ipairs(findAlternateLookActionKeys(specTbl)) do
      addTryFn(ak)
    end
    local extraCap = 0
    pcall(function()
      for k, v in pairs(specTbl) do
        if extraCap >= 80 then return end
        if type(k) == "string" and type(v) == "function" and shouldProbeSpecActionEventKey(k) then
          addTryFn(k)
          extraCap = extraCap + 1
        end
      end
    end)
  end
  for _, fn in ipairs(tryFns) do
    local oldFn = resolveClassMethod(specTbl, fn)
    if type(oldFn) == "function" then
      local key = tostring(specTbl) .. "\0" .. fn
      if not VehicleCameraExtension._utilsHookKeys[key] then
        VehicleCameraExtension._utilsHookKeys[key] = true
        local wrappedFn = makeLookWrapper(oldFn, label .. "." .. fn)
        local okSet = pcall(function()
          specTbl[fn] = wrappedFn
        end)
        if okSet then
          table.insert(self.overwrittenFunctions, { object = specTbl, funcName = fn, oldFunc = oldFn })
          nHooks = nHooks + 1
          logInfo("spec look wrap %s.%s", label, fn)
        else
          VehicleCameraExtension._utilsHookKeys[key] = nil
          logInfo("spec look wrap FAILED assign %s.%s (specType=%s)", label, fn, st)
        end
      end
    end
  end
  return nHooks
end

--- Called from MouseSteeringValidateVehicleTypesPost (after vanilla validateTypes).
--- FS25: getSpecializationByName is nil during prepended validate hook — scan typeDef.specializations for class refs.
---@return integer totalHooks
function VehicleCameraExtension:applySpecializationLookHooksAtValidateTypes()
  local sm = g_specializationManager
  local smOk = type(sm) == "table" and type(sm.getSpecializationByName) == "function"

  local regNames = {}
  local function addReg(nm)
    if type(nm) ~= "string" or nm == "" then return end
    regNames[nm] = true
    local dotPos = nm:find(".", 1, true)
    if dotPos then
      local suffix = nm:sub(dotPos + 1)
      if suffix ~= "" then regNames[suffix] = true end
    end
  end

  for _, nm in ipairs({
    "Cylindered",
    "Attachable",
    "AttachableFrontloader",
    "Foldable",
    "Shovel",
    "BaleGrab",
    "MovingTool",
    "MovingTools",
    "GroundAdjustedNodes",
    "Pickup",
    "PickUp",
    "Vehicle",
  }) do
    addReg(nm)
  end

  local vtm = g_vehicleTypeManager
  if type(vtm) == "table" and type(vtm.types) == "table" then
    for _, tdef in pairs(vtm.types) do
      if type(tdef) == "table" and type(tdef.specializationsByName) == "table" then
        for regName in pairs(tdef.specializationsByName) do
          addReg(regName)
        end
      end
    end
  end

  local total = 0
  local seenSpecRef = {}

  -- Primary: specialization class references on each vehicle type (same refs SpecializationUtil.hasSpecialization uses).
  if type(vtm) == "table" and type(vtm.types) == "table" then
    for _, tdef in pairs(vtm.types) do
      if type(tdef) == "table" and type(tdef.specializations) == "table" then
        for _, specRef in pairs(tdef.specializations) do
          local st = type(specRef)
          if st == "table" or st == "userdata" then
            local key = tostring(specRef)
            if not seenSpecRef[key] then
              seenSpecRef[key] = true
              total = total + self:hookSpecLookActionsUtils(specRef, "typeSpec")
            end
          end
        end
      end
    end
  end

  -- Secondary: name resolution via specialization manager (may duplicate typeSpec path; hookSpec dedupes).
  if smOk then
    local nSeen = 0
    for regName in pairs(regNames) do
      nSeen = nSeen + 1
      if nSeen > 950 then break end
      local specTbl = nil
      pcall(function()
        specTbl = sm:getSpecializationByName(regName)
      end)
      if type(specTbl) ~= "table" and type(specTbl) ~= "userdata" and type(sm.getSpecializationObjectByName) == "function" then
        pcall(function()
          specTbl = sm:getSpecializationObjectByName(regName)
        end)
      end
      if type(specTbl) == "table" or type(specTbl) == "userdata" then
        total = total + self:hookSpecLookActionsUtils(specTbl, regName)
      end
    end
  end

  return total
end

--- Retry hooking specialization globals until _G is populated (userdata/table specs invisible at validate time).
function VehicleCameraExtension:tickLateGlobalSpecHooks(dt)
  if self._lateGlobalHooksDone then return end
  self._lateGlobalAccMs = (self._lateGlobalAccMs or 0) + (dt or 16)
  if self._lateGlobalAccMs < 400 then return end
  self._lateGlobalAccMs = 0
  self._lateGlobalAttempts = (self._lateGlobalAttempts or 0) + 1
  if self._lateGlobalAttempts > 180 then
    self._lateGlobalHooksDone = true
    return
  end

  local added = 0
  pcall(function()
    for _, gn in ipairs({
      "Cylindered",
      "Attachable",
      "AttachableFrontloader",
      "MovingTool",
      "MovingTools",
      "Vehicle",
      "Enterable",
      "Foldable",
      "Shovel",
      "BaleGrab",
    }) do
      local o = rawget(_G, gn)
      local ot = type(o)
      if ot == "table" or ot == "userdata" then
        added = added + self:hookSpecLookActionsUtils(o, "lateG:" .. gn)
      end
    end
  end)

  if added > 0 then
    self._lateGlobalHooksDone = true
    logInfo("late global spec look hooks +%d", added)
  end
end

--- One-shot broad scan: handlers may sit on unexpected _G keys until late load.
function VehicleCameraExtension:deferredLoaderLookWrapScan()
  if self._loaderLookDeferredDone or not self.installed then return end
  if self._deferredBroadOneShotDone then return end

  self._deferredLoaderFrames = (self._deferredLoaderFrames or 0) + 1
  if self._deferredLoaderFrames < 60 then return end

  self._deferredBroadOneShotDone = true
  self._loaderLookDeferredDone = true

  local extraMethodWraps = 0
  local deferGlobalHooks = 0

  -- Late session: vanilla exposes specialization globals (often userdata); hookSpec supports assignment where wrapLookIfNeeded cannot.
  pcall(function()
    for _, gn in ipairs({
      "Vehicle",
      "Cylindered",
      "Attachable",
      "AttachableFrontloader",
      "MovingTool",
      "MovingTools",
      "Enterable",
      "Shovel",
      "BaleGrab",
      "Foldable",
    }) do
      local o = rawget(_G, gn)
      local ot = type(o)
      if ot == "table" or ot == "userdata" then
        deferGlobalHooks = deferGlobalHooks + self:hookSpecLookActionsUtils(o, "deferGlobal:" .. gn)
      end
    end
  end)

  pcall(function()
    for name, obj in pairs(_G) do
      if type(name) == "string" and type(obj) == "table" and not shouldExcludeBroadGlobalName(name) then
        if resolveClassMethod(obj, "actionEventLookLeftRight") or resolveClassMethod(obj, "actionEventLookUpDown")
            or #findAlternateLookActionKeys(obj) > 0 then
          for _, funcName in ipairs(LOOK_FUNCS) do
            if self:wrapLookIfNeeded(obj, name, funcName) then
              extraMethodWraps = extraMethodWraps + 1
            end
          end
          for _, ak in ipairs(findAlternateLookActionKeys(obj)) do
            if self:wrapLookIfNeeded(obj, name .. ":" .. ak, ak) then
              extraMethodWraps = extraMethodWraps + 1
            end
          end
        end
      end
    end
  end)

  -- Extra spec hooks from deferred globals (userdata specs); validateTypes path covers typeDef.specializations.

  pcall(function()
    for _, gn in ipairs({
      "Vehicle",
      "Attachable",
      "Cylindered",
      "AttachableFrontloader",
      "Enterable",
      "Foldable",
      "Shovel",
      "BaleGrab",
    }) do
      local obj = rawget(_G, gn)
      if type(obj) == "table" then
        for _, funcName in ipairs(LOOK_FUNCS) do
          if self:wrapLookIfNeeded(obj, gn, funcName) then
            extraMethodWraps = extraMethodWraps + 1
          end
        end
        for _, ak in ipairs(findAlternateLookActionKeys(obj)) do
          if self:wrapLookIfNeeded(obj, gn .. "*" .. ak, ak) then
            extraMethodWraps = extraMethodWraps + 1
          end
        end
      end
    end
  end)

end

--- Install overwrites. Returns true if at least one overwrite was applied.
function VehicleCameraExtension:install()
  if self.installed then
    return true
  end

  local count = 0

  -- 1) VehicleCamera (the main class for all vehicle cameras): wrap both axes.
  if VehicleCamera then
    for _, funcName in ipairs(LOOK_FUNCS) do
      if self:wrapLookIfNeeded(VehicleCamera, "VehicleCamera", funcName) then
        count = count + 1
      end
    end
  end

  -- 2) Other Camera/Reflector/Mirror classes with these methods.
  for name, obj in pairs(_G) do
    if type(name) == "string" and type(obj) == "table"
        and name ~= "VehicleCamera" and name ~= "VehicleCameraExtension"
        and (name:find("Camera") or name:find("Reflector") or name:find("Mirror")) then
      for _, funcName in ipairs(LOOK_FUNCS) do
        if self:wrapLookIfNeeded(obj, name, funcName) then
          count = count + 1
        end
      end
    end
  end

  -- 3) Vehicle / attachable / FL: deferred from MouseSteering:update — _G often empty at mod register.

  if count > 0 then
    self.installed = true
  end

  -- Run after vanilla VehicleCamera:update so we can apply a yaw offset from
  -- steering (see MouseSteering:afterVehicleCameraUpdate) without fighting input.
  if not self._cameraUpdateHooked and VehicleCamera and type(VehicleCamera.update) == "function" then
    self._origVehicleCameraUpdate = VehicleCamera.update
    VehicleCamera.update = Utils.appendedFunction(VehicleCamera.update, function(cameraSelf, delta)
      if MouseSteering and MouseSteering.afterVehicleCameraUpdate then
        MouseSteering:afterVehicleCameraUpdate(cameraSelf, delta)
      end
    end)
    self._cameraUpdateHooked = true
    self.installed = true
    logInfo("hooked VehicleCamera.update (steering-linked head turn)")
  end

  logInfo("install done, overwrote %d function(s) total", count)
  return self.installed
end

--- Restore original functions.
function VehicleCameraExtension:uninstall()
  if MouseSteering and MouseSteering.clearSteeringHeadTurn then
    MouseSteering:clearSteeringHeadTurn()
  end
  if self._cameraUpdateHooked and self._origVehicleCameraUpdate and VehicleCamera then
    VehicleCamera.update = self._origVehicleCameraUpdate
    self._cameraUpdateHooked = false
    self._origVehicleCameraUpdate = nil
  end
  for i = #self.overwrittenFunctions, 1, -1 do
    local info = self.overwrittenFunctions[i]
    if info.object and info.funcName and info.oldFunc then
      info.object[info.funcName] = info.oldFunc
    end
    self.overwrittenFunctions[i] = nil
  end
  VehicleCameraExtension._wrappedMethodKeys = {}
  VehicleCameraExtension._utilsHookKeys = {}
  VehicleCameraExtension._lateGlobalHooksDone = false
  VehicleCameraExtension._lateGlobalAttempts = 0
  VehicleCameraExtension._lateGlobalAccMs = 0
  self._loaderLookDeferredDone = false
  self._deferredLoaderFrames = 0
  self._deferredBroadOneShotDone = false
  self.installed = false
end
