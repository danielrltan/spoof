#!/bin/bash
# Builds Spoof.app and packs Spoof.dmg. `scripts/release.sh v1.0.1` also publishes it on GitHub.
# Needs xcodegen, Xcode 27 and dmgbuild (pip install dmgbuild). Sign ad hoc: no Developer ID here.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd mac && xcodegen generate >/dev/null && xcodebuild -scheme Spoof -configuration Release -derivedDataPath build build -quiet)
app=mac/build/Build/Products/Release/Spoof.app
codesign --force --deep --sign - "$app"
codesign --verify --strict "$app"

rm -f Spoof.dmg
dmgbuild -s scripts/dmg.py -D app="$app" Spoof Spoof.dmg
hdiutil verify Spoof.dmg >/dev/null

if [ $# -gt 0 ]; then
    gh release create "$1" Spoof.dmg --title "Spoof ${1#v}" --notes "Download **Spoof.dmg** below."
fi
