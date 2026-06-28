#!/usr/bin/env python3
"""
patch_fos_probe_neighborhood.py

Personal fork patch for FS25_FieldsOfStories (AirFoxTwo): add NEIGHBORHOOD TOLERANCE to
the phone field-outcome probe evaluation. A probe that lands on a tramline (Fahrgasse) or
a 1-cell unreachable edge still counts as matched when a nearby cell (within
NEIGHBOR_RADIUS_M) satisfies the expected FieldState.

Why: completion = matched/total probes (>= 0.9 since 1.0.0.1). Sparse random probes can
land on cells you can never satisfy (tramlines / unreachable edges), so small fields stall
1 probe under the threshold (the Feld-31 "89%" case). Sampling a small neighborhood per
probe rescues those without any tramline-map lookup -- dependency-free, works vanilla + PF.

Targets IAFieldOutcomeMissionProbeEvaluator.lua inside the mod zip. Idempotent (marker),
backs the zip up once, re-zips only that one member, preserves the file's line endings.
RE-RUN after any FoS update.

Usage:
    python3 patch_fos_probe_neighborhood.py                       # dry run
    python3 patch_fos_probe_neighborhood.py --apply
    python3 patch_fos_probe_neighborhood.py --zip /path/to/FS25_FieldsOfStories.zip --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "IAFieldOutcomeMissionProbeEvaluator.lua"
MARKER = "-- [SAM patch] neighborhood tolerance"
ANCHOR_FUNC = "function IAFieldOutcomeMissionProbeEvaluator.evaluateAllProbes("

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_FieldsOfStories.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_FieldsOfStories.zip"),
]

# Tabs match the mod's indentation; lines are joined with the file's detected newline.
HELPER_LINES = [
    "-- [SAM patch] neighborhood tolerance: a probe also counts as matched when a nearby",
    "-- cell (within NEIGHBOR_RADIUS_M) satisfies the expected FieldState. Rescues probes that",
    "-- land on tramlines / 1-cell unreachable edges without any tramline-map lookup (vanilla + PF).",
    "IAFieldOutcomeMissionProbeEvaluator.NEIGHBOR_RADIUS_M = 2.0",
    "function IAFieldOutcomeMissionProbeEvaluator.probeMatchesWithNeighborhood(expState, jobRaw, sampleAt, px, pz)",
    "\tlocal r = IAFieldOutcomeMissionProbeEvaluator.NEIGHBOR_RADIUS_M",
    "\tlocal offs = { {0,0},{r,0},{-r,0},{0,r},{0,-r},{r,r},{r,-r},{-r,r},{-r,-r} }",
    "\tlocal centerState = nil",
    "\tfor i, o in ipairs(offs) do",
    "\t\tlocal st = sampleAt(px + o[1], pz + o[2])",
    "\t\tif i == 1 then centerState = st end",
    "\t\tif IAFieldOutcomeMissionProbeEvaluator.probeSatisfiesExpected(expState, jobRaw, st) then",
    "\t\t\treturn true, st",
    "\t\tend",
    "\tend",
    "\treturn false, centerState",
    "end",
    "",
    "",
]

OLD_LOOP_LINES = [
    "\t\tlocal state = sampleAt(p.x, p.z)",
    "\t\tif eval.probeSatisfiesExpected(expState, jobRaw, state) then",
]
NEW_LOOP_LINES = [
    "\t\tlocal _nbOk, state = eval.probeMatchesWithNeighborhood(expState, jobRaw, sampleAt, p.x, p.z)",
    "\t\tif _nbOk then",
]


def detect_nl(src):
    return "\r\n" if "\r\n" in src else "\n"


def patch_src(src):
    """Return (new_src, changed, note)."""
    if MARKER in src:
        return src, False, "already patched (marker present)"
    if ANCHOR_FUNC not in src:
        return src, False, "evaluateAllProbes anchor not found -- mod layout changed"
    nl = detect_nl(src)
    old_loop = nl.join(OLD_LOOP_LINES)
    new_loop = nl.join(NEW_LOOP_LINES)
    helper = nl.join(HELPER_LINES)
    if old_loop not in src:
        return src, False, ("probe-loop anchor not found (version changed) -- "
                            "inspect evaluateAllProbes before patching")
    out = src.replace(ANCHOR_FUNC, helper + ANCHOR_FUNC, 1)
    out = out.replace(old_loop, new_loop, 1)
    return out, True, "patched: neighborhood tolerance added (radius 2.0 m, 8-neighborhood)"


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
        sys.exit("FS25_FieldsOfStories.zip not found (use --zip).")

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

    backup = zip_path + ".bak_preNB_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup: %s" % os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. If this was the library zip, re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
