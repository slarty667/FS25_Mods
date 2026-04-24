# Original Mouse Steering Mod (Downloads) – Analysis

Reference: `~/Downloads/FS25_mouseSteering/` (aaw3k / modnext mouseSteering).

## Bootstrap (why their HUD draws)

- They **do not** register the mod at mod load time. They hook **Mission00.load** and create the mod instance **with the mission**:
  - `MouseSteering.new(modName, modDirectory, modSettingsDirectory, **mission**, g_i18n, g_gui)`
  - `mission.mouseSteering = modEnvironment`
  - `addModEventListener(modEnvironment)`
- So the mod object has `self.mission` and is created when the mission loads. Draw checks `self.mission.hud.isMenuVisible` and `not g_noHudModeEnabled`, then calls `self.hud:drawControlledEntityHUD()`.

## Mouse input (why steering works)

- They **do not use mouseEvent**. They **overwrite VehicleCamera.actionEventLookLeftRight** (via VehicleCameraExtension):
  - When mouse steering is active and not paused, they **do not** call the super (camera does not rotate).
  - They set `self.movedSide = inputValue * 0.001 * 16.666` (axis from game).
  - The game already turns mouse X into the "look left/right" action; they hijack that value.
- In vehicle `onUpdate`, they call `spec.mouseSteering:getMovedSide()` (returns and resets the value) and pass it to `MouseSteeringController:update()`, which produces `axisSide` and then `vehicle:setSteeringInput(spec.axisSide, true, InputDevice.CATEGORY.WHEEL)`.

## HUD visibility

- The **vehicle** decides when the HUD is visible. In `onUpdate` they call `self:updateMouseSteeringHUD()`:
  - Checks motor running, not AI, controlled, not obstructed, indicator mode (inside/outside/both).
  - If visible: `spec.mouseSteering:setControlledVehicle(self)` else `setControlledVehicle(nil)`.
- So the mod’s HUD object has a single "controlled vehicle"; it only draws when that is set.

## Drawing the bar

- They use a **HUDDisplay** subclass (`MouseSteeringIndicatorDisplay`) and **g_overlayManager** overlays (profiles from `data/gui/gui.xml`).
- In `draw()` they use `background:render()`, `bar:render()` (ThreePartOverlay), `drawFilledRect` for center/ticks, and `renderText` for angle text.
- So they rely on the game’s overlay/HUD pipeline; we can try a minimal version with only `drawFilledRect` and `renderText` in our mod’s draw.

## Steering application

- They **overwrite** vehicle `setSteeringInput`. When mouse steering is used they do **not** call super; they write directly to `self.spec_drivable.lastInputValues.axisSteer` (and related fields). The value comes from their controller (movedSide → controller → axisSide).

## Toggle

- Default binding: **Ctrl+.** (KEY_lctrl KEY_period), not middle mouse. User can rebind to middle mouse in options.
- Action is registered on the vehicle via `onRegisterActionEvents` with `addActionEvent(..., InputAction.TOGGLE_MOUSE_STEERING_CONTROL, ...)`.

## Spec attachment

- They use **TypeManager.finalizeTypes** (AdditionalSpecialization) to add `modName .. ".mouseSteeringVehicle"` to all drivable, non-locomotive vehicle types. No vehicleTypes in modDesc.

## Takeaways for our mod

1. **Bootstrap**: Create mod instance in Mission00.load, set `mission.mouseSteering`, then addModEventListener(instance). Gives correct mission/HUD context for draw.
2. **Input**: Capture steering from **VehicleCamera.actionEventLookLeftRight** when our steering is armed/active (store a movedSide; vehicle reads it in update). Keeps LMB/middle-click behavior; mouse movement comes from look axis.
3. **HUD**: Vehicle sets itself as controlled vehicle every frame when it should show the bar (e.g. armed + in vehicle + motor on). Mod draw() only draws when controlled vehicle is set and menu not visible / HUD not disabled.
4. **Bar**: Use at least `drawFilledRect` + `renderText` in mod draw(); optional overlays later.
