#!/usr/bin/env python3
"""
patch_livestockvisibility_mac_ctrl.py

Personal fork patch for FS25_LivestockVisibility (v1.0.0.0).

Problem: the mod's info panel is opened with RIGHT Ctrl + T. The key handler gates on the
right-ctrl modifier flag only:

    local MODIFIER_RCTRL = 128            -- Right Ctrl modifier flag

On macOS the right Ctrl key is not reachable, so the panel can never be opened. Same class
of bug as FS25_LicensePlateRandomizer's duplicate-plate finder.

Fix: widen the modifier flag from 128 (right ctrl only) to 192 (128 right | 64 left), so the
handler also fires on LEFT Ctrl. Left Ctrl + T then opens the panel on Mac.

One edit in scripts/LivestockVisibility.lua (marker '-- [SAM patch] mac left-ctrl livestock panel').

Idempotent (marker), backs the zip up once, re-zips only that member, newline style preserved.
RE-RUN after any mod update, then `fsmods use <profile>` (FS closed).

Usage:
    python3 patch_livestockvisibility_mac_ctrl.py            # dry run
    python3 patch_livestockvisibility_mac_ctrl.py --apply
"""

import argparse
import datetime as _dt
import os
import re
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/LivestockVisibility.lua"
MARKER = "-- [SAM patch] mac left-ctrl livestock panel"

# Match the RCTRL modifier definition line (128 upstream, or 192 if already changed w/o our marker).
LINE_RE = re.compile(r"^(?P<indent>[ \t]*)local MODIFIER_RCTRL = \d+[^\r\n]*$", re.MULTILINE)
REPLACEMENT = (
    r"\g<indent>local MODIFIER_RCTRL = 192   "
    + MARKER
    + " (was 128; right ctrl unreachable on mac -> 128|64 also matches left ctrl)"
)

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_LivestockVisibility.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_LivestockVisibility.zip"),
]


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    if not LINE_RE.search(src):
        return src, False, "MODIFIER_RCTRL line not found -- mod version changed"
    out = LINE_RE.sub(REPLACEMENT, src, count=1)
    return out, True, "patched: MODIFIER_RCTRL 128 -> 192 (left ctrl now works)"


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
        sys.exit("FS25_LivestockVisibility.zip not found (use --zip).")

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

    backup = zip_path + ".bak_lvvctrl_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed), then restart FS.")


if __name__ == "__main__":
    main()
