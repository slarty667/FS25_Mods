--[[
  register.lua
  Bootstrap for FS25_HoldToDetach (variant C: speed-lock).

  Installs the AttacherJoints.isDetachAllowed overwrite BEFORE the vehicle types are
  validated, so the per-type overwritten-function registration captures our version.
]]

source(Utils.getFilename("scripts/HoldToDetach.lua", g_currentModDirectory))

local function init()
    if not g_currentModName or g_currentModName ~= "FS25_HoldToDetach" then
        return
    end

    -- Primary, correctly-timed install: run right before TypeManager.validateTypes so
    -- AttacherJoints.registerOverwrittenFunctions registers our wrapped isDetachAllowed.
    if TypeManager and TypeManager.validateTypes then
        TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, function()
            HoldToDetach.install()
        end)
    end

    -- Also try immediately (harmless / idempotent) in case types are already built.
    HoldToDetach.install()
end

init()
