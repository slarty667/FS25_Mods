#!/usr/bin/env python3
"""
patch_licenseplate_mac_ctrl.py

Personal fork patch for FS25_LicensePlateRandomizer (v1.0.2.0).

Problem: the Duplicate Plate Finder dialog is opened with RIGHT Ctrl + Period. The mod
gates the key handler on the right-ctrl modifier flag only:

    local LPR_MODIFIER_RCTRL = 128            -- Right Ctrl modifier flag
    if bitAND(modifier, LPR_MODIFIER_RCTRL) == 0 then return end

On macOS the right Ctrl key is not reachable, so the dialog can never be opened. Same class
of bug we already fixed in FS25_LivestockVisibility.

Fix: widen the modifier flag from 128 (right ctrl only) to 192 (128 right | 64 left), so the
handler also fires on LEFT Ctrl. Left Ctrl + Period then opens the finder on Mac. The core
feature (auto-randomize plate on purchase) is unaffected -- it uses no key binding.

One edit in scripts/LicensePlateRandomizer.lua (marker '-- [SAM patch] mac left-ctrl dup finder').

Idempotent (marker), backs the zip up once, re-zips only that member, newline style preserved.
RE-RUN after any mod update, then `fsmods use <profile>` (FS closed).

Usage:
    python3 patch_licenseplate_mac_ctrl.py            # dry run
    python3 patch_licenseplate_mac_ctrl.py --apply
"""

import argparse
import datetime as _dt
import os
import re
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/LicensePlateRandomizer.lua"
MARKER = "-- [SAM patch] mac left-ctrl dup finder"

# Match the RCTRL modifier definition line (128 upstream, or 192 if half-patched without marker).
LINE_RE = re.compile(r"^(?P<indent>[ \t]*)local LPR_MODIFIER_RCTRL = \d+[^\r\n]*$", re.MULTILINE)
REPLACEMENT = (
    r"\g<indent>local LPR_MODIFIER_RCTRL = 192   "
    + MARKER
    + " (was 128; right ctrl unreachable on mac -> 128|64 also matches left ctrl)"
)

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_LicensePlateRandomizer.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_LicensePlateRandomizer.zip"),
]


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    if not LINE_RE.search(src):
        return src, False, "RCTRL modifier line not found -- mod version changed"
    out = LINE_RE.sub(REPLACEMENT, src, count=1)
    return out, True, "patched: LPR_MODIFIER_RCTRL 128 -> 192 (left ctrl now works)"


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
        sys.exit("FS25_LicensePlateRandomizer.zip not found (use --zip).")

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

    backup = zip_path + ".bak_lprctrl_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed), then restart FS.")


if __name__ == "__main__":
    main()
