#!/usr/bin/env python3
"""
patch_woodchips_target_coords.py

Personal fork patch for FS25_woodChipsMission (htModding): two confirmed fixes.

1) SAVE CRASH (fires on every save, 3x in the log): WoodChipsMission:saveToXMLFile does
   xmlFile:setValue(key.."#sellingStationName", stationName) where stationName is nil whenever
   self.sellingStation is nil (the unresolved-after-reload state) -> 'setXMLString: Argument 2
   ... Actual: Nil' script error. Guard: fall back to the saved station name (or "").

2) TARGET-COORD CLOBBER: the reload re-resolve (update() retry, and one other setter) does
   self.sellingTargetX/Z = self:_getStationWorldTarget(ss) using the *resolved* station, which can
   be a wrong/generic station -> overwrites the persisted true target and breaks coord-based
   crediting/rollover. Guard: only set target coords if they aren't already valid (old saves), never
   overwrite a good saved target. The acceptance-time set in start() is left intact (it's the truth).

Targets scripts/WoodChipsMission.lua. Idempotent (marker), backs the zip up once, re-zips only that
member, preserves line endings. RE-RUN after any mod update (and re-run the other two woodchips patches).

Usage:
    python3 patch_woodchips_target_coords.py                 # dry run
    python3 patch_woodchips_target_coords.py --apply
    python3 patch_woodchips_target_coords.py --zip /path/to/FS25_woodChipsMission.zip --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/WoodChipsMission.lua"
MARKER = "-- [SAM patch] keep saved target"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_woodChipsMission.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_woodChipsMission.zip"),
]

# (old, new) replacements. Indentation is part of each anchor (distinguishes the 3 clobber sites).
REPLACEMENTS = [
    # 1) save-crash guard (4-space): prepend a fallback before the setValue
    (
        '    xmlFile:setValue(key .. "#sellingStationName", stationName)',
        '    if stationName == nil then stationName = self.savedSellingStationName or "" end -- [SAM patch] keep saved target\n'
        '    xmlFile:setValue(key .. "#sellingStationName", stationName)',
    ),
    # 2a) reload-retry clobber guard (16-space)
    (
        '                self.sellingTargetX, self.sellingTargetZ = self:_getStationWorldTarget(ss)',
        '                if self.sellingTargetX == nil or self.sellingTargetZ == nil or (self.sellingTargetX == 0 and self.sellingTargetZ == 0) then\n'
        '                    self.sellingTargetX, self.sellingTargetZ = self:_getStationWorldTarget(ss)\n'
        '                end',
    ),
    # 2b) other setter clobber guard (8-space)
    (
        '        self.sellingTargetX, self.sellingTargetZ = self:_getStationWorldTarget(ss)',
        '        if self.sellingTargetX == nil or self.sellingTargetZ == nil or (self.sellingTargetX == 0 and self.sellingTargetZ == 0) then\n'
        '            self.sellingTargetX, self.sellingTargetZ = self:_getStationWorldTarget(ss)\n'
        '        end',
    ),
]


def detect_nl(src):
    return "\r\n" if "\r\n" in src else "\n"


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    nl = detect_nl(src)
    # validate all anchors against the original first
    for i, (old, _new) in enumerate(REPLACEMENTS):
        o = old if nl == "\n" else old.replace("\n", nl)
        if o not in src:
            return src, False, "anchor #%d not found -- mod version changed" % (i + 1)
    out = src
    for old, new in REPLACEMENTS:
        o = old if nl == "\n" else old.replace("\n", nl)
        n = new if nl == "\n" else new.replace("\n", nl)
        out = out.replace(o, n, 1)
    return out, True, "patched: save-name guard + 2 target-coord clobber guards"


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

    backup = zip_path + ".bak_targetcoords_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup: %s" % os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. If this was the library zip, re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
