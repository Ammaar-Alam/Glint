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
rm -rf "$bundle/Contents/Frameworks"
mkdir -p "$bundle/Contents/Frameworks"
ditto "$binary_directory/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
install -S -m 644 Resources/Info.plist "$bundle/Contents/Info.plist"
install -S -m 644 LICENSE "$bundle/Contents/Resources/LICENSE.txt"
install -S -m 644 assets/glint-mark.svg "$bundle/Contents/Resources/glint-mark.svg"
swift scripts/make-icon.swift assets/glint-icon.svg "$PWD/build/AppIcon.iconset"
iconutil -c icns build/AppIcon.iconset -o "$bundle/Contents/Resources/AppIcon.icns"
identity="${GLINT_SIGNING_IDENTITY:--}"
# hardened runtime and a timestamp are required for notarization
flags=(--force --sign "$identity")
[[ "$identity" != "-" ]] && flags+=(--options runtime --timestamp)
# Sparkle's helpers are signed inside out before the framework and the app
sparkle="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${flags[@]}" "$sparkle/XPCServices/Installer.xpc"
codesign "${flags[@]}" --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
codesign "${flags[@]}" "$sparkle/Autoupdate"
codesign "${flags[@]}" "$sparkle/Updater.app"
codesign "${flags[@]}" "$bundle/Contents/Frameworks/Sparkle.framework"
codesign "${flags[@]}" --entitlements Resources/Glint.entitlements "$bundle"
codesign --verify --strict "$bundle"
echo "$bundle"
