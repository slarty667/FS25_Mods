# FS25 Vehicle Specialization – Reference (from FS25_AutoDrive)

This document summarizes how **FS25_AutoDrive** adds a vehicle specialization in FS25, so NaviHelper can do the same (SOTA pattern).

---

## 1. modDesc.xml (AutoDrive)

- **Only one script** is listed in `<extraSourceFiles>`: **`register.lua`** (at mod root).
- No `<vehicleTypes>` or `<specializations>` XML. The game does **not** load the spec from modDesc; everything is done in Lua.
- Actions and `<inputBinding>` are defined in modDesc as usual.

```xml
<extraSourceFiles>
    <sourceFile filename="register.lua" />
</extraSourceFiles>
```

---

## 2. register.lua (bootstrap)

- **Sources** all needed Lua files (including `scripts/Specialization.lua`, `scripts/AutoDrive.lua`, etc.) via `source(Utils.getFilename("scripts/...", g_currentModDirectory))`.
- **Registers the specialization** with the global specialization manager:
  ```lua
  g_specializationManager:addSpecialization("AutoDrive", "AutoDrive",
      Utils.getFilename("scripts/AutoDrive.lua", g_currentModDirectory), nil)
  ```
  Name and className can be the same; the third argument is the path to the spec script.
- **Adds the spec to all vehicle types at runtime**: it does **not** use extra XML. It hooks into the game’s type validation so that after vehicle types are loaded, it runs:
  ```lua
  TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, AutoDriveValidateVehicleTypes)
  ```
  `AutoDriveValidateVehicleTypes` just calls `AutoDriveRegister.registerAutoDrive()`.
- **registerAutoDrive()** loops over **all** vehicle types and adds the spec to each type that has the right prerequisites (and doesn’t have it yet):
  ```lua
  for vehicleType, typeDef in pairs(g_vehicleTypeManager.types) do
      if typeDef ~= nil and vehicleType ~= "horse" and (not typeDef.hasADSpec == true) then
          if AutoDrive.prerequisitesPresent(typeDef.specializations) then
              if typeDef.specializationsByName[AutoDrive.ADSpecName] == nil then
                  g_vehicleTypeManager:addSpecialization(vehicleType, AutoDrive.ADSpecName)
                  typeDef.hasADSpec = true
              end
          end
      end
  end
  ```
- Then **addModEventListener(AutoDriveRegister)** and **addModEventListener(AutoDrive)** so the mod still gets loadMap, draw, etc.

Result: one script (`register.lua`) is loaded by the game; it registers the specialization and injects it into every vehicle type that satisfies the prerequisites (e.g. Drivable + Enterable), without any vehicleTypes/specializations XML in modDesc.

---

## 3. Specialization.lua (vehicle spec)

- **prerequisitesPresent(specializations)**  
  Returns true for vehicle types that have e.g. AIVehicle, Motorized, Drivable, Enterable (or SplineVehicle, Drivable, Locomotive). So “all normal driveable vehicles” get the spec.
- **registerEventListeners(vehicleType)**  
  Registers: `onRegisterActionEvents`, `onLoad`, `onDrawUIInfo`, `onUpdate`, etc.
- **onRegisterActionEvents(self, _, isOnActiveVehicle)**  
  When the player is in a vehicle (or it’s the controlled vehicle), registers **action events on the vehicle**:
  ```lua
  InputBinding.registerActionEvent(g_inputBinding, action[1], self, ADInputManager.onActionCall, false, true, false, true)
  ```
  Here **`self`** is the **vehicle** instance. So when the user presses the key, the callback runs with the vehicle as target – i.e. the event is delivered in vehicle context.
- **onLoad(savegame)**  
  Creates `self.ad = {}` and all submodules (stateModule, drivePathModule, …). The spec stores its state on the vehicle.
- **onDrawUIInfo(self)**  
  Draws the HUD when `self` is the controlled vehicle. So drawing is also vehicle-scoped (only for the vehicle the player is in).

Important: **No** separate XML for vehicle types or specializations. The spec is registered by name with `g_specializationManager:addSpecialization`, then attached to types in Lua with `g_vehicleTypeManager:addSpecialization(vehicleType, specName)`.

---

## 4. register.lua – Bootstrap flow (excerpt)

- **At the end:** a single `check()` is called. It:
  1. Ensures `g_currentModName == "FS25_AutoDrive"` (and that the mod is active).
  2. Sets `TypeManager.validateTypes = Utils.prependedFunction(TypeManager.validateTypes, AutoDriveValidateVehicleTypes)` so that every time the game validates vehicle types, `AutoDriveValidateVehicleTypes` runs first. In AutoDrive that hook only calls `AutoDriveRegister.onMissionWillLoad(g_i18n)` (translations).
  3. Calls `addModEventListener(AutoDriveRegister)` and `addModEventListener(AutoDrive)`.
  4. Calls **once** `AutoDriveRegister.registerAutoDrive()` (and `registerVehicleData()`, `registerPlaceableData()`). So the spec is attached to all current vehicle types when the mod loads; the `validateTypes` hook is used for other things (e.g. l10n), not for adding the spec again.

- **Spec name:** `AutoDrive.ADSpecName = g_currentModName .. ".AutoDrive"` (e.g. `"FS25_AutoDrive.AutoDrive"`). The same name is used in `g_vehicleTypeManager:addSpecialization(vehicleType, AutoDrive.ADSpecName)`.

- **Registration:**  
  `g_specializationManager:addSpecialization("AutoDrive", "AutoDrive", Utils.getFilename("scripts/AutoDrive.lua", g_currentModDirectory), nil)`  
  So the **first** argument is the internal name (can be same as class), the **second** is the class name, the **third** is the path to the spec Lua file.

---

## 5. Summary for NaviHelper

| Step | What to do |
|------|------------|
| **modDesc** | Keep `<actions>` and `<inputBinding>`. In `<extraSourceFiles>` have **only** a single bootstrap script (e.g. `register.lua` or `scripts/register.lua`). |
| **Bootstrap script** | 1) Source NaviHelper.lua and the new vehicle spec script. 2) `g_specializationManager:addSpecialization("NaviHelperVehicle", "NaviHelperVehicle", pathToSpecLua, nil)`. 3) Prepend to `TypeManager.validateTypes` a function that calls our “register spec to all vehicle types” (loop `g_vehicleTypeManager.types`, prerequisitesPresent, then `g_vehicleTypeManager:addSpecialization(vehicleType, "FS25_NaviHelper.NaviHelperVehicle")`). 4) `addModEventListener(NaviHelper)` so the existing global mod (map, draw) still runs. |
| **Vehicle spec script** | prerequisitesPresent: e.g. Drivable + Enterable. registerEventListeners: onRegisterActionEvents (and optionally onLoad if we need per-vehicle state). onRegisterActionEvents: register the four NaviHelper actions with **self** (vehicle) and a callback that forwards to NaviHelper (e.g. NaviHelper:onToggleUI()). No XML, no new vehicle type – only add one specialization and attach it to existing types in Lua. |
| **NaviHelper.lua** | Remove global `registerActionEvents` (or leave it as fallback). Keep loadMap (map hook), draw (arrow + text), update, getEffectiveTarget, etc. The spec only forwards input to these. |

This matches the FS25 AutoDrive approach: **one bootstrap script, one vehicle specialization registered and attached in Lua, input handled in the vehicle spec so keys work in vehicle context.**
