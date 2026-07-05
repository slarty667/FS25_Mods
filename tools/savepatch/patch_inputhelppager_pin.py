#!/usr/bin/env python3
"""
patch_inputhelppager_pin.py

Personal fork patch for FS25_InputHelpPager (v3.5.0).

Problem: the mod paginates the input-help list into pages of 12 and only draws the current
page. With many active action prompts (CoursePlay, AutoDrive, UniversalAutoload, cruise
control, ...), context/trigger prompts like ACTIVATE_OBJECT ("R" = load/activate at a
loading trigger) get pushed onto page 2+ and become invisible.

Fix: pin a small set of important CONTEXT prompts to the FRONT of the filtered list before
pagination, so they always land on page 1. These actions only appear when actually relevant
(at a trigger / near an attachable), so pinning them does not clutter page 1 otherwise.

Two edits in InputHelpPager.lua (marker '-- [SAM patch] pin context prompts'):
  1) define InputHelpPager.pinnedActions right after hiddenActions,
  2) stable-partition filteredList (pinned first, rest after) before the page slice.

Idempotent (marker), backs the zip up once, re-zips only that member, LF preserved.
RE-RUN after any mod update, then `fsmods use <profile>` (FS closed).

Usage:
    python3 patch_inputhelppager_pin.py            # dry run
    python3 patch_inputhelppager_pin.py --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "InputHelpPager.lua"
MARKER = "-- [SAM patch] pin context prompts"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_InputHelpPager.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_InputHelpPager.zip"),
]

# Edit 1: pinned-actions table, injected after the hiddenActions field.
ANCHOR1 = "InputHelpPager.hiddenActions = {}"
INSERT1 = ANCHOR1 + "\n" + (
    "-- [SAM patch] pin context prompts: always keep these on page 1 (they only show when relevant)\n"
    "InputHelpPager.pinnedActions = { ACTIVATE_OBJECT = true, ATTACH = true }"
)

# Edit 2: stable partition (pinned first) after the item count is set, before the page limit.
ANCHOR2 = "    InputHelpPager.totalItems = #filteredList\n"
INSERT2 = ANCHOR2 + (
    "    -- [SAM patch] pin context prompts to the front so page 1 always shows them\n"
    "    do\n"
    "        local pinned, rest = {}, {}\n"
    "        for _, e in ipairs(filteredList) do\n"
    "            if InputHelpPager.pinnedActions and InputHelpPager.pinnedActions[e.actionName] then\n"
    "                pinned[#pinned + 1] = e\n"
    "            else\n"
    "                rest[#rest + 1] = e\n"
    "            end\n"
    "        end\n"
    "        if #pinned > 0 then\n"
    "            filteredList = pinned\n"
    "            for _, e in ipairs(rest) do filteredList[#filteredList + 1] = e end\n"
    "        end\n"
    "    end\n"
)


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    # The mod zip ships CRLF line endings; match the file's newline style so anchors hit.
    nl = "\r\n" if "\r\n" in src else "\n"
    a1, a2 = ANCHOR1, ANCHOR2.replace("\n", nl)
    if a1 not in src or a2 not in src:
        miss = "ANCHOR1" if a1 not in src else "ANCHOR2"
        return src, False, "%s not found -- mod version changed" % miss
    i1, i2 = INSERT1.replace("\n", nl), INSERT2.replace("\n", nl)
    out = src.replace(a1, i1, 1).replace(a2, i2, 1)
    return out, True, "patched: pin ACTIVATE_OBJECT/ATTACH to page 1"


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
        sys.exit("FS25_InputHelpPager.zip not found (use --zip).")

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

    backup = zip_path + ".bak_ihppin_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup:", os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. Re-link with `fsmods use <profile>` (FS closed), then restart FS.")


if __name__ == "__main__":
    main()
