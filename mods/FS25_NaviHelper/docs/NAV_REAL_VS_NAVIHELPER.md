# Real car navigation vs. NaviHelper (current vs. goal)

## Real car navigation (e.g. Google Maps, built-in navi)

| Feature | Description |
|--------|-------------|
| **Route on map** | The full route is drawn on the map (road-following path). |
| **Route on street** | In AR or HUD mode: arrows/lane guidance painted on the road ahead ("follow the blue line", turn arrows on the lane). |
| **Turn-by-turn** | "In 500 m turn left", "Take the second exit at the roundabout". |
| **Distance to next action** | "Next turn in 412 m" (to the next decision point, not just to final destination). |
| **Compass / direction** | Optional: arrow or compass showing direction to destination. |

## NaviHelper – current state (after "Hallo" and arrow fix)

| Feature | Status |
|--------|--------|
| **Direction arrow** | Yes: ↑ ↓ ← → (4 directions) toward target/next waypoint. |
| **Distance** | Yes: "Next: X m \| Total: Y m" (next = to next path node or target; total = to destination). |
| **Route on map** | No: no path drawn on minimap or big map. |
| **Route on street** | No: no line or arrows on the road in the 3D world. |
| **Turn-by-turn** | No: no "in X m turn left" or lane hints. |
| **Data source** | AutoDrive: we use its destination and, when AD is driving, its path (wayPoints). So we already have the same route data AutoDrive uses for its own "arrows on the road". |

## Next challenge: "echtes Routing" (like AutoDrive’s arrows on the road)

- **Goal:** Show the route in the world – line and/or arrows on the street, so the player can follow it manually like following AutoDrive’s arrows when the AI drives.
- **Data we have:** When AutoDrive has an active route we get `effPath` (waypoints from `drivePathModule.wayPoints`). When the player only selected a destination (no AD drive), we can compute a path with `NaviHelperAD.getPathFromToWorld(vehiclePos, dest)`.
- **Rendering options:**
  1. **Engine Debug API (FS25):** We draw the path with `drawDebugLine` between waypoints. In practice this does **not** show in normal play (GDN: "only for debug rendering"); AutoDrive does not use this for its route display.
  2. **AutoDrive’s method:** AutoDrive draws route arrows/models in its own way (likely I3D or custom render). To get the same look we would need to inspect how AutoDrive’s draw/rendering works (e.g. in its scripts) or use another in-world drawing method if the engine exposes one.
  3. **Minimap:** Drawing the route as a line on the minimap could work if the game allows drawing on the map layer.
