#!/usr/bin/env python3
"""
check_forks.py -- health check for our personal FS25 mod forks.

We patch several third-party mods (idempotent scripts in this folder, each leaving a
"-- [SAM patch] ..." marker in the mod's Lua). Third-party mods can be replaced WITHOUT
us noticing:
  * ModHub auto-update on game start -> the fresh upstream zip overwrites the active file
    and our patches are gone (silent regression), or
  * a manual re-download.

This script detects both. For every fork it checks whether ALL expected markers are still
present in:
  * the LIBRARY zip (~/FS25_ModLibrary) -- our patched single source of truth, and
  * the ACTIVE mods-folder zip -- what the game actually loads (only when that mod is in
    the currently active set),
and reads each modDesc version so we spot an upstream version bump before it bites.

No network, read-only -- safe to run any time, even while FS is running.
Exit code 0 = all forks intact, 1 = at least one needs attention.

Usage:  python3 check_forks.py
"""

import os
import re
import sys
import zipfile

LIBRARY = os.path.expanduser("~/FS25_ModLibrary")
ACTIVE = os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods")

# Mod zip base name (without .zip) -> required markers + a human note on the upstream source.
# Markers are substrings that MUST appear somewhere in the mod's Lua once our patch is applied.
FORKS = {
    "FS25_woodChipsMission": {
        "markers": [
            "reload-safe match",
            "keep saved target",
            "multi-mission split",
            "proximity by the mission",
            "trust own resolved station",
            "no proximity",
        ],
        "source": "htModding - NOT on ModHub (manual updates only)",
        "reapply": "re-run patch_woodchips_*.py --apply (all 5), then fsmods use <profile>",
    },
    "FS25_FieldsOfStories": {
        "markers": ["neighborhood tolerance"],
        "source": "AirFoxTwo - NOT on ModHub (manual updates only)",
        "reapply": "re-run patch_fos_probe_neighborhood.py --apply, then fsmods use <profile>",
    },
    "FS25_AdditionalContracts": {
        "markers": ["keep recovered cargo for the player"],
        "source": "ModHub? - auto-update risk (verify)",
        "reapply": "re-run patch_lostcargo_mod.py --apply, then fsmods use <profile>",
    },
}


def zip_text(path):
    """Concatenate all Lua/XML members of a zip for marker scanning. None if unreadable."""
    try:
        parts = []
        with zipfile.ZipFile(path) as z:
            for name in z.namelist():
                if name.endswith((".lua", ".xml")):
                    try:
                        parts.append(z.read(name).decode("utf-8", "ignore"))
                    except Exception:
                        pass
        return "\n".join(parts)
    except Exception:
        return None


def mod_version(path):
    """Read <version> from modDesc.xml, or a placeholder."""
    try:
        with zipfile.ZipFile(path) as z:
            md = z.read("modDesc.xml").decode("utf-8", "ignore")
        m = re.search(r"<version>\s*([^<\s]+)\s*</version>", md)
        return m.group(1) if m else "?"
    except Exception:
        return "n/a"


def scan(path, markers):
    """Return (state, missing_markers). state in {ok, DEGRADED, unreadable, absent}."""
    if not os.path.isfile(path):
        return "absent", []
    text = zip_text(path)
    if text is None:
        return "unreadable", list(markers)
    missing = [mk for mk in markers if mk not in text]
    return ("ok" if not missing else "DEGRADED"), missing


def main():
    needs_attention = False
    print("FS25 mod-fork integrity check")
    print("=" * 60)
    for mod, spec in FORKS.items():
        lib_zip = os.path.join(LIBRARY, mod + ".zip")
        act_zip = os.path.join(ACTIVE, mod + ".zip")
        lib_state, lib_missing = scan(lib_zip, spec["markers"])
        act_state, act_missing = scan(act_zip, spec["markers"])
        lib_v = mod_version(lib_zip)
        act_v = mod_version(act_zip) if os.path.isfile(act_zip) else None

        print("\n### %s" % mod)
        print("    source : %s" % spec["source"])
        print("    library: %-9s v%-10s %s"
              % (lib_state, lib_v, ("MISSING " + str(lib_missing)) if lib_missing else ""))
        if act_state == "absent":
            print("    active : (not in the currently active set)")
        else:
            print("    active : %-9s v%-10s %s"
                  % (act_state, act_v, ("MISSING " + str(act_missing)) if act_missing else ""))

        # Verdicts
        if lib_state in ("DEGRADED", "unreadable"):
            needs_attention = True
            print("    >> LIBRARY patch missing/broken -> %s" % spec["reapply"])
        if act_state == "DEGRADED":
            needs_attention = True
            print("    >> ACTIVE is unpatched (game runs upstream). If lib is OK: fsmods use <profile>.")
        if act_v is not None and lib_v not in ("n/a", "?") and act_v not in ("n/a", "?") and act_v != lib_v:
            needs_attention = True
            print("    >> VERSION DRIFT: library v%s != active v%s -> upstream UPDATE." % (lib_v, act_v))
            print("       Re-fork: mirror the new zip, re-apply the patch scripts, then relink.")

    print("\n" + "=" * 60)
    print("RESULT: " + ("SOME FORKS NEED ATTENTION (see >> above)" if needs_attention else "all forks intact"))
    sys.exit(1 if needs_attention else 0)


if __name__ == "__main__":
    main()
