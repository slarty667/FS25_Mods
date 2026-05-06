# Changelog

## Unreleased

### Fixed

- **Frontloader vs. LMB mouse steering:** With cab/tractor (or trailer)
  selection, fork/arm could still move from horizontal mouse steering because
  part of the input path uses **`g_inputBinding.actionEvents`** targets on the
  **implement** (`AXIS_FRONTLOADER_ARM`, `AXIS_FRONTLOADER_TOOL`,
  `AXIS_FRONTLOADER_TOOL2`), not only `lastInputValues` on specs. The mod now
  wraps those callbacks for the controlled vehicle’s hierarchy and **re-wraps**
  after Giants replaces callbacks when switching implements (trailer ↔ tractor ↔
  loader ↔ fork).

### Technical

- Removed temporary Cursor debug-session logger (`MouseSteeringDebugAgent`).

## 0.9.0 — 2026-04-25

First public beta.

### Features

- Realistic mouse-held steering with **rate-based** input (cursor offset =
  steer rate; wheel holds angle until you move the mouse again).
- **Smooth return after LMB release (“coast”):** steering output decays toward
  centre; speed follows the game steering-return option when available, else a
  configurable fallback % (tuned to feel close to keyboard return).
- **LMB takeover:** on LMB down, reads the current wheel angle from the vehicle
  so steering does not jump to straight.
- **Steering-linked cabin camera (“look into the corner”):** optional extra
  `rotY` after `VehicleCamera:update`; reverses flip with travel direction;
  anchored blend toward interior default during coast.
- **Projected driving path**: two green ground lines showing the outer edges
  of the vehicle's future position, based on current steering angle.
- **Vehicle-aware path length**: scales with the vehicle's own top speed, so
  feel is consistent across classes.
- **Path start at vehicle nose**: reads `vehicle.size.length` +
  `sizeCenterOffset` to offset the lines so they start at the actual front
  of the vehicle, not the geometric centre. Critical on combines.
- **Lines on vehicle outer edges**: uses real vehicle width + 15 cm padding
  per side instead of wheel track, so the lines mark where the body will pass.
- **Terrain-following**: lines hug the heightmap, not a flat plane.
- **Reverse support**: path flips behind the vehicle when reversing.
- **Trailer swing prediction** (reverse only): yellow line using a
  kingpin-hitch model with live hitch-angle measurement. Approximates
  tongue length per trailer type (single-axle ≈ 65%, two-axle with
  turntable ≈ 80% of trailer length).
- **Visibility modes** (via settings): Off / On-steering (any input source) /
  Mouse only (includes post-LMB coast) / Always in vehicle.

### Sensitivity & behaviour

- **Servo-style damping** scales with the vehicle's own top speed. Tractor
  and truck both get 25% sensitivity at their respective full throttle.
- **Steering source is input-agnostic**: path reflects keyboard A/D,
  controller and wheel too, not only mouse.
- **Rate model with mouse deadzone** (configurable) prevents sub-pixel
  jitter without killing fine control.

### Quality of life

- **Frontloader coexistence:** mouse steering stays **armed by default** with a
  frontloader fitted. While the **frontloader arm** or a **tool on that arm** is
  the selected implement, mouse steering input is **suppressed** so vanilla can
  drive the loader with the mouse. Select the **tractor** or **trailer** again
  and mouse steering works without toggling.
- **Frontloader hydraulics vs. LMB steer:** with cab/tractor focus, mouse-driven
  `axis*` inputs on loader/fork `lastInputValues` are zeroed each frame while
  LMB mouse steering is active, so forks should not move up/down from steering.
- **Auto-disarm on vehicle leave**; **auto-arm on enter** for the next vehicle
  (clean baseline via `onControlledVehicleChanged`).
- **LMB + RMB = free look**: hold both for hands-on-wheel, head-turning.
  FS25's cursor-toggle is suppressed while steering is active.
- **Safety net against sprünge**: when re-gripping LMB, steering waits for
  the cursor to return to the centre before accumulating, so accidental
  mouse positions at screen edges don't swing the wheels to full lock.
- **HelpIconBox entry**: Ctrl+M hint visible top-left while in a vehicle.

### Configuration

- All settings are in **Options → General** under **Mouse Steering**.
- Settings persist globally per user profile (not per savegame).

### Technical

- **Frontloader selection detection:** `rootVehicle:getSelectedVehicle()` plus
  a DFS over `spec_attacherJoints.attachedImplements` from each vehicle
  classified as a frontloader in `VehicleIntrospection:getAttachedImplementsInfo`.
- Clean split between data (`MouseSteeringSettings`) and UI
  (`MouseSteeringSettingsUI`) to avoid UIHelper overwriting numeric values.
- I3D line rendering via AutoDrive's `drawing/line.i3d` when present;
  `drawDebugLine` fallback otherwise.
- Multi-group segment pool: tractor path (green) + trailer path (yellow)
  share the same node pool with per-group colouring.
- Live hitch-angle measurement via `localToLocal(trailerRoot, vehicleRoot)`
  so the trailer simulation starts from the real current articulation.

### Known limitations

- Articulated vehicles (Knicklenker) use Ackermann approximation.
- Terrain-follow uses heightmap only — bridges and overpasses ignored.
- Exact trailer axle positions approximated from `size.length`; implement
  `spec_wheels.wheels` not reliably populated at introspection time.
