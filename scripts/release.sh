#!/bin/bash
# Builds Spoof.app and packs Spoof.dmg. `scripts/release.sh v1.0.1` also publishes it on GitHub.
# Needs xcodegen, Xcode 27 and dmgbuild (pip install dmgbuild). Sign ad hoc: no Developer ID here.
# Only building needs Xcode. People running Spoof don't: it carries its own helper.
set -euo pipefail
cd "$(dirname "$0")/.."

(cd mac && xcodegen generate >/dev/null && xcodebuild -scheme Spoof -configuration Release -derivedDataPath build build -quiet)
app=mac/build/Build/Products/Release/Spoof.app

scripts/build-helper.sh
mkdir -p "$app/Contents/Helpers"
cp helper/build/dist/spoof-helper "$app/Contents/Helpers/spoof-helper"
cp helper/LICENSE "$app/Contents/Resources/spoof-helper-LICENSE.txt"
codesign --force --sign - "$app/Contents/Helpers/spoof-helper"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"

rm -f Spoof.dmg
dmgbuild -s scripts/dmg.py -D app="$app" Spoof Spoof.dmg
hdiutil verify Spoof.dmg >/dev/null

if [ $# -gt 0 ]; then
    gh release create "$1" Spoof.dmg --title "Spoof ${1#v}" --notes "Download **Spoof.dmg** below."
fi
