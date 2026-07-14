#!/usr/bin/env python3
"""
patch_courseplay_coursedisplay_nil.py

Personal fork patch for FS25_Courseplay (v8.1.0.3).

Problem: CpCourseManager:onPreDelete() calls `spec.courseDisplay:delete()` unconditionally
(scripts/specializations/CpCourseManager.lua:370). When a vehicle is torn down whose
courseDisplay was never created (nil), this throws every frame:

    CpCourseManager.lua:370: attempt to index nil with 'delete'

Because the crash aborts onPreDelete, the vehicle removal is retried every frame -> the error
floods the log (8000+/run) and the update loop drowns, so the in-game MAP hangs on "Karte wird
geladen" and ESC no longer responds. Confirmed on Markus' Helden savegame10 (2026-07-13).

Fix: nil-guard the delete (what upstream should have done):
    spec.courseDisplay:delete()   ->   if spec.courseDisplay then spec.courseDisplay:delete() end
The following `spec.courseDisplay = nil` is harmless. onPreDelete then completes, the pending
vehicle removal succeeds, the crash-loop ends. Courseplay stays fully enabled.

One edit in scripts/specializations/CpCourseManager.lua (marker '-- [SAM patch] guard nil courseDisplay').
Idempotent (marker), backs the zip up once, re-zips only that member, newline style preserved.
RE-RUN after any Courseplay update, then `fsmods use <profile>` (FS closed).

Usage:
    python3 patch_courseplay_coursedisplay_nil.py            # dry run
    python3 patch_courseplay_coursedisplay_nil.py --apply
"""

import argparse
import datetime as _dt
import os
import re
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/specializations/CpCourseManager.lua"
MARKER = "-- [SAM patch] guard nil courseDisplay"

LINE_RE = re.compile(r"^(?P<indent>[ \t]*)spec\.courseDisplay:delete\(\)[ \t]*$", re.MULTILINE)
REPLACEMENT = (
    r"\g<indent>if spec.courseDisplay then spec.courseDisplay:delete() end   "
    + MARKER
    + " (was unconditional; nil on half-init vehicle -> onPreDelete crash-loop -> map hang)"
)

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_Courseplay.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_Courseplay.zip"),
]


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    if not LINE_RE.search(src):
        return src, False, "courseDisplay:delete() line not found -- Courseplay version changed"
    out = LINE_RE.sub(REPLACEMENT, src, count=1)
    return out, True, "patched: nil-guarded spec.courseDisplay:delete() in onPreDelete"


def fs_running():
    try:
        r = subprocess.run(["pgrep", "-fi", "FarmingSimulator2025Game"],
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
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", default=None)
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    zip_path = args.zip
    if zip_path is None:
        for c in DEFAULT_ZIPS:
            if os.path.isfile(c):
                zip_path = c
                break
    if not zip_path or not os.path.isfile(zip_path):
        sys.exit("FS25_Courseplay.zip not found (use --zip).")

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

    backup = zip_path + ".bak_cpcoursedisp_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed), then restart FS.")


if __name__ == "__main__":
    main()
