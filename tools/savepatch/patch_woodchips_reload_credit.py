#!/usr/bin/env python3
"""
patch_woodchips_reload_credit.py

Personal fork patch for FS25_woodChipsMission (htModding): fix deliveries not counting
after a savegame reload.

Root cause: woodchip sales are routed to a mission via findMatchingMission(), which matches
either by station.missions[mission] (the registration) or by mission:_isTargetStation(station).
BOTH depend on the mission's live `sellingStation` object being resolved. After a reload that
object is nil (only id/name/target-coords are persisted) and the lazy re-resolve is unreliable,
so `_isTargetStation` hits its `if ... or self.sellingStation == nil then return false` guard and
EVERY match fails -> the player gets paid by vanilla but the mission stays at 0 L.

Fix: make `_isTargetStation` also match by the SAVED target coordinates (sellingTargetX/Z), which
ARE persisted -- so a sale at the target location credits the mission even when the live station
object isn't resolved. Reload-safe, no dependency on the fragile re-registration.

Targets scripts/WoodChipsMission.lua inside the mod zip. Idempotent (marker), backs the zip up
once, re-zips only that member, preserves line endings. RE-RUN after any mod update.

Usage:
    python3 patch_woodchips_reload_credit.py                 # dry run
    python3 patch_woodchips_reload_credit.py --apply
    python3 patch_woodchips_reload_credit.py --zip /path/to/FS25_woodChipsMission.zip --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/WoodChipsMission.lua"
MARKER = "-- [SAM patch] reload-safe match"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_woodChipsMission.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_woodChipsMission.zip"),
]

OLD_LINE = "    if station == nil or self.sellingStation == nil then return false end"

NEW_LINES = [
    "    if station == nil then return false end",
    "    -- [SAM patch] reload-safe match: credit deliveries by SAVED target coords even when",
    "    -- the live sellingStation object isn't resolved yet (fixes deposited=0 after reload).",
    "    if self.sellingTargetX ~= nil and self.sellingTargetZ ~= nil and self._getStationWorldTarget ~= nil then",
    "        local _sx, _sz = self:_getStationWorldTarget(station)",
    "        if _sx ~= nil and _sz ~= nil then",
    "            local _dx, _dz = _sx - self.sellingTargetX, _sz - self.sellingTargetZ",
    "            if (_dx * _dx + _dz * _dz) <= 625 then return true end",  # 25 m radius
    "        end",
    "    end",
    "    if self.sellingStation == nil then return false end",
]


def detect_nl(src):
    return "\r\n" if "\r\n" in src else "\n"


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    nl = detect_nl(src)
    old = OLD_LINE if nl == "\n" else OLD_LINE.replace("\n", nl)
    if old not in src:
        return src, False, "_isTargetStation guard line not found -- mod version changed"
    new = nl.join(NEW_LINES)
    out = src.replace(old, new, 1)
    return out, True, "patched _isTargetStation: coordinate fallback added (25 m), reload-safe crediting"


def fs_running():
    try:
        r = subprocess.run(["pgrep", "-fi", "FarmingSimulator2025"],
                           capture_output=True, text=True)
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
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zip", default=None)
    ap.add_argument("--apply", action="store_true", help="write the patch (default: dry run)")
    ap.add_argument("--force", action="store_true", help="patch even if FS appears to run")
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
            sys.exit("%s not in zip -- wrong mod/version." % MEMBER)
        src = z.read(MEMBER).decode("utf-8")

    new_src, changed, note = patch_src(src)
    print("Zip : %s" % zip_path)
    print("=> %s" % note)
    if not changed:
        return
    if not args.apply:
        print("\nDRY RUN -- nothing written. Re-run with --apply.")
        return
    if fs_running() and not args.force:
        sys.exit("Farming Simulator is running -- close it first (or --force).")

    backup = zip_path + ".bak_reloadcredit_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup: %s" % os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. If this was the library zip, re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
