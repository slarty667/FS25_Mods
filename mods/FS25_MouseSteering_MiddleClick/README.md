# Mouse Steering (Middle-Click) — FS25

Realistic mouse steering for Farming Simulator 25 with live reverse-camera-style
path projection, trailer swing prediction, and vehicle-aware sensitivity.

## What it does

- **Mouse-held steering:** press and hold **LMB** to steer; the further the
  cursor is from the screen centre, the faster the wheels rotate. Let go and
  the vehicle's own physics re-centre the wheels naturally.
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
- **Frontloader-aware:** when a frontloader is attached, mouse steering is
  off by default (so pallet work with the mouse isn't ruined). Re-enable
  manually with `Ctrl+M` if needed.

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
| Toggle Mouse Steering on/off | `Ctrl+M` *or* **Middle Mouse Button** |
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
| Steering bar HUD | On | toggle | Top-of-screen bar showing current steering angle |
| Driving path projection | On-steering | Off/On-steering/Mouse-only/Always | When the green ground lines are visible |
| Trailer path (reverse) | On | toggle | Yellow line showing trailer swing while reversing |

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
