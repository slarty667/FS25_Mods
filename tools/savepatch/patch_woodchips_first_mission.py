#!/usr/bin/env python3
"""
patch_woodchips_first_mission.py

Personal fork patch for FS25_woodChipsMission (htModding) -- THE fix that finally made
deliveries count on Weipersdorf "Scheune VK" (which pays via Mission00:addMoney, no sellFillType).

Proven via forced-debug trace: the addMoney-inference's proximity check (line ~990) was always
false -- the player's tip position never matched the mission's stored target coords (the station
placeable root is a different point than the unload trigger on this map, >160 m apart), so no
candidate was ever found and nothing was credited (108/102 stayed 0) even though the player got paid.

Fix (3 changes in WoodChipsMissionRegister.lua, all inside the addMoney-inference block):
  1) collect only missions that NEED delivery (wcMissionNeedsDelivery instead of isMissionRunning),
  2) drop the proximity requirement: with >=1 running woodchips mission at the station, credit the
     FIRST one needing delivery (distribution 108->102 falls out as each fills),
  3) pricePerLiter fallback to the mission's stored pricePerLiter when the (mis-resolved) station
     reports none.

Depends on the other woodchips patches (esp. "trust own resolved station" in serverOnWoodchipsSold).
Idempotent (marker), backs the zip up once, re-zips only that member, LF preserved.
RE-RUN after any mod update (with the other woodchips patches).

Usage:
    python3 patch_woodchips_first_mission.py            # dry run
    python3 patch_woodchips_first_mission.py --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/WoodChipsMissionRegister.lua"
MARKER = "-- [SAM patch] no proximity"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_woodChipsMission.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_woodChipsMission.zip"),
]

REPLACEMENTS = [
    (
        "m.isWoodChipsMission == true and isMissionRunning(m) and m.sellingStation ~= nil",
        "m.isWoodChipsMission == true and wcMissionNeedsDelivery(m) and m.sellingStation ~= nil",
    ),
    (
        "    if #running == 1 then",
        "    if #running >= 1 then -- [SAM patch] no proximity: credit first needing-delivery mission",
    ),
    (
        "            pricePerLiter = bestStation:getFillTypePrice(bestMission.fillTypeIndex) or 0\n        end",
        "            pricePerLiter = bestStation:getFillTypePrice(bestMission.fillTypeIndex) or 0\n"
        "        end\n"
        "        if pricePerLiter <= 0.0001 then pricePerLiter = tonumber(bestMission.pricePerLiter) or 0 end -- [SAM patch] price fallback",
    ),
]


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    for old, _new in REPLACEMENTS:
        if old not in src:
            return src, False, "anchor not found (%s...) -- mod version changed" % old[:40]
    out = src
    for old, new in REPLACEMENTS:
        out = out.replace(old, new, 1)
    return out, True, "patched: credit first needing-delivery mission (no proximity) + price fallback"


def fs_running():
    try:
        r = subprocess.run(["pgrep", "-fi", "FarmingSimulator2025"], capture_output=True, text=True)
        return r.returncode == 0 and r.stdout.strip() != ""
    except Exception:
        return False


def replace_in_zip(zip_path, member, new_bytes):
    tmp = zip_path + ".tmp"
    with zipfile.ZipFile(zip_path, "r") as zin, \
         zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == member:
                data = new_bytes
            zout.writestr(item, data)
    os.replace(tmp, zip_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=None)
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    zip_path = args.zip
    if zip_path is None:
        for c in DEFAULT_ZIPS:
            if os.path.isfile(c):
                zip_path = c
                break
    if not zip_path or not os.path.isfile(zip_path):
        sys.exit("FS25_woodChipsMission.zip not found (use --zip).")

    with zipfile.ZipFile(zip_path, "r") as z:
        if MEMBER not in z.namelist():
            sys.exit("%s not in zip." % MEMBER)
        src = z.read(MEMBER).decode("utf-8")

    new_src, changed, note = patch_src(src)
    print("Zip :", zip_path)
    print("=>", note)
    if not changed:
        return
    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return
    if fs_running() and not args.force:
        sys.exit("Farming Simulator is running -- close it first (or --force).")

    backup = zip_path + ".bak_firstmission_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
