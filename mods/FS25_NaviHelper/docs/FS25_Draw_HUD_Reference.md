# FS25 Draw / HUD – Reference and "Do we do it right?"

## Log result (last run)

- **Target:** `getSelectedDest: ok dest=Hof 1 x=-170 z=9` – AutoDrive target is detected.
- **No** NaviHelper errors in log.
- Drawing is triggered from **vehicle specialization `onDrawUIInfo`** (not from mod `draw()`), so we run in vehicle HUD context.

---

## Are we using draw correctly?

**Short answer:** We are now aligned with how FS25 expects vehicle HUD drawing:

1. **Vehicle specialization `onDrawUIInfo`**  
   The game calls this only for the **active** vehicle when drawing the in-game HUD. So we draw from **NaviHelperVehicle:onDrawUIInfo** and call **NaviHelper:drawForVehicle(self)**. That is the same pattern as other vehicle HUD (e.g. speed, fuel). So yes – drawing from the vehicle spec is correct.

2. **Mod `draw()`**  
   We kept it as a fallback that calls `drawForVehicle(g_currentMission.controlledVehicle)`. In practice, mod `draw()` can run when `controlledVehicle` is still nil, so the main path must be the vehicle spec.

3. **APIs we use**  
   - **Overlay (arrow):** `createImageOverlay`, `setOverlayColor`, `setOverlayRotation`, `renderOverlay` – Engine Overlays (GDN).  
   - **Text:** GDN documents **`renderText(x, y, fontSize, string)`** (screenspace 0–1, origin **bottom-left**). We use `renderText` with fallback to `renderTextOverlay` if needed.

---

## Your approach: tutorial / sample first

That approach is the right one:

1. **Official docs**  
   - **GDN LUADOC FS25:** https://gdn.giants-software.com/documentation_scripting_fs25.php  
   - **Engine → Text Rendering:** `renderText`, `setTextColor`, `setTextAlignment`, etc.  
   - **Engine → Overlays:** `createImageOverlay`, `renderOverlay`, etc.  
   - **Script → Hud:** e.g. ContextActionDisplay uses `renderText` in its `draw()`.

2. **Minimal “hello world” for drawing**  
   - Get **one** thing on screen first, e.g. in a vehicle spec’s `onDrawUIInfo`:  
     `renderText(0.5, 0.5, 0.02, "Hello")`  
   - Then add overlay (arrow), then your logic (target, distance). We effectively did that by moving the real drawing into `drawForVehicle` and calling it from `onDrawUIInfo`.

3. **Example mods**  
   - **FS25 Production Info HUD** (ModHub) – adds HUD elements.  
   - **FS25 Modular HUD** – custom HUD/overlays.  
   - **FS25 Easy Dev Controls** – dev/debug UI.  
   - **GDN eBook “Scripting Farming Simulator with Lua”** – general scripting and patterns.

4. **Pitfall we hit**  
   Relying on **mod `draw()`** for vehicle HUD: it can run when `g_currentMission.controlledVehicle` is nil. So for “only when sitting in this vehicle” we must use **vehicle specialization `onDrawUIInfo`** (or similar vehicle-scoped draw), not only mod `draw()`.

---

## Summary

- **Drawing path:** Vehicle spec `onDrawUIInfo` → `NaviHelper:drawForVehicle(vehicle)` is correct for FS25.  
- **APIs:** Overlay (arrow) and text follow GDN; we added a `renderText` fallback.  
- **Your routine:** “Tutorial/sample first, then own feature” is the right order; GDN + one minimal draw (e.g. `renderText` in `onDrawUIInfo`) is the right starting point.
