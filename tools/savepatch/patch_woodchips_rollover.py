#!/usr/bin/env python3
"""
patch_woodchips_rollover.py

Personal fork patch for FS25_woodChipsMission (htModding): make an oversized woodchips
delivery roll the surplus over to the NEXT running contract at the same station, like vanilla
harvest missions do -- instead of crediting a single mission and dropping/mis-paying the rest.

Stock behaviour: wrapSell() routes a whole sale to ONE mission (findMatchingMission), which caps
at its need; the surplus neither advances the next contract nor reliably pays out.

Fix: in wrapSell, after vanilla booked the money, distribute `liters` across ALL running woodchips
missions targeting this station, each absorbing up to its remaining need via serverOnWoodchipsSold
(which removes that chunk's booked market money -- contract liters don't pay). Only the true
surplus left after every mission is full keeps the vanilla market payout. Money nets out exactly.

Targets scripts/WoodChipsMissionRegister.lua inside the mod zip. Idempotent (marker), backs the zip
up once, re-zips only that member, preserves line endings. RE-RUN after any mod update.
Requires the reload-credit patch's reliable _isTargetStation (apply patch_woodchips_reload_credit.py too).

Usage:
    python3 patch_woodchips_rollover.py                 # dry run
    python3 patch_woodchips_rollover.py --apply
    python3 patch_woodchips_rollover.py --zip /path/to/FS25_woodChipsMission.zip --apply
"""

import argparse
import datetime as _dt
import os
import shutil
import subprocess
import sys
import zipfile

MEMBER = "scripts/WoodChipsMissionRegister.lua"
MARKER = "-- [SAM patch] multi-mission split"

DEFAULT_ZIPS = [
    os.path.expanduser("~/FS25_ModLibrary/FS25_woodChipsMission.zip"),
    os.path.expanduser("~/Library/Application Support/FarmingSimulator2025/mods/"
                       "FS25_woodChipsMission.zip"),
]

OLD = '''        if mission ~= nil and mission.serverOnWoodchipsSold ~= nil and mission.isServer ~= false then
            mission:serverOnWoodchipsSold(station, liters, money, farmId)
        end

        -- Fallback: if vanilla did not call mission:fillSold() (progress unchanged), do it ourselves.
        if mission ~= nil and depositedBefore ~= nil then
            local depositedAfter = mission.depositedLiters or 0
            if depositedAfter <= depositedBefore then
                mission:fillSold(liters)
                if dbg then
                    local name = (station and station.getName) and station:getName() or tostring(station)
                    Logging.warning("[WCDbg] sellFillType fallback: vanilla did not update progress (station='%s', liters=%.1f). Forced mission:fillSold().",
                        tostring(name), tonumber(liters) or -1)
                end
            end
        end'''

NEW = '''        -- [SAM patch] multi-mission split: distribute the delivery across ALL running woodchips
        -- missions targeting this station (vanilla harvest-mission behaviour). Each mission absorbs
        -- up to its remaining need (contract-covered, no market pay); only the true surplus left
        -- after every mission is full keeps the vanilla market payout. Money nets out exactly:
        -- each chunk's serverOnWoodchipsSold removes its booked market money, surplus money stays.
        if isWoodchips and type(liters) == "number" and liters > 0 then
            local ppl = (money ~= nil and liters > 0) and (money / liters) or 0
            local remaining = liters
            local targets = {}
            for _, m in pairs(iterMissions()) do
                if m ~= nil and m.fillTypeIndex == fillTypeIndex
                    and wcMissionNeedsDelivery(m)
                    and m._isTargetStation ~= nil and m:_isTargetStation(station)
                    and m.serverOnWoodchipsSold ~= nil and m.isServer ~= false then
                    targets[#targets + 1] = m
                end
            end
            for _, m in ipairs(targets) do
                if remaining <= 0 then break end
                local need = math.max((m.expectedLiters or 0) - (m.depositedLiters or 0), 0)
                local chunk = math.min(remaining, need)
                if chunk > 0 then
                    m:serverOnWoodchipsSold(station, chunk, chunk * ppl, farmId, true)
                    remaining = remaining - chunk
                end
            end
        elseif mission ~= nil and mission.serverOnWoodchipsSold ~= nil and mission.isServer ~= false then
            mission:serverOnWoodchipsSold(station, liters, money, farmId)
        end'''


def detect_nl(src):
    return "\r\n" if "\r\n" in src else "\n"


def patch_src(src):
    if MARKER in src:
        return src, False, "already patched (marker present)"
    nl = detect_nl(src)
    old = OLD if nl == "\n" else OLD.replace("\n", nl)
    new = NEW if nl == "\n" else NEW.replace("\n", nl)
    if old not in src:
        return src, False, "wrapSell single-mission block not found -- mod version changed"
    out = src.replace(old, new, 1)
    return out, True, "patched wrapSell: surplus now rolls over to the next contract at the station"


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

    backup = zip_path + ".bak_rollover_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    shutil.copy2(zip_path, backup)
    print("Backup: %s" % os.path.basename(backup))
    replace_in_zip(zip_path, MEMBER, new_src.encode("utf-8"))
    print("Patched. If this was the library zip, re-link with `fsmods use <profile>` (FS closed).")


if __name__ == "__main__":
    main()
