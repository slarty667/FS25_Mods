# fsmods — per-savegame mod-set manager for FS25 (macOS)

Manage which mods are active per Farming Simulator 25 savegame without doing it
by hand. Function mods live in a `[global]` set (always on); vehicle/asset/map
mods live in per-save `[sets.*]`. A single command swaps the game's mods folder
to the right subset using **hardlinks** for zip mods and **symlinks** for folder
mods (instant on APFS, no copying, no disk bloat).

> **Why hardlinks for zips?** FS25 does **not** recognise a *symlinked* zip — it
> tries to read the entry as an unpacked folder (`<name>/modDesc.xml`) and fails,
> so the mod silently doesn't load. A hardlink is indistinguishable from a real
> file, so FS opens it as a normal zip. Folder mods (e.g. dev mods) work fine as
> symlinks. Both require library and mods folder to be on the **same volume**
> (both under `$HOME` → same APFS volume); `fsmods` falls back to a copy if not.

This is the macOS-native answer to the Windows-only "mod manager" tools.

## How FS25 works (the facts this is built on)

- FS25 has **one** global mods folder:
  `~/Library/Application Support/FarmingSimulator2025/mods/`
- Which mods are *active* is stored **per savegame** in
  `<savegame>/careerSavegame.xml` as `<mod modName="…" version="…" fileHash="…"/>`.
- A mod merely *present* in the folder is **not** auto-activated for an existing
  save — see "Adding a new function mod" below.

## Architecture

```
~/FS25_ModLibrary/          # the library: every mod (zip or folder)
   FS25_AutoDrive.zip
   FS25_Courseplay.zip
   ...
profiles.toml               # global set + per-save sets + profiles
        │  fsmods use <profile>
        ▼
~/Library/.../FarmingSimulator2025/mods/   # hardlinks (zips) + symlinks (folders)
```

`fsmods` tracks what it created in `.fsmods_state.json` so the next `use` removes
exactly its own entries — real files (e.g. `*.disabled`) and foreign symlinks are
never touched.

**Restart FS after `use`:** the game scans the mods folder only at startup. Quit
FS completely and relaunch before loading the switched save.

A **profile** = `[global]` ∪ chosen `[sets.*]` ∪ optional inline `mods`,
optionally mapped to a `savegame` so you can run `fsmods use savegame3`.

## Setup

The project uses its own virtualenv (per-project convention). It is
**stdlib-only** (needs Python ≥ 3.11 for `tomllib`), so there is nothing to
`pip install` — the venv only pins the interpreter.

```bash
cd tools/fsmods
python3.13 -m venv .venv          # one-time
./fsmods --help                   # wrapper uses .venv automatically
```

## First run

```bash
# 1. Generate profiles.toml from your existing savegames.
#    Mods present in ALL saves become [global]; each save's remainder a set.
./fsmods scan --write --library ~/FS25_ModLibrary

# 2. Move your loose mod zips out of the game folder into the library.
#    (Moves *.zip only; symlinks and folders — e.g. dev mods — are left alone.)
./fsmods migrate --dry-run        # preview
./fsmods migrate --yes            # do it (writes a manifest log into the library)

# 3. Switch to a savegame's mod set before launching the game.
./fsmods use zielonka             # or: ./fsmods use savegame1
```

## Commands

| Command | Purpose |
|---------|---------|
| `scan` | Bootstrap `profiles.toml` from savegames. `--write` to save, `--force` to overwrite, `--min-saves N` to loosen the "global" threshold. |
| `use <profile\|savegameN>` | Link `global + sets` into the mods folder. **On a real switch** (target differs from the last-used profile) it first auto-`sync`s the *outgoing* profile from its savegame, so an in-game mod trim is captured automatically before re-linking. `--dry-run` previews, `--no-sync` skips the auto-sync. |
| `status` | Show what is linked now and which profile it matches. |
| `list` | List the global set, all sets and profiles with mod counts. |
| `doctor` | Mods referenced by saves but missing from the library, and library mods unused by any save (`-v` for details). Supersedes `find_unused_mods.py`. |
| `migrate` | Move loose zips from the mods folder into the library. `--dry-run` / `--yes`. |
| `sync <profile\|savegameN>` | Re-derive a profile's set from its savegame's *current* `careerSavegame.xml` — use after trimming a save's mods in-game. Rewrites only that `[sets.*]` block, preserving the rest of the config. `--dry-run` previews, `--set` if the profile has several. |
| `adopt <zip> --set <name>\|--global` | Adopt a freshly downloaded mod: move its `.zip` into the library and add it to a set (or `[global]`). Config-only and safe while the game runs; do the `use` afterwards when the game is closed. `--dry-run` previews. |

Every mutating command takes `--dry-run`. Config path override: `--config PATH`.

## Adding a new function mod to *all* saves

1. Put the zip in `~/FS25_ModLibrary/`.
2. Add its name to `[global]` in `profiles.toml`.
3. `fsmods use <current-save>` links it in.
4. **One manual step remains:** FS does not auto-activate a newly present mod in
   an existing save. On the next load, tick it once in the mod-selection screen
   (FS then writes it into that save's `careerSavegame.xml`). A future
   `careerSavegame.xml` injector (phase 2) can automate this away — pending
   verification of the `fileHash` algorithm FS uses.

## Safety model (Asimov: no data loss through sloppiness)

- `use` removes **only** entries it created itself (tracked in
  `.fsmods_state.json`) plus leftover managed symlinks from the old approach.
  Real files/folders (e.g. `*.disabled`) and foreign symlinks are reported and
  **never** touched.
- Deleting a hardlink is safe — the library copy survives (it shares the inode,
  reference-counted).
- `migrate` *moves* (never deletes) and records a manifest.
- Dry-run everywhere; the library lives outside the repo and outside the game
  folder, so nothing collides.

## `[external]` — link dev mods straight from the repo

```toml
[external]
FS25_HoldToSteer = "~/Dropbox/htdocs/FS25_Mods/mods/FS25_HoldToSteer"
```

Now `FS25_HoldToSteer` can appear in `[global]`/sets and be linked from the repo
instead of the library — handy for mods you develop here.

## Verified behaviour & caveats

- **Symlinked zips do NOT load in FS25** (verified in-game: log shows
  `Failed to open xml file mods/<name>/modDesc.xml` and the mod is skipped).
  That is why zips are **hardlinked**. Folder mods work as symlinks.
- `doctor` may list mods "missing from library" that are actually DLC (`pdlc_*`,
  auto-skipped by `use`) or removed mods referenced by old saves; review before
  deleting anything.
- Save-list previews: base-game maps (Zielonka, Riverbend Springs, Hutan Pantai)
  always show a thumbnail. Mod-map saves show a warning triangle until their set
  is active — that is expected, not data loss.
