# Route line rendering in FS25 – options and current choice

## Using AutoDrive's line asset (preferred when FS25_AutoDrive is installed)

When the **FS25_AutoDrive** mod is installed, NaviHelper loads AutoDrive's **drawing/line.i3d** from that mod (via `g_modManager:getModByName("FS25_AutoDrive")` and `Utils.getFilename("drawing/line.i3d", adMod.directory)`). We create our own root node under `g_currentMission.terrainRootNode`, clone the line mesh once per segment (up to `routeLineMaxSegments`), and each frame update segment positions/rotations/scales from the current path. Because these nodes live in **our** scene, nothing (e.g. ADDrawingManager) clears them, so the route line stays visible and performant. If AutoDrive is not installed or line.i3d cannot be loaded, we fall back to **drawDebugLine** (see below).

## Why we don't use ADDrawingManager (addLineTask)

We **did** use I3D via AutoDrive's **ADDrawingManager:addLineTask**. The path only **flickered** – something (AutoDrive or the engine) **clears** that manager's lines every frame, so our segments disappeared. So we use AutoDrive's **asset** (line.i3d) in **our** scene instead of their drawing manager.

1. **I3D-based lines (like AutoDrive)**  
   AutoDrive draws its route with `ADDrawingManager:addLineTask` – line segments as I3D geometry. That is the proper, performant way: one mesh per segment, no per-frame CPU draw. We tried that; in our context the manager (or AutoDrive) clears those lines every frame, so the path only flickered. We could not keep it visible without redrawing every frame, which caused accumulation and FPS collapse when we did it every frame.

2. **Official Engine API for mod 3D lines**  
   The GDN Engine docs expose **Debug** functions: `drawDebugLine`, `drawDebugPoint`, etc. They are in the **Debug** category and are intended for debugging. There is no documented, supported "draw 3D line for mods in release" API. So for a released mod, using Debug APIs is a pragmatic workaround, not the intended use.

3. **Custom I3D / spline in our mod**  
   The "proper" way would be: our mod loads a small I3D (e.g. line or ribbon), we update its positions each frame or when the path changes, and render it ourselves. That would require I3D assets and deeper engine/scenegraph usage. No such helper exists in the public script/engine docs we have.

## What we do now

- **Route line:**  
  - If AutoDrive is installed: we load **drawing/line.i3d** from the AutoDrive mod and use a segment pool in our own scene (see above).  
  - Otherwise: we draw **every frame** with **`drawDebugLine`** (Engine → Debug); single-frame draw, no accumulation, path stays visible.  
- **HUD (arrow + text):** Standard GDN: `renderText`, overlay for arrow – that part is by the book.

## How to switch to our own I3D (if not using AutoDrive's asset)

1. **Create a line-segment I3D**  
   In GIANTS Editor (or Blender + GIANTS exporter): create a thin box or cylinder (e.g. 1 m long, 0.1 m wide), export as e.g. `lineSegment.i3d`, put it in the mod (e.g. `assets/lineSegment.i3d`).

2. **Load it once**  
   In Lua: `loadSharedI3DFileAsync(Utils.getFilename("assets/lineSegment.i3d", g_currentModDirectory), "onRouteLineI3DLoaded", self)` (or sync `loadSharedI3DFile`). In the callback, store the root node and link it under the mission (e.g. `link(g_currentMission.terrainRootNode, root)` or a dedicated node).

3. **Pool of segments**  
   Either clone the segment node N times (e.g. 20–30) or use a single mesh and set many transforms. Simplest: N clones, each is a child of a "routeLineRoot" node.

4. **Each frame (or when path changes)**  
   For each path segment from `startIdx` to `startIdx + routeLineMaxSegments`: set the segment's position/rotation so it goes from waypoint `i` to `i+1` (position = midpoint, rotation from direction). Segments that aren't needed can be scaled to 0 or moved far away.

5. **Cleanup**  
   When nav aid is turned off or path is cleared, hide or remove the route line nodes (or scale to 0).

Then you can remove the `drawDebugLine` route drawing. No one else clears our nodes, so the line stays visible. This is the "state of the art" approach; the only missing piece was the I3D asset and the load/update code.

## If GIANTS adds a proper API later

If GIANTS ever documents a "draw 3D line for mods" (non-debug) API or a stable way to use the drawing manager so lines persist, we could use that instead of our own I3D.
