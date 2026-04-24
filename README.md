# FS25 Mods

Farming Simulator 25 mods – development repo with shared docs and tools.

## Structure

- **`mods/`** – One subfolder per mod (e.g. `mods/FS25_NaviHelper/`). You can add `experiments/`, `old/`, `wip/` etc. alongside without cluttering the main mods.
- **`tmp/`** – Sandbox for experiments and WIP (not official mods).
- **`docs/`** – Project-wide notes: [learned.md](docs/learned.md), [mac-testing.md](docs/mac-testing.md).
- **`tools/`** – Scripts for development and release.

Authoritative project documentation lives in **`docs/`**; see [docs/repo-conventions.md](docs/repo-conventions.md) for repo structure and conventions.

## Tools

Run from project root (or use full paths).

| Script | Purpose |
|--------|---------|
| **`tools/link-mod.sh <ModName>`** | Create a symlink from `mods/<ModName>` to the game mods folder so you can test without copying. See [docs/mac-testing.md](docs/mac-testing.md). |
| **`tools/tail-log.sh`** | Tail the game log (`~/Library/Application Support/FarmingSimulator2025/log.txt`). |
| **`tools/zip-mod.sh <mods/ModName>`** | Build a release zip for a mod (e.g. for ModHub). Output: project root, e.g. `FS25_NaviHelper.zip`. |
| **`tools/find_unused_mods.py`** | Compare installed mods with savegame references; see script or docs. |

Example: link NaviHelper for testing, then zip it for release:

```bash
./tools/link-mod.sh FS25_NaviHelper
./tools/zip-mod.sh mods/FS25_NaviHelper
```

These scripts are part of the standard dev workflow.

## Docs

- [docs/repo-conventions.md](docs/repo-conventions.md) – Repo structure and conventions.
- [docs/mac-testing.md](docs/mac-testing.md) – Symlink workflow and Mac paths.
- [docs/learned.md](docs/learned.md) – Lessons learned and references.
