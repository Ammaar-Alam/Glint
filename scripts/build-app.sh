#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
if [[ "$configuration" != "release" && "$configuration" != "debug" ]]; then
    echo "Usage: scripts/build-app.sh [release|debug]" >&2
    exit 2
fi
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
bundle="$PWD/build/Glint.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -S -m 755 "$binary_directory/Glint" "$bundle/Contents/MacOS/Glint"
install -S -m 644 Resources/Info.plist "$bundle/Contents/Info.plist"
install -S -m 644 LICENSE "$bundle/Contents/Resources/LICENSE.txt"
install -S -m 644 assets/glint-mark.svg "$bundle/Contents/Resources/glint-mark.svg"
swift scripts/make-icon.swift assets/glint-icon.svg "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign "${GLINT_SIGNING_IDENTITY:--}" "$bundle"
codesign --verify --strict "$bundle"
echo "$bundle"
