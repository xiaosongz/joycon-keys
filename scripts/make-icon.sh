#!/bin/zsh
# Regenerate scripts/AppIcon.icns from the vector AppIconView.
# Run after changing AppIconView.swift; the .icns is committed so ordinary
# builds don't need this step.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/JoyConKeys"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

"$BIN" --render-icon "$TMP/icon-1024.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done

iconutil -c icns -o scripts/AppIcon.icns "$ICONSET"
echo "wrote scripts/AppIcon.icns"
