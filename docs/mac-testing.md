# Mac Testing

Quick guide for testing FS25 mods on macOS without copying files.

## FS25 mods folder (Mac)

The game expects mods here:

```
~/Library/Application Support/FarmingSimulator2025/mods/
```

## Symlink workflow

Develop in this project (e.g. `mods/FS25_NaviHelper/`) and let the game use it via a symlink:

```bash
./tools/link-mod.sh FS25_NaviHelper
```

Then edits in the project folder are visible to the game on the next start; no copy/sync needed.

## Tools

- **`tools/link-mod.sh <ModName|path>`** – Create symlink from project mod to game mods folder. Argument: mod name (e.g. `FS25_NaviHelper`) or path to mod folder (e.g. `mods/FS25_NaviHelper`). Idempotent: safe to run again if already linked.
- **`tools/tail-log.sh`** – Tail the game log: `~/Library/Application Support/FarmingSimulator2025/log.txt`
- **`tools/zip-mod.sh <mods/ModName>`** – Build a release zip (e.g. for ModHub). The zip is written to the **project root** (e.g. `FS25_NaviHelper.zip`). Excludes `*.DS_Store`.

Run from project root or use full paths to the scripts.
