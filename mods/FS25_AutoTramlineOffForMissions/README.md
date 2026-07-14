# FS25_AutoTramlineOffForMissions

Keeps NPC / contract fields free of tramlines ("Fahrgassen") in Farming Simulator 25.
Fields spawned for AI/contract work come with tramlines the player never asked for, and
those tramlines trigger recurring mission bugs (e.g. roller/Walzen missions stuck near
100%). This mod removes them and stops new ones — with zero interaction for the common case.

Standalone; the only dependency is **Precision Farming** (`FS25_precisionFarming`).
Your own seeder-created tramlines are **not** touched.

## How it works — three levers

1. **Disable at source (automatic, every load).**
   Empties Precision Farming's `tramlineMap.npcFieldFruitTypes` table, which gates which
   fruit types get tramlines on NPC/AI fields. Result: no *new* NPC tramlines, on any map,
   without any action.

2. **Contract-field reset (automatic).**
   Appends `AbstractMission:finishedPreparing()` and sweeps missions on load, resetting
   tramlines on fertilize / spray-herbicide / hoe / weed contract fields.

3. **Mass clear of already-baked tramlines (console, one-time per map).**
   Console command **`samAutoTramlineSweep`** loops every unowned farmland
   (`farmland.farmId == FarmlandManager.NO_OWNER_FARM_ID`) and resets its tramlines.
   This is intentionally **not** run at load (re-running the per-field foliage rebuild
   every load causes a load-time stutter, and it fires too early there to work).

## Per-map workflow (do once, then that map stays clean forever)

1. Load the map → open the console → run `samAutoTramlineSweep`
2. **Save + fully restart FS.** The crop refill only becomes visible after save + restart;
   a plain "return to menu → reload savegame" is not enough.
3. Done. New tramlines are prevented automatically from then on (lever 1).

## Notes

- **Credit / blueprint:** the Precision Farming tramline API was learned from
  BayernGamers' *Adjust Tramlines For Missions* (ModHub 351451), used as a readable
  reference only — no code copied (its licence is No-Derivatives). This mod calls
  Precision Farming's own API directly, so BayernGamers' mod is not required and can be
  removed. (Lever 1 also suppresses that mod's accept-time dialog, since it reads the same
  `npcFieldFruitTypes` table.)
- **Multiplayer:** single-player correct; MP clients are not separately synced in this version.
- Deeper API notes and rationale: see `../../docs/learned.md` → "Precision Farming / tramlines".

## Files

- `modDesc.xml` — descVersion 108, dependency on `FS25_precisionFarming`.
- `register.lua` — sources the script.
- `scripts/AutoTramlineOff.lua` — all logic (levers, hooks, console command).
EOF
