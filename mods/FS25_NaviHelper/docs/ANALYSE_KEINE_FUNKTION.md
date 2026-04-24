# Bird's-Eye Analysis: "Weiterhin keine Funktion"

## Goal

NaviHelper shall show **arrow + distance** in the vehicle when:
1. User pressed Alt+N (nav aid ON).
2. A target exists (AutoDrive "Hof 1" or own target).

---

## Chain Overview

```
[Game loads mod]
  → register.lua runs
  → NaviHelperVehicle spec registered, added to all Drivable+Enterable types
  → addModEventListener(NaviHelper) → loadMap(), draw(), update(), keyEvent()

[User enters vehicle]
  → onRegisterActionEvents(self, _, true) for that vehicle
  → Alt+N bound to NaviHelperVehicle:onToggleUI → NaviHelper:onToggleUI(vehicle)
  → navAidOn = true (and green message if no target)

[Every frame when HUD is drawn]
  → ??? onDrawUIInfo(self) for each vehicle with that spec ???
  → NaviHelperVehicle:onDrawUIInfo() checks: NaviHelper, navAidOn, uiVisible, controlledVehicle==self
  → NaviHelper:drawForVehicle(self)
  → getEffectiveTarget(vehicle) → AutoDrive getSelectedDestinationFromVehicle(vehicle)
  → draw arrow (createImageOverlay, setOverlayColor, setOverlayRotation, renderOverlay)
  → draw text (renderText or renderTextOverlay)
```

---

## Possible Failure Points

| # | Where | What could go wrong |
|---|--------|----------------------|
| 1 | **onDrawUIInfo never called** | FS25 might not call this event for our spec (e.g. only for certain specs, or different event name). We assumed "onDrawUIInfo" from AutoDrive reference – needs verification. |
| 2 | **Early return in onDrawUIInfo** | navAidOn false (toggle not working or keyEvent path used without setting state?). uiVisible false. controlledVehicle ~= self (e.g. trailer vs root vehicle). |
| 3 | **drawForVehicle not reached** | Same as (2); or NaviHelper/NaviHelper.drawForVehicle nil. |
| 4 | **No target in drawForVehicle** | getEffectiveTarget(vehicle) returns nil – but log showed "getSelectedDest: ok dest=Hof 1", so target exists when we call from onToggleUI. In draw we use the same vehicle; possible timing/state difference? |
| 5 | **Rendering APIs missing** | In onDrawUIInfo context, createImageOverlay / renderOverlay / renderText might be nil or have different names. We use pcall so errors are swallowed. |
| 6 | **Wrong coordinates** | GDN: renderText(x, y, fontSize, text) with **origin bottom-left**. We use hudCenterY = 0.88 → 88% from bottom = **top** of screen. If we wanted "lower area", we need **low y** (e.g. 0.1–0.15). |
| 7 | **Mod draw() not used** | We rely on vehicle onDrawUIInfo. If that event is never fired for us, we never draw. Mod draw() runs but we return early when no controlledVehicle in some code paths. |

---

## What We Know

- **Target detection works:** Log shows `getSelectedDest: ok dest=Hof 1` (from diagnostic or AutoDrive bridge).
- **No NaviHelper errors** in log.
- **We never confirmed** that onDrawUIInfo is actually called, or that drawForVehicle runs when navAidOn is true.

---

## Actions Taken

1. **Diagnostic logging (throttled):** In onDrawUIInfo and drawForVehicle, log once every 3 seconds: whether we're called, navAidOn, uiVisible, controlledVehicle==self, hasTarget. So one log session shows where the chain breaks.
2. **Fallback draw path:** In NaviHelper:draw(), when controlledVehicle and navAidOn exist, call drawForVehicle(controlledVehicle). So even if onDrawUIInfo is never called, we still try to draw from the mod's draw().
3. **Coordinate fix:** Use bottom-left origin: e.g. hudCenterY = 0.12 (lower area); textY slightly above that.
4. **Optional:** Minimal "hello world" in onDrawUIInfo (e.g. single renderText) to verify that this event runs and that renderText is available.

---

## Next Steps for You

1. Update mod in game folder (rsync from project).
2. Start game, enter vehicle, select "Hof 1" in AutoDrive, press Alt+N.
3. Play for a few seconds; then check log.txt for lines like:
   - `[NaviHelper] onDrawUIInfo: ...`
   - `[NaviHelper] drawForVehicle: ...`
4. If **onDrawUIInfo** never appears → the game is not calling our spec's draw event (try different event or draw from mod draw only).
5. If **drawForVehicle** appears with hasTarget=true but still nothing on screen → rendering APIs or coordinates; try minimal renderText(0.5, 0.5, 0.02, "NaviHelper") to confirm.
