--[[
  VehicleCameraExtension.lua
  Overwrites VehicleCamera.actionEventLookLeftRight so that mouse-look input
  is suppressed (not rotating the camera/mirror) when the mod is actively steering.

  Note: In FS25, actionEventLookLeftRight receives inputValue=0 when LMB is held
  (the game handles mouse look internally). The primary steering input comes from
  mouseEvent posX displacement instead. This extension still suppresses the
  look-axis call to prevent mirror jitter during active steering.
]]

VehicleCameraExtension = {}
VehicleCameraExtension.overwrittenFunctions = {}
VehicleCameraExtension.installed = false

local LOG = "[MouseSteering][VCE] "

local function logInfo(fmt, ...)
  if Logging and Logging.info then
    Logging.info(LOG .. fmt, ...)
  end
end

--- Create wrapper that suppresses look axis when mod is actively steering with
--- LMB only. While an extra mouse button (e.g. RMB) is also held, we let the
--- camera rotation through — that's the "hands on the wheel, head turning"
--- use case: LMB keeps steering, RMB+LMB enables free-look during steering.
local function makeLookWrapper(oldFunc, tag)
  return function(cameraObj, actionName, inputValue, callbackState, isAnalog, isMouse)
    local armed = MouseSteering and MouseSteering.armed
    local active = MouseSteering and MouseSteering.active
    local otherDown = MouseSteering and MouseSteering._otherMouseButtonDown
    -- Only block camera while steering with LMB ALONE. With RMB+LMB, the
    -- player explicitly wants the look-axis to work.
    local shouldSuppress = isMouse and cameraObj and cameraObj.vehicle
                           and armed and active and not otherDown

    if shouldSuppress then
      return -- suppress camera/mirror rotation while purely steering
    end
    return oldFunc(cameraObj, actionName, inputValue, callbackState, isAnalog, isMouse)
  end
end

--- Install overwrites. Returns true if at least one overwrite was applied.
function VehicleCameraExtension:install()
  if self.installed then
    return true
  end

  local count = 0

  -- 1) VehicleCamera (the main class for all vehicle cameras)
  if VehicleCamera and type(VehicleCamera.actionEventLookLeftRight) == "function" then
    local old = VehicleCamera.actionEventLookLeftRight
    VehicleCamera.actionEventLookLeftRight = makeLookWrapper(old, "VehicleCamera")
    table.insert(self.overwrittenFunctions, { object = VehicleCamera, funcName = "actionEventLookLeftRight", oldFunc = old })
    count = count + 1
    logInfo("overwrote VehicleCamera.actionEventLookLeftRight")
  end

  -- 2) Scan all globals for other Camera/Reflector/Mirror classes with actionEventLookLeftRight
  for name, obj in pairs(_G) do
    if type(name) == "string" and type(obj) == "table"
        and name ~= "VehicleCamera" and name ~= "VehicleCameraExtension"
        and (name:find("Camera") or name:find("Reflector") or name:find("Mirror"))
        and type(obj.actionEventLookLeftRight) == "function" then
      local old = obj.actionEventLookLeftRight
      obj.actionEventLookLeftRight = makeLookWrapper(old, name)
      table.insert(self.overwrittenFunctions, { object = obj, funcName = "actionEventLookLeftRight", oldFunc = old })
      count = count + 1
      logInfo("also overwrote %s.actionEventLookLeftRight", name)
    end
  end

  if count > 0 then
    self.installed = true
  end
  logInfo("install done, overwrote %d class(es)", count)
  return count > 0
end

--- Restore original functions.
function VehicleCameraExtension:uninstall()
  for i = #self.overwrittenFunctions, 1, -1 do
    local info = self.overwrittenFunctions[i]
    if info.object and info.funcName and info.oldFunc then
      info.object[info.funcName] = info.oldFunc
    end
    self.overwrittenFunctions[i] = nil
  end
  self.installed = false
end
