#!/usr/bin/env python3
"""
patch_woodchips_inference_proximity.py

Personal fork patch for FS25_woodChipsMission (htModding): make the addMoney-inference credit
deliveries on maps where the sell point pays via Mission00:addMoney (e.g. Weipersdorf "Scheune VK").

Root cause (traced via routing[unregister] debug): after reload a mission's live `sellingStation`
resolves to a WRONG/FAR station object (getName "Selling Station"), while the persisted target
coords stay correct. The addMoney-inference then (a) measures player proximity against that wrong
station's placeable -> player is far -> no candidate found, and (b) credits via serverOnWoodchipsSold
whose `isTarget` checks the same wrong object -> no fillSold. So nothing is credited (108/102 stay 0)
even though the player got paid.

Two surgical fixes:
  1) Register.lua: inference proximity uses the mission's SAVED sellingTargetX/Z (where the player
     actually tips), falling back to the station placeable only if coords are missing.
  2) WoodChipsMission.lua: serverOnWoodchipsSold:isTarget also trusts the mission's OWN resolved
     station (sellingStation == self.sellingStation), so fillSold runs for the inference path.

Idempotent (per-file markers), backs the zip up once, re-zips only the changed members, LF preserved.
RE-RUN after any mod update (with the other woodchips patches).

Usage:
    python3 patch_woodchips_inference_proximity.py                 # dry run
    python3 patch_woodchips_inference_proximity.py --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_woodChipsMission.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_woodChipsMission.zip"),
]

# member -> (marker, old, new)
EDITS = {
    "scripts/WoodChipsMissionRegister.lua": (
        "-- [SAM patch] proximity by the mission",
        (
            "            local st = resolveStation(m.sellingStation) or m.sellingStation\n"
            "            local placeable = st ~= nil and st.owningPlaceable or nil\n"
            "            local node = placeable ~= nil and placeable.rootNode or (st ~= nil and st.rootNode or nil)\n"
            "            if node ~= nil then\n"
            "                local sx, sy, sz = getWorldTranslation(node)\n"
            "                local dx = px - sx\n"
            "                local dz = pz - sz\n"
            "                local distSq = dx*dx + dz*dz\n"
            "                if distSq < bestDistSq then\n"
            "                    bestDistSq = distSq\n"
            "                    bestMission = m\n"
            "                    bestStation = st\n"
            "                end\n"
            "            end"
        ),
        (
            "            local st = resolveStation(m.sellingStation) or m.sellingStation\n"
            "            -- [SAM patch] proximity by the mission's SAVED target coords (where the player tips);\n"
            "            -- the resolved station object can be a wrong/far placeable on addMoney-paying maps.\n"
            "            local sx, sz = m.sellingTargetX, m.sellingTargetZ\n"
            "            if sx == nil or sz == nil then\n"
            "                local placeable = st ~= nil and st.owningPlaceable or nil\n"
            "                local node = placeable ~= nil and placeable.rootNode or (st ~= nil and st.rootNode or nil)\n"
            "                if node ~= nil then local gx_, gy_, gz_ = getWorldTranslation(node); sx, sz = gx_, gz_ end\n"
            "            end\n"
            "            if sx ~= nil and sz ~= nil then\n"
            "                local dx = px - sx\n"
            "                local dz = pz - sz\n"
            "                local distSq = dx*dx + dz*dz\n"
            "                if distSq < bestDistSq then\n"
            "                    bestDistSq = distSq\n"
            "                    bestMission = m\n"
            "                    bestStation = st\n"
            "                end\n"
            "            end"
        ),
    ),
    "scripts/WoodChipsMission.lua": (
        "-- [SAM patch] trust own resolved station",
        "    local isTarget = sellingStation ~= nil and self:_isTargetStation(sellingStation)",
        "    local isTarget = sellingStation ~= nil and (self:_isTargetStation(sellingStation) or sellingStation == self.sellingStation) -- [SAM patch] trust own resolved station",
    ),
}


def fs_running():
    try:
        r = subprocess.run(["pgrep", "-fi", "FarmingSimulator2025"],
                           capture_output=True, text=True)
        return r.returncode == 0 and r.stdout.strip() != ""
    except Exception:
        return False


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

    zin = zipfile.ZipFile(zip_path, "r")
    infos = {i.filename: i for i in zin.infolist()}
    data = {fn: zin.read(fn) for fn in infos}
    zin.close()

    changed = []
    notes = []
    for member, (marker, old, new) in EDITS.items():
        if member not in data:
            sys.exit("%s not in zip -- wrong mod/version." % member)
        src = data[member].decode("utf-8")
        if marker in src:
            notes.append("%s: already patched" % member)
            continue
        if old not in src:
            sys.exit("ANCHOR not found in %s -- mod version changed; aborting (no write)." % member)
        data[member] = src.replace(old, new, 1).encode("utf-8")
        changed.append(member)
        notes.append("%s: patched" % member)

    print("Zip :", zip_path)
    for n in notes:
        print(" =>", n)
    if not changed:
        return
    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return
    if fs_running() and not args.force:
        sys.exit("Farming Simulator is running -- close it first (or --force).")

    backup = zip_path + ".bak_inference_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    tmp = zip_path + ".tmp"
    zo = zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED)
    for fn, info in infos.items():
        zo.writestr(info, data[fn])
    zo.close()
    os.replace(tmp, zip_path)
    print("Patched. Re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
