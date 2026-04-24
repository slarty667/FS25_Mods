#!/usr/bin/env python3
"""
Find unused mods in FS25 mods folder.
Compares installed mods against mods referenced in all active savegames.
"""

import os
import re
import xml.etree.ElementTree as ET
from pathlib import Path
from collections import defaultdict

# Paths
FS25_BASE = Path.home() / "Library/Application Support/FarmingSimulator2025"
MODS_FOLDER = FS25_BASE / "mods"

def get_installed_mods():
    """Get all installed mods from the mods folder."""
    mods = set()
    if not MODS_FOLDER.exists():
        print(f"ERROR: Mods folder not found: {MODS_FOLDER}")
        return mods
    
    for item in MODS_FOLDER.iterdir():
        if item.is_file() and item.suffix.lower() == ".zip":
            mod_name = item.stem
            mods.add(mod_name)
        elif item.is_dir() and not item.name.startswith("."):
            mods.add(item.name)
    
    return mods

def get_savegame_mods(savegame_path):
    """Extract mod names from a savegame's careerSavegame.xml."""
    mods = set()
    career_file = savegame_path / "careerSavegame.xml"
    
    if not career_file.exists():
        return mods, None
    
    try:
        tree = ET.parse(career_file)
        root = tree.getroot()
        
        map_title = None
        settings = root.find("settings")
        if settings is not None:
            map_title_elem = settings.find("mapTitle")
            if map_title_elem is not None:
                map_title = map_title_elem.text
        
        for mod in root.findall("mod"):
            mod_name = mod.get("modName")
            if mod_name:
                mods.add(mod_name)
        
        return mods, map_title
    
    except ET.ParseError as e:
        print(f"  WARNING: Could not parse {career_file}: {e}")
        return mods, None

def get_all_savegame_mods():
    """Get all mods used across all active savegames."""
    all_mods = set()
    mods_per_savegame = {}
    
    print("\nActive Savegames found:")
    print("-" * 50)
    
    for item in sorted(FS25_BASE.iterdir()):
        if item.is_dir() and item.name.startswith("savegame") and item.name != "savegameBackup":
            mods, map_title = get_savegame_mods(item)
            if mods:
                all_mods.update(mods)
                mods_per_savegame[item.name] = {
                    "map": map_title or "Unknown",
                    "mods": mods
                }
                print(f"  {item.name}: {map_title or 'Unknown'} ({len(mods)} mods)")
    
    print("-" * 50)
    print(f"Total unique mods used across all savegames: {len(all_mods)}")
    
    return all_mods, mods_per_savegame

def find_mod_usage(mod_name, mods_per_savegame):
    """Find which savegames use a specific mod."""
    savegames = []
    for sg_name, sg_data in mods_per_savegame.items():
        if mod_name in sg_data["mods"]:
            savegames.append(f"{sg_name} ({sg_data['map']})")
    return savegames

def main():
    print("=" * 60)
    print("FS25 Unused Mods Finder")
    print("=" * 60)
    
    installed_mods = get_installed_mods()
    print(f"\nInstalled mods in folder: {len(installed_mods)}")
    
    used_mods, mods_per_savegame = get_all_savegame_mods()
    
    unused_mods = installed_mods - used_mods
    missing_mods = used_mods - installed_mods
    
    print("\n" + "=" * 60)
    print(f"UNUSED MODS (installed but not in any savegame): {len(unused_mods)}")
    print("=" * 60)
    
    if unused_mods:
        for mod in sorted(unused_mods):
            print(f"  - {mod}")
    else:
        print("  (none)")
    
    if missing_mods:
        print("\n" + "=" * 60)
        print(f"WARNING: Mods referenced but NOT installed: {len(missing_mods)}")
        print("=" * 60)
        for mod in sorted(missing_mods):
            savegames = find_mod_usage(mod, mods_per_savegame)
            print(f"  - {mod}")
            for sg in savegames:
                print(f"      Used in: {sg}")
    
    print("\n" + "=" * 60)
    print("Summary")
    print("=" * 60)
    print(f"  Installed mods:      {len(installed_mods)}")
    print(f"  Used in savegames:   {len(used_mods)}")
    print(f"  Unused mods:         {len(unused_mods)}")
    print(f"  Missing mods:        {len(missing_mods)}")
    
    # Export unused mods to file
    output_file = Path(__file__).parent / "unused_mods.txt"
    with open(output_file, "w") as f:
        f.write("# Unused FS25 Mods\n")
        f.write(f"# Generated: {__import__('datetime').datetime.now()}\n")
        f.write(f"# Total unused: {len(unused_mods)}\n\n")
        for mod in sorted(unused_mods):
            f.write(f"{mod}\n")
    
    print(f"\n  List exported to: {output_file}")

if __name__ == "__main__":
    main()
