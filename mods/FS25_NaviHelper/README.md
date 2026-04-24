# FS25_NaviHelper

Shows a **navigation aid** (arrow + distance) to your destination in Farming Simulator 25.  
Set the destination in **AutoDrive**; NaviHelper shows the arrow and “Next / Total” distance. You can drive manually or let AutoDrive drive.

## How to use (with AutoDrive)

1. Enter a vehicle that has AutoDrive.
2. In the **AutoDrive window** (e.g. “AutoDrive – Fahren”), choose a destination (e.g. “Gesteinbrecher”).
3. Press **Alt+N** (or **F10**) to **activate** NaviHelper. If a destination is selected in AutoDrive, the nav aid appears: arrow + “To: Gesteinbrecher” + “Next: X m | Total: Y m”. If no destination is set (or AutoDrive is not installed), a **green notification** (top-right) tells you to select one in AutoDrive or that AutoDrive is required.

**Toggle / hide:** **Alt+N** or **F10** = turn nav aid on/off. **Alt+M** / **F9** = map target mode; **Ctrl+N** / **F11** = clear target. Keys in **Settings → Controls** (NaviHelper); left and right Alt/Ctrl bound by default.

## UX (FS mod convention)

In Farming Simulator, **vehicle control** is keyboard (WASD) and **mouse is used for camera** (and optionally steering mods). Mod features are normally controlled via **key bindings** in Settings → Controls, not by clicking on HUD text. NaviHelper follows that: no click-to-toggle; toggle and actions are done with the keys you assign (or the default bindings). The nav aid is **off** until you press Alt+N; then it shows the arrow if a target exists, or a green message if not.

## Without AutoDrive

You can set a target via the mod’s key bindings (map mode Alt+M then click map, or Alt+T for “target ahead”), if your setup delivers those key events. On some systems (e.g. Mac) key events may not reach the mod; using AutoDrive as the target source is then the way to get the nav aid.

## Installation (macOS)

1. Copy the **unpacked** mod folder to:
   ```
   ~/Library/Application Support/FarmingSimulator2025/mods/FS25_NaviHelper/
   ```
2. Enable the mod in the game’s Mods menu.

**Development (this repo):** From the project root, run `./tools/link-mod.sh FS25_NaviHelper` to use a symlink so the game loads the mod from the repo; no copy needed. See [docs/mac-testing.md](../../docs/mac-testing.md) in the repo.

## What you see

When you press **Alt+N** to turn the nav aid **on**: if a destination exists (from AutoDrive or the mod), you see **arrow** + “To: &lt;name&gt;” (if from AutoDrive) + “Next: X m | Total: Y m”. If there is no destination, a green ingame message asks you to select one in AutoDrive (or says AutoDrive is required). Toggle **off** with Alt+N again; then nothing is drawn.

## Dependencies

- **Optional but recommended:** **FS25_AutoDrive**. NaviHelper reads the current/selected destination from the vehicle and shows the nav aid.
- Without AutoDrive, the mod can show an arrow to a target you set via its key bindings (where supported).

## Technical notes

- Destination from AutoDrive: **active route** (`drivePathModule.wayPoints`) or **selected target** in UI (`stateModule.firstMarker`).
- Key bindings: **left and right** Alt and Ctrl where applicable.
- Routing uses AutoDrive’s path when available; otherwise a straight-line arrow.
