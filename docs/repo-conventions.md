# Repo conventions

- **Mod structure:** Mods under `mods/` must meet FS25/ModHub technical minimums (modDesc.xml, entry point, etc.). For details and repo-specific notes, see [learned.md](learned.md). The typical layout (register.lua, scripts/, l10n/) reflects these requirements; deviations are fine if they still satisfy the game/ModHub.
- **`tmp/`:** Sandbox for experiments and WIP. Contents are not official mods; may be removed or restructured at any time. Do not rely on `tmp/` for stable structure.
- **`docs/`:** Authoritative project documentation. For API notes, workflow, and debugging, consult `docs/` (especially [learned.md](learned.md)) first.
- **`tools/`:** Scripts in `tools/` are part of the standard development workflow (symlink, zip, tail log, find unused mods). Use them when testing or preparing releases.
