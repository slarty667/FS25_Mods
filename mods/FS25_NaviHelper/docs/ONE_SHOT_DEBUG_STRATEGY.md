# One-Shot Debug Strategy (minimize restarts and log analysis)

Goal: Get NaviHelper + AutoDrive target detection working with **as few game restarts and log round-trips as possible**.

## How it works

1. **Single diagnostic file per run**  
   When you press **Alt+N** in a vehicle and no target is found, the mod writes a **full state dump** to:
   - `.../FarmingSimulator2025/mods/FS25_NaviHelper/NaviHelper_diagnose.txt`  
   (same folder as the mod; on macOS typically under `~/Library/Application Support/`.)

2. **One run → one file**  
   The file contains:
   - Whether `vehicle` is nil and how it compares to `controlledVehicle`
   - `vehicle.ad` and `vehicle.ad.stateModule`
   - Result of `getFirstMarker`, `marker.id` / `marker.name`, and `getWayPointById`
   - Result of `getSelectedDestinationFromVehicle(vehicle)`

   No need to search through `log.txt`; everything relevant is in this one file.

3. **You do once**  
   - Start game, get in a vehicle, select a destination in AutoDrive (e.g. "Hof 1"), leave AD window open.
   - Press **Alt+N** (NaviHelper on).
   - You’ll see the usual “Bitte in AutoDrive ein Ziel wählen” (or similar) and a second line like **“NaviHelper: Diagnose → NaviHelper_diagnose.txt”**.
   - Exit game, copy the diagnose file into your **project folder** so it sits next to the scripts:
     - From: `~/Library/Application Support/FarmingSimulator2025/mods/FS25_NaviHelper/NaviHelper_diagnose.txt`
     - To: `FS25_NaviHelper/NaviHelper_diagnose.txt` (your Dropbox project).

4. **We fix in one go**  
   From the contents of `NaviHelper_diagnose.txt` we can see exactly where the chain breaks (no vehicle, no `vehicle.ad`, no marker, wrong waypoint, etc.) and apply a single, targeted fix. No need for multiple “change → restart → send log” cycles.

## Optional: disable diagnostic later

After the bug is fixed, you can:
- Remove or shorten the second notification (“Diagnose → …”) in `NaviHelper.lua` (search for `diagPath and g_currentMission`), or
- Stop calling `NaviHelper.writeDiagnosticFile(vehicle)` in `onToggleUI` so the file is no longer written.

The diagnostic is there only to minimize cost (restarts + log analysis) until the integration works.
