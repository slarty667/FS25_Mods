#!/usr/bin/env python3
"""fsmods - a per-savegame mod-set manager for Farming Simulator 25 on macOS.

Problem this solves
-------------------
FS25 uses a single global mods folder, but binds the *active* mod selection to
each savegame individually (stored in ``<savegame>/careerSavegame.xml`` as
``<mod modName=.../>`` entries). Managing "function mods everywhere" plus
"asset mods only in specific saves" by hand is unworkable once you have a few
hundred mods and a dozen saves.

Architecture
------------
* A central **library** directory holds every mod (zip or unpacked folder).
* A declarative **profiles.toml** defines a ``[global]`` set (function mods,
  always active), reusable ``[sets.*]`` (asset bundles) and ``[profiles.*]``
  (global + chosen sets, optionally mapped to a savegame).
* ``use <profile>`` materialises the active mods folder as a **symlink farm**:
  it links exactly ``global + sets`` from the library into the game's mods
  folder. The game then only ever sees the relevant subset.

Safety (Asimov: no data loss through sloppiness)
-----------------------------------------------
* ``use`` only ever removes symlinks that resolve *into the library* (or a
  configured external path). Real files/folders and foreign symlinks are never
  touched - they are reported, not deleted.
* ``migrate`` *moves* loose zips into the library (reversible) and writes a
  manifest; it never deletes.
* ``--dry-run`` is available on every mutating command.

Run with Python >= 3.11 (needs ``tomllib``). Use the bundled ``fsmods``
wrapper, which locates a suitable interpreter automatically.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import shutil
import sys
try:
    import tomllib  # Python >= 3.11
except ModuleNotFoundError:  # pragma: no cover - fallback for 3.10 with tomli
    import tomli as tomllib  # type: ignore
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_CONFIG = Path(__file__).resolve().parent / "profiles.toml"


# --------------------------------------------------------------------------- #
# Config model
# --------------------------------------------------------------------------- #
@dataclass
class Config:
    """Resolved fsmods configuration."""

    config_path: Path
    library: Path
    mods_folder: Path
    savegames_dir: Path
    global_mods: list[str] = field(default_factory=list)
    sets: dict[str, list[str]] = field(default_factory=dict)
    profiles: dict[str, dict] = field(default_factory=dict)
    external: dict[str, Path] = field(default_factory=dict)

    @classmethod
    def load(cls, config_path: Path) -> "Config":
        """Load and resolve a profiles.toml file."""
        if not config_path.exists():
            sys.exit(
                f"Config not found: {config_path}\n"
                f"Run 'fsmods scan' first to generate one from your savegames."
            )
        with config_path.open("rb") as fh:
            data = tomllib.load(fh)

        paths = data.get("paths", {})
        mods_folder = _expand(paths.get("mods_folder", _default_mods_folder()))
        library = _expand(paths.get("library", "~/FS25_ModLibrary"))
        savegames_dir = _expand(paths.get("savegames", str(mods_folder.parent)))

        external = {k: _expand(v) for k, v in data.get("external", {}).items()}

        return cls(
            config_path=config_path,
            library=library,
            mods_folder=mods_folder,
            savegames_dir=savegames_dir,
            global_mods=list(data.get("global", {}).get("mods", [])),
            sets={k: list(v.get("mods", [])) for k, v in data.get("sets", {}).items()},
            profiles=dict(data.get("profiles", {})),
            external=external,
        )

    def resolve_profile(self, name: str) -> list[str]:
        """Return the full, de-duplicated mod list for a profile.

        Accepts a profile name or a savegame name (e.g. ``savegame3``); the
        latter is matched against each profile's ``savegame`` key.
        """
        prof = self.profiles.get(name)
        if prof is None:  # maybe a savegame name -> find the profile mapped to it
            for pname, pdata in self.profiles.items():
                if pdata.get("savegame") == name:
                    prof, name = pdata, pname
                    break
        if prof is None:
            sys.exit(f"Unknown profile or savegame: {name}\n{self._profiles_hint()}")

        mods: list[str] = list(self.global_mods)
        for set_name in prof.get("sets", []):
            if set_name not in self.sets:
                sys.exit(f"Profile '{name}' references unknown set '{set_name}'.")
            mods.extend(self.sets[set_name])
        mods.extend(prof.get("mods", []))  # optional inline extras
        return _dedup(mods)

    def _profiles_hint(self) -> str:
        if not self.profiles:
            return "No profiles defined yet."
        lines = ["Available profiles:"]
        for pname, pdata in sorted(self.profiles.items()):
            sg = pdata.get("savegame", "-")
            lines.append(f"  {pname:24} (savegame: {sg})")
        return "\n".join(lines)


# --------------------------------------------------------------------------- #
# Library lookup
# --------------------------------------------------------------------------- #
def find_source(cfg: Config, mod_name: str) -> Path | None:
    """Locate a mod in the library or external paths. Returns its path or None."""
    if mod_name in cfg.external:
        p = cfg.external[mod_name]
        return p if p.exists() else None
    zip_path = cfg.library / f"{mod_name}.zip"
    if zip_path.exists():
        return zip_path
    dir_path = cfg.library / mod_name
    if dir_path.is_dir():
        return dir_path
    return None


def managed_roots(cfg: Config) -> list[Path]:
    """Directories whose contents fsmods considers 'its own' symlink targets."""
    roots = [cfg.library.resolve()]
    for p in cfg.external.values():
        roots.append(p.resolve().parent)
    return roots


def is_managed_symlink(cfg: Config, entry: Path) -> bool:
    """True if entry is a symlink resolving into a managed root."""
    if not entry.is_symlink():
        return False
    try:
        target = entry.resolve()
    except OSError:
        return False
    return any(_is_within(target, root) for root in managed_roots(cfg))


# --------------------------------------------------------------------------- #
# Savegame parsing
# --------------------------------------------------------------------------- #
def read_savegame_mods(savegames_dir: Path) -> dict[str, dict]:
    """Parse all careerSavegame.xml files. Returns {savegame: {map, mods}}."""
    result: dict[str, dict] = {}
    if not savegames_dir.exists():
        return result
    for sg in sorted(savegames_dir.glob("savegame*")):
        if sg.name == "savegameBackup" or not sg.is_dir():
            continue
        career = sg / "careerSavegame.xml"
        if not career.exists():
            continue
        try:
            root = ET.parse(career).getroot()
        except ET.ParseError:
            continue
        mods = {m.get("modName") for m in root.findall("mod") if m.get("modName")}
        result[sg.name] = {
            "map": root.findtext("settings/mapTitle") or "Unknown",
            "mods": mods,
        }
    return result


def installed_mods(cfg: Config) -> set[str]:
    """Mod names available in the library (zips + folders) and external paths."""
    names: set[str] = set(cfg.external.keys())
    if cfg.library.exists():
        for item in cfg.library.iterdir():
            if item.name.startswith("."):
                continue
            if item.is_file() and item.suffix.lower() == ".zip":
                names.add(item.stem)
            elif item.is_dir():
                names.add(item.name)
    return names


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def materialize(src: Path, dest: Path) -> str:
    """Create `dest` from `src`.

    Folders are symlinked (FS follows directory symlinks fine). Zips are
    **hardlinked** — FS25 does NOT recognise a *symlinked* zip (it tries to read
    it as an unpacked folder and fails), but a hardlink is indistinguishable
    from a real file. Falls back to a copy across volumes (hardlinks are
    same-filesystem only).
    """
    if src.is_dir():
        dest.symlink_to(src)
        return "symlink"
    try:
        os.link(src, dest)  # hardlink: instant, no extra space on the same APFS volume
        return "hardlink"
    except OSError:
        shutil.copy2(src, dest)
        return "copy"


def cmd_use(cfg: Config, args: argparse.Namespace) -> int:
    """Materialise the mods folder for a profile (hardlinks for zips)."""
    target_name = _profile_name(cfg, args.profile)

    # Switch-time auto-sync: when switching AWAY from another profile, first re-derive
    # that outgoing profile's set from its savegame, so an in-game mod trim is captured
    # automatically (no separate `sync` to remember). Only on a real switch, and only
    # when not in dry-run / --no-sync.
    last = load_last_profile(cfg)
    if last and last != target_name and not args.no_sync and not args.dry_run:
        note = _auto_sync_outgoing(cfg, last)
        if note:
            print(note)

    all_targets = cfg.resolve_profile(args.profile)
    dlc = [n for n in all_targets if _is_dlc(n)]
    targets = [n for n in all_targets if not _is_dlc(n)]
    cfg.mods_folder.mkdir(parents=True, exist_ok=True)

    prior = set(load_state(cfg))  # basenames fsmods created on the last run

    # 1. Inventory. Removable = what we made before (state) OR leftover managed
    #    symlinks from the old symlink-farm approach. Everything else is sacred.
    to_remove: list[Path] = []
    foreign: list[Path] = []
    real_files: list[Path] = []
    for entry in cfg.mods_folder.iterdir():
        if entry.name.startswith("."):
            continue
        if entry.name in prior or is_managed_symlink(cfg, entry):
            to_remove.append(entry)
        elif entry.is_symlink():
            foreign.append(entry)
        else:
            real_files.append(entry)

    # 2. Resolve sources; collect what is missing from the library.
    resolved: dict[str, Path] = {}
    missing: list[str] = []
    for name in targets:
        src = find_source(cfg, name)
        (resolved.__setitem__(name, src) if src else missing.append(name))

    print(f"Profile '{args.profile}': {len(targets)} mods "
          f"({len(cfg.global_mods)} global + sets)")
    print(f"  library: {cfg.library}")
    print(f"  active : {cfg.mods_folder}")
    print(f"  will remove {len(to_remove)} managed entr(ies), "
          f"create {len(resolved)} (hardlink zips / symlink folders)")
    if missing:
        print(f"  WARNING: {len(missing)} mod(s) not found in library: "
              f"{', '.join(sorted(missing))}")
    if dlc:
        print(f"  NOTE: {len(dlc)} DLC entr(ies) skipped (game-managed): "
              f"{', '.join(sorted(dlc))}")
    if foreign:
        print(f"  NOTE: {len(foreign)} foreign symlink(s) left untouched: "
              f"{', '.join(p.name for p in foreign)}")
    if real_files:
        print(f"  NOTE: {len(real_files)} unmanaged real file(s)/folder(s) "
              f"left untouched (e.g. *.disabled).")

    if args.dry_run:
        print("  [dry-run] nothing changed.")
        return 0

    # 3. Apply: clear what we manage, then materialise the wanted set fresh.
    for entry in to_remove:
        entry.unlink()

    created: dict[str, int] = {"hardlink": 0, "symlink": 0, "copy": 0}
    new_state: list[str] = []
    for name, src in resolved.items():
        dest_name = f"{name}.zip" if src.suffix.lower() == ".zip" else name
        dest = cfg.mods_folder / dest_name
        if dest.exists() or dest.is_symlink():
            print(f"  SKIP {dest_name}: an unmanaged entry is in the way.")
            continue
        method = materialize(src, dest)
        created[method] += 1
        new_state.append(dest_name)

    save_state(cfg, new_state, profile=target_name)
    print(f"  done: removed {len(to_remove)}, created {sum(created.values())} "
          f"(hardlink {created['hardlink']}, symlink {created['symlink']}, "
          f"copy {created['copy']}).")
    return 0


def cmd_status(cfg: Config, args: argparse.Namespace) -> int:
    """Show what is currently materialised and which profile it matches."""
    if not cfg.mods_folder.exists():
        print(f"Mods folder does not exist: {cfg.mods_folder}")
        return 1
    state = set(load_state(cfg))
    managed, foreign, real = [], [], []
    for entry in cfg.mods_folder.iterdir():
        if entry.name.startswith("."):
            continue
        if entry.name in state or is_managed_symlink(cfg, entry):
            managed.append(entry.name[:-4] if entry.name.endswith(".zip") else entry.name)
        elif entry.is_symlink():
            foreign.append(entry.name)
        else:
            real.append(entry.name)

    print(f"Active mods folder: {cfg.mods_folder}")
    print(f"  managed (fsmods) : {len(managed)}")
    print(f"  foreign symlinks : {len(foreign)}")
    print(f"  unmanaged real   : {len(real)}")

    active = set(managed)
    matches = [
        name for name in cfg.profiles
        if linkable_names(cfg, name) == active
    ]
    if matches:
        print(f"  matches profile  : {', '.join(matches)}")
    elif active:
        print("  matches profile  : none exactly")
    return 0


def _read_state(cfg: Config) -> dict:
    p = cfg.config_path.parent / ".fsmods_state.json"
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except (ValueError, OSError):
        return {}


def load_state(cfg: Config) -> list[str]:
    """Basenames fsmods materialised for this mods_folder on the last `use`."""
    entry = _read_state(cfg).get(str(cfg.mods_folder))
    if isinstance(entry, dict):
        return entry.get("managed", [])
    if isinstance(entry, list):  # legacy format
        return entry
    return []


def load_last_profile(cfg: Config) -> str | None:
    """The profile name materialised by the last `use` for this mods_folder."""
    entry = _read_state(cfg).get(str(cfg.mods_folder))
    return entry.get("profile") if isinstance(entry, dict) else None


def save_state(cfg: Config, names: list[str], profile: str | None = None) -> None:
    p = cfg.config_path.parent / ".fsmods_state.json"
    data = _read_state(cfg)
    prev = data.get(str(cfg.mods_folder))
    if profile is None and isinstance(prev, dict):
        profile = prev.get("profile")
    data[str(cfg.mods_folder)] = {"managed": sorted(names), "profile": profile}
    p.write_text(json.dumps(data, indent=2))


def _profile_name(cfg: Config, key: str) -> str:
    """Canonical profile name for a profile name or a savegame name."""
    if key in cfg.profiles:
        return key
    for pname, pdata in cfg.profiles.items():
        if pdata.get("savegame") == key:
            return pname
    return key


def _auto_sync_outgoing(cfg: Config, profile_name: str) -> str | None:
    """Best-effort: before switching away, re-derive the OUTGOING profile's set from
    its savegame so an in-game mod trim is preserved. Never raises; returns a note."""
    try:
        prof = cfg.profiles.get(profile_name)
        if prof is None:
            return None
        savegame = prof.get("savegame")
        sets = list(prof.get("sets", []))
        if not savegame or len(sets) != 1 or sets[0] not in cfg.sets:
            return None  # ambiguous/none -> skip silently
        target_set = sets[0]
        info = read_savegame_mods(cfg.savegames_dir).get(savegame)
        if not info:
            return None
        new_mods = sorted(info["mods"] - set(cfg.global_mods))
        old = cfg.sets[target_set]
        if set(new_mods) == set(old):
            return f"  auto-sync {profile_name}: set [{target_set}] unverändert ({len(old)})"
        cfg.config_path.write_text(
            _replace_array(cfg.config_path.read_text(), f"[sets.{target_set}]", new_mods))
        cfg.sets[target_set] = new_mods
        added = len(set(new_mods) - set(old))
        removed = len(set(old) - set(new_mods))
        return (f"  auto-sync {profile_name}: set [{target_set}] {len(old)} -> "
                f"{len(new_mods)} (+{added} / -{removed})")
    except Exception as exc:  # noqa: BLE001 - best-effort, must not break a switch
        return f"  auto-sync {profile_name}: übersprungen ({exc})"


def cmd_list(cfg: Config, args: argparse.Namespace) -> int:
    """List global mods, sets and profiles."""
    print(f"global: {len(cfg.global_mods)} function mod(s)")
    print(f"\nsets ({len(cfg.sets)}):")
    for name, mods in sorted(cfg.sets.items()):
        print(f"  {name:28} {len(mods)} mod(s)")
    print(f"\nprofiles ({len(cfg.profiles)}):")
    for name, pdata in sorted(cfg.profiles.items()):
        total = len(cfg.resolve_profile(name))
        sg = pdata.get("savegame", "-")
        sets = ", ".join(pdata.get("sets", [])) or "-"
        print(f"  {name:28} {total:4} mods  savegame={sg:12} sets=[{sets}]")
    return 0


def cmd_doctor(cfg: Config, args: argparse.Namespace) -> int:
    """Report mods referenced by saves but missing, and library mods unused."""
    saves = read_savegame_mods(cfg.savegames_dir)
    have = installed_mods(cfg)
    used: set[str] = set()
    print(f"Savegames: {len(saves)} | library mods: {len(have)}\n")
    for sg, info in saves.items():
        used |= info["mods"]
        miss = info["mods"] - have
        flag = f"  MISSING {len(miss)}" if miss else ""
        print(f"  {sg:12} {info['map']:28} {len(info['mods']):4} mods{flag}")
        if miss and args.verbose:
            for m in sorted(miss):
                print(f"        - {m}")

    missing = used - have
    unused = have - used
    print(f"\nReferenced by saves: {len(used)}")
    print(f"Missing from library: {len(missing)}")
    print(f"Unused in any save  : {len(unused)}")
    if args.verbose and unused:
        print("\nUnused library mods:")
        for m in sorted(unused):
            print(f"  - {m}")
    return 0


def cmd_migrate(cfg: Config, args: argparse.Namespace) -> int:
    """Move loose *.zip files from the active mods folder into the library."""
    if not cfg.mods_folder.exists():
        sys.exit(f"Mods folder does not exist: {cfg.mods_folder}")
    cfg.library.mkdir(parents=True, exist_ok=True)

    moves: list[tuple[Path, Path]] = []
    for entry in cfg.mods_folder.iterdir():
        if entry.is_file() and entry.suffix.lower() == ".zip" and not entry.is_symlink():
            dest = cfg.library / entry.name
            moves.append((entry, dest))

    print(f"Migrate: {len(moves)} loose zip(s) "
          f"{cfg.mods_folder} -> {cfg.library}")
    collisions = [(s, d) for s, d in moves if d.exists()]
    if collisions:
        print(f"  {len(collisions)} already in library (will be skipped): "
              f"{', '.join(s.name for s, _ in collisions)}")
    moves = [(s, d) for s, d in moves if not d.exists()]

    if args.dry_run:
        for s, _ in moves[:20]:
            print(f"  [dry-run] move {s.name}")
        if len(moves) > 20:
            print(f"  [dry-run] ... and {len(moves) - 20} more")
        return 0
    if not args.yes:
        sys.exit("Refusing to move files without --yes (or use --dry-run).")

    manifest = cfg.library / f"_fsmods_migrate_{_timestamp()}.log"
    with manifest.open("w") as log:
        log.write(f"# fsmods migrate {_dt.datetime.now()}\n")
        for src, dest in moves:
            shutil.move(str(src), str(dest))
            log.write(f"{dest}\t<-\t{src}\n")
    print(f"  moved {len(moves)} zip(s). Manifest: {manifest}")
    return 0


def cmd_sync(cfg: Config, args: argparse.Namespace) -> int:
    """Re-derive a profile's set from its savegame's current careerSavegame.xml.

    Use after trimming a save's active mods in-game: the save file is the source
    of truth. Rewrites ONLY that profile's [sets.*] block in profiles.toml; the
    rest of the file (global, external, other sets) is preserved verbatim.
    """
    prof = cfg.profiles.get(args.profile)
    name = args.profile
    if prof is None:
        for pname, pdata in cfg.profiles.items():
            if pdata.get("savegame") == args.profile:
                prof, name = pdata, pname
                break
    if prof is None:
        sys.exit(f"Unknown profile or savegame: {args.profile}")
    savegame = prof.get("savegame")
    if not savegame:
        sys.exit(f"Profile '{name}' has no 'savegame' to sync from.")
    sets = list(prof.get("sets", []))
    target_set = args.set or (sets[0] if len(sets) == 1 else None)
    if target_set is None:
        sys.exit(f"Profile '{name}' references {len(sets)} sets; pass --set <name>.")
    if target_set not in cfg.sets:
        sys.exit(f"Unknown set '{target_set}'.")

    saves = read_savegame_mods(cfg.savegames_dir)
    info = saves.get(savegame)
    if not info:
        sys.exit(f"No careerSavegame.xml found for {savegame}.")
    new_mods = sorted(info["mods"] - set(cfg.global_mods))
    old_mods = cfg.sets[target_set]
    added = sorted(set(new_mods) - set(old_mods))
    removed = sorted(set(old_mods) - set(new_mods))

    print(f"sync {name} (savegame {savegame}) -> set [{target_set}]")
    print(f"  save references {len(info['mods'])} mods ({len(cfg.global_mods)} global)")
    print(f"  set: {len(old_mods)} -> {len(new_mods)}  (+{len(added)} / -{len(removed)})")
    if removed:
        print(f"  removed: {', '.join(removed[:25])}{' …' if len(removed) > 25 else ''}")
    if added:
        print(f"  added:   {', '.join(added[:25])}{' …' if len(added) > 25 else ''}")

    if args.dry_run:
        print("  [dry-run] profiles.toml not changed.")
        return 0
    new_text = _replace_array(cfg.config_path.read_text(), f"[sets.{target_set}]", new_mods)
    cfg.config_path.write_text(new_text)
    print(f"  updated {cfg.config_path}")
    return 0


def cmd_adopt(cfg: Config, args: argparse.Namespace) -> int:
    """Adopt a freshly downloaded mod: move its zip into the library and add the mod
    to a set (or global). Use after downloading a mod outside the game.

    The physical `use` (hardlink into the active folder) stays a separate step so it
    only runs when the game is closed.
    """
    src = Path(os.path.expanduser(args.zip))
    if src.suffix.lower() == ".zip" and src.exists():
        mod_name = src.stem
        dest = cfg.library / src.name
        if dest.exists():
            moved = "already in library"
        else:
            cfg.library.mkdir(parents=True, exist_ok=True)
            if not args.dry_run:
                shutil.move(str(src), str(dest))
            moved = f"moved {src} -> {dest}"
    else:
        mod_name = src.name  # treat the arg as a mod name already in the library
        if find_source(cfg, mod_name) is None:
            sys.exit(f"Not a .zip path and not found in library: {args.zip}")
        moved = "already in library"

    if args.global_:
        header, current, label = "[global]", cfg.global_mods, "global"
    else:
        if not args.set:
            sys.exit("Pass --set <name> or --global.")
        if args.set not in cfg.sets:
            sys.exit(f"Unknown set '{args.set}'.")
        header, current, label = f"[sets.{args.set}]", cfg.sets[args.set], f"set [{args.set}]"

    print(f"adopt {mod_name}")
    print(f"  library: {moved}")
    if mod_name in current:
        print(f"  {mod_name} already in {label} — nothing to add.")
        return 0
    new_mods = sorted(set(current) | {mod_name})
    if args.dry_run:
        print(f"  [dry-run] would add {mod_name} to {label}.")
        return 0
    cfg.config_path.write_text(
        _replace_array(cfg.config_path.read_text(), header, new_mods))
    print(f"  added to {label}.")
    hint = ("a profile that uses it" if not args.global_ else "the profile you play")
    print(f"  next (game closed): fsmods use <{hint}>, then activate it once in the "
          f"in-game mod screen.")
    return 0


def cmd_scan(cfg_path: Path, args: argparse.Namespace) -> int:
    """Bootstrap a profiles.toml from the current savegames.

    Heuristic: mods present in >= ``min_saves`` (default: all) become global
    function mods; each save's remaining mods become a per-save set + profile.
    """
    mods_folder = _expand(args.mods_folder) if args.mods_folder else _default_mods_folder()
    savegames_dir = _expand(args.savegames) if args.savegames else mods_folder.parent
    library = _expand(args.library)

    saves = read_savegame_mods(savegames_dir)
    if not saves:
        sys.exit(f"No savegames found under {savegames_dir}")

    counts: dict[str, int] = {}
    for info in saves.values():
        for m in info["mods"]:
            counts[m] = counts.get(m, 0) + 1
    threshold = args.min_saves if args.min_saves else len(saves)
    global_mods = sorted(m for m, c in counts.items() if c >= threshold)

    text = _emit_toml(library, mods_folder, savegames_dir, global_mods, saves)

    out = _expand(args.out) if args.out else cfg_path
    print(f"Scanned {len(saves)} saves; {len(global_mods)} global mods "
          f"(in >= {threshold} saves).")
    if args.print or not args.write:
        print("\n" + text)
    if args.write:
        if out.exists() and not args.force:
            sys.exit(f"{out} exists. Re-run with --force to overwrite, "
                     f"or --out to write elsewhere.")
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text)
        print(f"\nWrote {out}")
    else:
        print("\n(not written; add --write to save, --out to choose a path)")
    return 0


# --------------------------------------------------------------------------- #
# TOML emitter (tomllib is read-only; we control the schema)
# --------------------------------------------------------------------------- #
def _emit_toml(
    library: Path,
    mods_folder: Path,
    savegames_dir: Path,
    global_mods: list[str],
    saves: dict[str, dict],
) -> str:
    def arr(mods) -> str:
        if not mods:
            return "[]"
        body = ",\n".join(f'    "{m}"' for m in sorted(mods))
        return "[\n" + body + ",\n]"

    lines = [
        "# fsmods configuration - generated by 'fsmods scan'.",
        "# Curate freely: extract shared asset bundles into their own [sets.*],",
        "# rename profiles, etc. Re-running 'scan' will not overwrite this file",
        "# unless you pass --force.",
        "",
        "[paths]",
        f'library = "{_tilde(library)}"',
        f'mods_folder = "{_tilde(mods_folder)}"',
        f'savegames = "{_tilde(savegames_dir)}"',
        "",
        "# Function mods: linked into EVERY profile. Add a new one here once and",
        "# it lands in all profiles on the next 'fsmods use'.",
        "[global]",
        f"mods = {arr(global_mods)}",
        "",
        "# Map repo dev mods (or any path outside the library) to a name so they",
        "# can be referenced from global/sets. Example:",
        '# [external]',
        '# FS25_HoldToSteer = "~/Dropbox/htdocs/FS25_Mods/mods/FS25_HoldToSteer"',
        "",
    ]

    slugs = _unique_slugs(saves)
    global_set = set(global_mods)
    lines.append("# --- Per-save asset sets (save's mods minus global) ---")
    for sg, info in saves.items():
        asset = sorted(info["mods"] - global_set)
        lines.append("")
        lines.append(f'[sets.{slugs[sg]}]  # {info["map"]} ({sg})')
        lines.append(f"mods = {arr(asset)}")

    lines.append("")
    lines.append("# --- Profiles: global + chosen sets, mapped to a savegame ---")
    for sg, info in saves.items():
        lines.append("")
        lines.append(f"[profiles.{slugs[sg]}]  # {info['map']}")
        lines.append(f'savegame = "{sg}"')
        lines.append(f'sets = ["{slugs[sg]}"]')

    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def _expand(p: str | Path) -> Path:
    return Path(os.path.expanduser(str(p)))


def _tilde(p: Path) -> str:
    home = str(Path.home())
    s = str(p)
    return "~" + s[len(home):] if s.startswith(home) else s


def _default_mods_folder() -> Path:
    return _expand("~/Library/Application Support/FarmingSimulator2025/mods")


def _dedup(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for it in items:
        if it not in seen:
            seen.add(it)
            out.append(it)
    return out


def _is_dlc(name: str) -> bool:
    """DLC entries (pdlc_*) are managed by the game/launcher, not the mods folder."""
    return name.startswith("pdlc_")


def linkable_names(cfg: Config, profile_name: str) -> set[str]:
    """Names a profile would actually link: resolvable, non-DLC mods."""
    names: set[str] = set()
    for n in cfg.resolve_profile(profile_name):
        if _is_dlc(n):
            continue
        if find_source(cfg, n) is not None:
            names.add(n)
    return names


def _replace_array(text: str, header: str, mods: list[str]) -> str:
    """Replace the `mods = [...]` array under a given table `header` (e.g.
    "[sets.helden]" or "[global]") in TOML text, keeping the header (and its inline
    comment) and the rest of the file verbatim."""
    lines = text.split("\n")
    hdr = None
    for i, line in enumerate(lines):
        head = line.split("#", 1)[0].strip()
        if head == header:
            hdr = i
            break
    if hdr is None:
        raise ValueError(f"{header} not found in config")
    j = hdr + 1
    while j < len(lines) and not lines[j].lstrip().startswith("mods"):
        j += 1
    if j >= len(lines):
        raise ValueError(f"mods array for {header} not found")
    if lines[j].rstrip().endswith("]"):
        k = j  # single-line array, e.g. `mods = []`
    else:
        k = j + 1
        while k < len(lines) and lines[k].strip() != "]":
            k += 1
    if not mods:
        arr = ["mods = []"]
    else:
        arr = ["mods = ["] + [f'    "{m}",' for m in mods] + ["]"]
    return "\n".join(lines[:j] + arr + lines[k + 1:])


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _slug(map_title: str, fallback: str) -> str:
    # TOML bare keys allow only [A-Za-z0-9_-]; keep ASCII alnum, rest -> '_'.
    keep = [c.lower() if (c.isascii() and c.isalnum()) else "_" for c in map_title]
    s = "".join(keep).strip("_")
    while "__" in s:
        s = s.replace("__", "_")
    return s or fallback


def _unique_slugs(saves: dict[str, dict]) -> dict[str, str]:
    """Map each savegame to a unique slug, disambiguating collisions."""
    out: dict[str, str] = {}
    used: set[str] = set()
    for sg, info in saves.items():
        base = _slug(info["map"], sg)
        slug = base
        n = 2
        while slug in used:
            slug = f"{base}_{n}"
            n += 1
        used.add(slug)
        out[sg] = slug
    return out


def _timestamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d_%H%M%S")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="fsmods",
        description="Per-savegame mod-set manager for Farming Simulator 25 (macOS).",
    )
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG,
                   help=f"Path to profiles.toml (default: {DEFAULT_CONFIG})")
    sub = p.add_subparsers(dest="command", required=True)

    sp = sub.add_parser("use", help="Link a profile's mods into the game folder.")
    sp.add_argument("profile", help="Profile name or savegame (e.g. savegame3).")
    sp.add_argument("--dry-run", action="store_true")
    sp.add_argument("--no-sync", action="store_true",
                    help="Don't auto-sync the outgoing profile's set from its savegame.")

    sub.add_parser("status", help="Show what is currently linked.")
    sub.add_parser("list", help="List global mods, sets and profiles.")

    dp = sub.add_parser("doctor", help="Report missing/unused mods.")
    dp.add_argument("-v", "--verbose", action="store_true")

    mp = sub.add_parser("migrate", help="Move loose zips into the library.")
    mp.add_argument("--yes", action="store_true", help="Actually move files.")
    mp.add_argument("--dry-run", action="store_true")

    syp = sub.add_parser("sync", help="Re-derive a profile's set from its savegame.")
    syp.add_argument("profile", help="Profile name or savegameN.")
    syp.add_argument("--set", default=None, help="Target set (if the profile has several).")
    syp.add_argument("--dry-run", action="store_true")

    ap = sub.add_parser("adopt", help="Move a downloaded zip into the library + add to a set.")
    ap.add_argument("zip", help="Path to the .zip (or a mod name already in the library).")
    grp = ap.add_mutually_exclusive_group(required=True)
    grp.add_argument("--set", default=None, help="Add the mod to this set.")
    grp.add_argument("--global", dest="global_", action="store_true",
                     help="Add the mod to the global (function-mod) set.")
    ap.add_argument("--dry-run", action="store_true")

    cp = sub.add_parser("scan", help="Bootstrap profiles.toml from savegames.")
    cp.add_argument("--library", default="~/FS25_ModLibrary")
    cp.add_argument("--mods-folder", default=None)
    cp.add_argument("--savegames", default=None)
    cp.add_argument("--min-saves", type=int, default=0,
                    help="Global threshold (default: present in ALL saves).")
    cp.add_argument("--out", default=None, help="Output path.")
    cp.add_argument("--write", action="store_true", help="Write the file.")
    cp.add_argument("--force", action="store_true", help="Overwrite existing.")
    cp.add_argument("--print", action="store_true", help="Print even when writing.")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "scan":
        return cmd_scan(args.config, args)

    cfg = Config.load(args.config)
    return {
        "use": cmd_use,
        "status": cmd_status,
        "list": cmd_list,
        "doctor": cmd_doctor,
        "migrate": cmd_migrate,
        "sync": cmd_sync,
        "adopt": cmd_adopt,
    }[args.command](cfg, args)


if __name__ == "__main__":
    sys.exit(main())
