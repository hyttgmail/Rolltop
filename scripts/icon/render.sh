#!/bin/bash
# Renders an Icon Composer document the way macOS draws it (system glass included) with
# Xcode's ictool, in every appearance and at the sizes that matter, plus contact sheets.
#
#   scripts/icon/render.sh [<document.icon>] [<out-dir>]
#
# Defaults: Rolltop/Resources/AppIcon.icon into tmp/icon-render (relative to this checkout).
# Output: <out-dir>/<Rendition>-<px>.png for Default, Dark, ClearLight, ClearDark,
# TintedLight, TintedDark at 1024/512/128/32/16 px, sheet-appearances.png (all six at
# 256 px) and sheet-sizes.png (Default at 128, 32 and 16 px, the small ones also magnified).
set -euo pipefail

cd "$(dirname "$0")/../.."
ICON=${1:-Rolltop/Resources/AppIcon.icon}
OUT=${2:-tmp/icon-render}
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ICTOOL" ]] || ICTOOL="$(xcode-select -p)/usr/bin/ictool"
[[ -x "$ICTOOL" ]] || { echo "ictool not found (needs Xcode 26 or later)" >&2; exit 1; }

mkdir -p "$OUT"
render() { # rendition px
    "$ICTOOL" "$ICON" --export-image --output-file "$OUT/$1-$2.png" --platform macOS --rendition "$1" \
        --width "$2" --height "$2" --scale 1 >/dev/null
}
for rendition in Default Dark ClearLight ClearDark TintedLight TintedDark; do
    for px in 1024 512 256 128 32 16; do render "$rendition" "$px"; done
done

SHEET="$OUT/.contact-sheet"
swiftc -O -o "$SHEET" scripts/icon/contact-sheet.swift 2>/dev/null
"$SHEET" "$OUT/sheet-appearances.png" 6 270 --bg split \
    "Default=$OUT/Default-256.png" "Dark=$OUT/Dark-256.png" "Clear light=$OUT/ClearLight-256.png" \
    "Clear dark=$OUT/ClearDark-256.png" "Tinted light=$OUT/TintedLight-256.png" "Tinted dark=$OUT/TintedDark-256.png"
"$SHEET" "$OUT/sheet-sizes.png" 6 270 --bg split \
    "128=$OUT/Default-128.png" "32=$OUT/Default-32.png" "16=$OUT/Default-16.png" \
    "32 x8=$OUT/Default-32.png@8" "16 x16=$OUT/Default-16.png@16" "dark 16 x16=$OUT/Dark-16.png@16"
rm -f "$SHEET"
echo "rendered $ICON into $OUT"
