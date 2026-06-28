#!/usr/bin/env python3
"""
fix_lostcargo_pallets.py

One-shot cleanup for FS25 "Lost cargo" (FS25_AdditionalContracts) reward pallets
that get stuck as un-sellable orphans.

Root cause: LostCargoMission.lua's deleteObject() has dead-code ownership logic,
so a recovered-cargo pallet from a FINISHED/SUCCESS mission is neither deleted nor
handed to the player. It lingers with propertyState="MISSION" (and often a foreign
farmId like 15), which makes it impossible to sell at any selling station.

This script flips such stuck MISSION-state pallets to propertyState="OWNED" and the
player's farm id, so they can be sold normally. It edits only the matching
<vehicle ...> opening tags (regex, formatting preserved) and never reparses/rewrites
the whole savegame.

Default is a DRY RUN (prints what it would change). Use --apply to write, which
backs up vehicles.xml first.

Usage:
    python3 fix_lostcargo_pallets.py                      # dry run, default savegame5
    python3 fix_lostcargo_pallets.py --apply              # apply to savegame5
    python3 fix_lostcargo_pallets.py --savegame savegame5 --farm 1 --apply
    python3 fix_lostcargo_pallets.py --uniqueid vehicle2a3b... --apply   # target one

Re-runnable: it only touches MISSION-state pallets, so running it again after a new
stuck reward repeats the fix.
"""

import argparse
import datetime as _dt
import os
import re
import shutil
import subprocess
import sys

# Reward fill types that "fall off a truck" -- restrict to product pallets so we never
# touch an active delivery mission's deliverable by accident. Extend as needed.
REWARD_FILLTYPES = {
    "BATHTUB", "PREFABWALL", "FURNITURE", "BOARDS", "PLANKS", "WOODBEAM",
    "BARREL", "BUCKET", "CEMENT", "CEMENTBRICKS", "ROOFPLATES", "ROPE",
    "CARTONROLL", "PAPERROLL", "FABRIC", "CLOTHES",
}

DEFAULT_SAVEGAME_DIR = os.path.expanduser(
    "~/Library/Application Support/FarmingSimulator2025"
)

VEHICLE_OPEN_RE = re.compile(r"<vehicle\b[^>]*>")
ATTR_RE = lambda name: re.compile(r'(%s=")([^"]*)(")' % re.escape(name))
FILLTYPE_RE = re.compile(r'fillType="([^"]+)"')


def fs_is_running():
    try:
        out = subprocess.run(
            ["pgrep", "-fi", "FarmingSimulator2025"],
            capture_output=True, text=True
        )
        return out.returncode == 0 and out.stdout.strip() != ""
    except Exception:
        return False


def get_attr(tag, name):
    m = ATTR_RE(name).search(tag)
    return m.group(2) if m else None


def set_attr(tag, name, value):
    """Set or insert an attribute in an XML opening tag, returning the new tag."""
    pat = ATTR_RE(name)
    if pat.search(tag):
        return pat.sub(lambda m: m.group(1) + value + m.group(3), tag)
    # insert before the closing '>'
    return tag[:-1] + ' %s="%s"' % (name, value) + tag[-1]


def find_block_filltype(lines, start_idx, max_scan=15):
    """Scan forward from a <vehicle> line to find the first fillType in its unit block."""
    for j in range(start_idx, min(start_idx + max_scan, len(lines))):
        if "</vehicle>" in lines[j] and j != start_idx:
            break
        m = FILLTYPE_RE.search(lines[j])
        if m:
            return m.group(1)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--savegame", default="savegame5",
                    help="savegame folder name or absolute path (default: savegame5)")
    ap.add_argument("--farm", default="1", help="player farm id to assign (default: 1)")
    ap.add_argument("--apply", action="store_true",
                    help="actually write changes (default: dry run)")
    ap.add_argument("--uniqueid", action="append", default=[],
                    help="only fix the vehicle with this uniqueId (repeatable)")
    ap.add_argument("--any-filltype", action="store_true",
                    help="do not restrict to the reward fill-type allowlist")
    ap.add_argument("--force", action="store_true",
                    help="proceed even if Farming Simulator appears to be running")
    args = ap.parse_args()

    sg = args.savegame
    if not os.path.isabs(sg):
        sg = os.path.join(DEFAULT_SAVEGAME_DIR, sg)
    vfile = os.path.join(sg, "vehicles.xml")
    if not os.path.isfile(vfile):
        sys.exit("vehicles.xml not found: %s" % vfile)

    if args.apply and fs_is_running() and not args.force:
        sys.exit("Farming Simulator is running -- close it first (the game would "
                 "overwrite the save). Use --force to override.")

    with open(vfile, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    targets = []  # (line_index, old_tag, new_tag, info)
    for i, line in enumerate(lines):
        m = VEHICLE_OPEN_RE.search(line)
        if not m:
            continue
        tag = m.group(0)
        filename = get_attr(tag, "filename") or ""
        prop = get_attr(tag, "propertyState") or ""
        if prop != "MISSION":
            continue
        if "pallet" not in filename.lower():
            continue
        uid = get_attr(tag, "uniqueId") or ""
        if args.uniqueid and uid not in args.uniqueid:
            continue
        filltype = find_block_filltype(lines, i) or "?"
        if not args.any_filltype and not args.uniqueid:
            if filltype not in REWARD_FILLTYPES:
                continue
        farm = get_attr(tag, "farmId") or "?"
        new_tag = set_attr(tag, "propertyState", "OWNED")
        new_tag = set_attr(new_tag, "farmId", args.farm)
        new_line = line.replace(tag, new_tag)
        info = "%-14s farm %-3s -> %s  fill=%-10s  %s" % (
            os.path.basename(filename).replace(".xml", ""),
            farm, args.farm, filltype, uid)
        targets.append((i, line, new_line, info))

    if not targets:
        print("No stuck MISSION-state reward pallets found. Nothing to do.")
        return

    print("Found %d stuck MISSION pallet(s):" % len(targets))
    for _, _, _, info in targets:
        print("  " + info)

    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply to fix.")
        return

    backup = vfile + ".bak_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(vfile, backup)
    print("\nBackup: %s" % backup)

    for idx, _, new_line, _ in targets:
        lines[idx] = new_line
    with open(vfile, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    print("Patched %d pallet(s) -> propertyState=OWNED, farmId=%s. "
          "Load the save and sell them at the farmer market." % (len(targets), args.farm))


if __name__ == "__main__":
    main()
