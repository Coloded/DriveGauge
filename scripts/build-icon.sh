#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCE_ICON="Resources/AppIcon.png"
FINAL_ICON="Resources/DriveGaugeIconV2.icns"

test -f "$SOURCE_ICON"
/usr/bin/python3 Tools/build_icns.py
test -f "$FINAL_ICON"
