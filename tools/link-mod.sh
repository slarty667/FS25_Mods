#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FS25_MODS="$HOME/Library/Application Support/FarmingSimulator2025/mods"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <ModName|path/to/mod>"
  echo "Example: $0 FS25_NaviHelper"
  exit 1
fi

ARG="$1"
if [[ -d "$ARG" ]]; then
  MOD_NAME="$(basename "$ARG")"
  MOD_SOURCE="$ARG"
else
  MOD_NAME="$ARG"
  MOD_SOURCE="$PROJECT_ROOT/mods/$MOD_NAME"
fi

if [[ ! -d "$MOD_SOURCE" ]]; then
  echo "Error: Mod not found: $MOD_SOURCE"
  exit 1
fi

MOD_ABS="$(cd "$(dirname "$MOD_SOURCE")" && pwd)/$(basename "$MOD_SOURCE")"
LINK_TARGET="$FS25_MODS/$MOD_NAME"

if [[ -L "$LINK_TARGET" ]]; then
  CURRENT="$(readlink "$LINK_TARGET")"
  if [[ "$CURRENT" == /* ]]; then
    RESOLVED_LINK="$CURRENT"
  else
    RESOLVED_LINK="$(cd "$(dirname "$LINK_TARGET")" && cd "$CURRENT" && pwd)"
  fi
  if [[ "$RESOLVED_LINK" == "$MOD_ABS" ]]; then
    echo "Already linked: $LINK_TARGET -> $MOD_SOURCE"
    exit 0
  fi
  echo "Removing existing link and re-linking."
  rm "$LINK_TARGET"
elif [[ -e "$LINK_TARGET" ]]; then
  echo "Error: $LINK_TARGET exists and is not a symlink. Remove or rename it first."
  exit 1
fi

mkdir -p "$FS25_MODS"
ln -s "$MOD_ABS" "$LINK_TARGET"
echo "Linked: $LINK_TARGET -> $MOD_SOURCE"
