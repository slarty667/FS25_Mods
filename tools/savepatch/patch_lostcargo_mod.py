#!/usr/bin/env python3
"""
patch_lostcargo_mod.py

Reproducible source patch for FS25_AdditionalContracts: make a SUCCESSFUL "Lost cargo"
mission HAND the recovered cargo to the player (OWNED, sellable) instead of deleting it.

This is a deliberate house-rule change (you keep the salvage on top of the delivery
reward), not a pure bug fix -- but it also repairs a genuine dead-code condition.

The bug, in missions/universalMission/lostCargoMission/LostCargoMission.lua, deleteObject():

    if self.status ~= MissionStatus.FINISHED and self.finishState == MissionFinishState.SUCCESS then
        ...:setOwnerFarmId(self.farmId);
    else
        ...:delete();
    end

When cleanup runs the status IS FINISHED, so `status ~= FINISHED` is false and the
ownership branch is unreachable -> the cargo is always deleted, and stuck instances end
up un-sellable (propertyState=MISSION, foreign farmId).

This patch rewrites the condition to fire on SUCCESS and additionally sets the object's
propertyState to OWNED (setOwnerFarmId alone leaves propertyState=MISSION, which still
blocks selling -- confirmed in-save).

It is idempotent (a marker comment guards re-runs), backs the mod zip up once, and only
replaces the single Lua file inside the zip. Re-run it after the mod updates.

Usage:
    python3 patch_lostcargo_mod.py            # dry run (shows the diff intent)
    python3 patch_lostcargo_mod.py --apply
    python3 patch_lostcargo_mod.py --zip /path/to/FS25_AdditionalContracts.zip --apply
"""

import argparse
import datetime as _dt
import os
import re
import shutil
import sys
import zipfile

LUA_PATH = "missions/universalMission/lostCargoMission/LostCargoMission.lua"
MARKER = "-- [SAM patch] keep recovered cargo for the player"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_AdditionalContracts.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_AdditionalContracts.zip"),
]

COND_RE = re.compile(
    r"if\s+self\.status\s*~=\s*MissionStatus\.FINISHED\s+and\s+"
    r"self\.finishState\s*==\s*MissionFinishState\.SUCCESS\s+then"
)
SETOWNER_RE = re.compile(
    r"(g_currentMission\.nodeToObject\[object\.rootNode\]:setOwnerFarmId\(self\.farmId\);)"
)


def patch_lua(src):
    """Return (patched_src, changed:bool, note:str)."""
    if MARKER in src:
        return src, False, "already patched (marker present) -- nothing to do"
    if not COND_RE.search(src):
        return src, False, ("buggy condition not found -- mod layout changed; "
                            "inspect deleteObject() manually before patching")
    out = COND_RE.sub(
        "if self.finishState == MissionFinishState.SUCCESS then %s" % MARKER, src, count=1)
    if not SETOWNER_RE.search(out):
        return src, False, "setOwnerFarmId line not found -- aborting to stay safe"
    out = SETOWNER_RE.sub(
        r"\1 if g_currentMission.nodeToObject[object.rootNode].setPropertyState ~= nil then "
        r"g_currentMission.nodeToObject[object.rootNode]:setPropertyState(VehiclePropertyState.OWNED); end;",
        out, count=1)
    return out, True, "patched deleteObject(): SUCCESS now hands cargo to player as OWNED"


def replace_in_zip(zip_path, member, new_bytes):
    """Rewrite the zip with one member replaced (preserves the rest)."""
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
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", default=None, help="path to FS25_AdditionalContracts.zip")
    ap.add_argument("--apply", action="store_true", help="write the patch (default: dry run)")
    args = ap.parse_args()

    zip_path = args.zip
    if zip_path is None:
        for cand in DEFAULT_ZIPS:
            if os.path.isfile(cand):
                zip_path = cand
                break
    if not zip_path or not os.path.isfile(zip_path):
        sys.exit("FS25_AdditionalContracts.zip not found (use --zip).")

    with zipfile.ZipFile(zip_path, "r") as z:
        if LUA_PATH not in z.namelist():
            sys.exit("%s not inside the zip -- wrong mod or version." % LUA_PATH)
        src = z.read(LUA_PATH).decode("utf-8")

    new_src, changed, note = patch_lua(src)
    print("Zip : %s" % zip_path)
    print("File: %s" % LUA_PATH)
    print("=> %s" % note)
    if not changed:
        return
    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return

    backup = zip_path + ".bak_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup: %s" % backup)
    replace_in_zip(zip_path, LUA_PATH, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed), then restart FS.")


if __name__ == "__main__":
    main()
