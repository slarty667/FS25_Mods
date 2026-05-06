# Mouse Steering (Middle-Click) — FS25

Realistic mouse steering for Farming Simulator 25 with live reverse-camera-style
path projection, trailer swing prediction, and vehicle-aware sensitivity.

## What it does

- **Mouse-held steering:** hold **LMB** to steer. Cursor offset from the
  screen centre acts as a **rate** (not a position): the wheel keeps its angle
  until you move the mouse again — similar to holding a steering wheel. After
  **LMB release**, steering eases back toward centre on a curve tuned to match
  the game's steering-return option (with a mod fallback % in settings).
- **Hand-over on LMB down:** picks up the current wheel angle from the
  physical wheels / drivable axis so you do not snap to straight when you
  grab the mouse mid-turn or after keyboard steering.
- **Optional “look into the corner”:** while LMB steering (and briefly during
  the return phase), the cabin camera can yaw slightly with steering; reverse
  travel flips the feel. Configure under **Mouse Steering** in General settings.
- **Projected driving path:** two green ground lines show where the outer
  edges of the vehicle will go, based on the current steering angle. Works
  for mouse, keyboard, controller and wheel inputs.
- **Trailer swing prediction:** while reversing with a trailer, a yellow line
  shows where the trailer's rear edges will swing. Kingpin-hitch model,
  single- and two-axle trailers supported.
- **Smart sensitivity:** steering damping scales with the vehicle's own top
  speed, so a 40 km/h tractor and an 80 km/h truck both feel consistent.
- **Free-look while steering:** hold **LMB + RMB** to keep steering while
  looking around with the mouse — hands on the wheel, head turning.
- **Frontloader-aware:** with a frontloader fitted, mouse steering stays **armed
  by default** like any other vehicle. Input is **paused only while** you have
  the **frontloader arm** or a **tool mounted on that arm** selected in the
  implement menu — then the game can use the mouse for the loader. Select the
  **tractor** or a **trailer** again and mouse steering works as usual. You
  can still turn the whole mod off/on with `Ctrl+M` or middle-click.
  While you **LMB steer with the tractor or trailer selected** (cab focus, not
  the loader arm or its tool), the mod applies **two** safeguards so the fork
  should not creep from steering motion: it clears axis-like entries in loader
  `spec_*`.`lastInputValues`, and it **short-circuits** the vanilla
  `AXIS_FRONTLOADER_*` input-binding callbacks registered against the loader /
  mounted tool objects (Giants may replace those callbacks when you change
  selection, so the mod re-wraps whenever the binding points at a new function).

## Installation

Download the latest `.zip` from the [releases page](#) and drop it into your
FS25 mods folder:

- **Windows:** `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\`
- **macOS:** `~/Library/Application Support/FarmingSimulator2025/mods/`
- **Linux (Proton):** inside the Proton prefix under the same path as Windows

Activate the mod in the in-game mod list when creating or loading a savegame.

## Controls

| Action | Default binding |
|---|---|
| Toggle Mouse Steering armed / disarmed | `Ctrl+M` *or* **Middle Mouse Button** (first press after enter typically disarms) |
| Hold to actively steer | **Left Mouse Button** |
| Free-look while steering | **Left Mouse + Right Mouse** (hold both) |

Bindings are remappable under **Options → Controls → Vehicle**.

## Settings

All options are in **Options → General** under the **Mouse Steering** group.

| Setting | Default | Range | What it does |
|---|---|---|---|
| Sensitivity | 9.0 | 0.5 – 25.0 | How quickly mouse displacement turns into steering angle |
| Output deadzone | 0.02 | 0.00 – 0.20 | Steering values below this clamp to zero (prevents wheel jitter) |
| Mouse deadzone | 0.003 | 0.00 – 0.05 | Mouse movement below this is ignored |
| Steering bar HUD | On | toggle | Bar while LMB steering or during the short return-to-centre after release |
| Driving path projection | On-steering | Off / On-steering / Mouse-only / Always | When the green ground lines are visible (Mouse-only includes post-LMB coast) |
| Trailer path (reverse) | On | toggle | Yellow line showing trailer swing while reversing |
| Look into corner (camera) | On | toggle | Extra cabin yaw with steering; LMB+RMB still allows free look |
| Corner look — max angle | 85° | 10–110° | Cap for camera yaw at full steer |
| Corner look — response | 14 | 4–35 | How fast the camera follows / relaxes |
| Invert corner look | Off | toggle | Flip direction if a vehicle or camera mod feels wrong |
| Use game steering return | On | toggle | After LMB up, match game steering-return speed when the API exposes it |
| Steering return (fallback %) | 80 | 5–200 | Faster recentre when the game value is unavailable or the toggle is off |

Settings persist globally per user profile in
`modSettings/FS25_MouseSteering_MiddleClick.xml`.

## Compatibility

- **AutoDrive**: works alongside it. If AutoDrive is installed, the mod uses
  AutoDrive's line asset for crisp I3D-rendered path lines; without AutoDrive,
  it falls back to `drawDebugLine` (slightly thinner lines, same information).
- **CruiseControlPlus / Courseplay / NaviHelper**: no known conflicts.
- **Singleplayer + Multiplayer**: tested in both. Path rendering is
  client-local (no network chatter).

## Known limitations

- **Articulated vehicles** (Knicklenker like wheel loaders) use the regular
  Ackermann approximation, so the projected path may be slightly off the real
  turning circle. Still useful as a tendency indicator.
- **Uneven terrain / raised roads**: the projected lines follow the terrain
  heightmap, not collision meshes. On overpasses or bridges, lines may sink
  into the roadbed.

## Credits

- Mouse steering core by **MouseSteering** (this repo).
- `scripts/lib/UIHelper.lua` by **Farmsim Tim** (based on discoveries by
  **Shad0wlife**), used with attribution per the licence header in that file.
- I3D line asset via the **AutoDrive** mod when present (not bundled).
- Debug support and testing: solo-developer grind powered by sarkastischen Iterationen.

## License

See `LICENSE` in the repo root. UIHelper.lua retains its original author
attribution in the file header.
