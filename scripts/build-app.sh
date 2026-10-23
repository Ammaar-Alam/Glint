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
bundle="$PWD/build/Clipt.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
install -S -m 755 "$binary_directory/Clipt" "$bundle/Contents/MacOS/Clipt"
install -S -m 644 Resources/Info.plist "$bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
codesign --force --sign "${CLIPT_SIGNING_IDENTITY:--}" "$bundle"
codesign --verify --strict "$bundle"
echo "$bundle"
