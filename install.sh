#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/World of Warcraft/_retail_/Interface/AddOns/WoWFocus"

rsync -a --delete "$REPO/WoWFocus/" "$DEST/"
echo "WoWFocus → $DEST"
