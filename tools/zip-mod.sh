#!/usr/bin/env bash
set -euo pipefail
MOD_DIR="$1"
MOD_NAME="$(basename "$MOD_DIR")"
PARENT="$(cd "$(dirname "$MOD_DIR")/.." && pwd)"
(cd "$(dirname "$MOD_DIR")" && zip -r "../${MOD_NAME}.zip" "$MOD_NAME" -x "*.DS_Store")
echo "Built: ${PARENT}/${MOD_NAME}.zip"
