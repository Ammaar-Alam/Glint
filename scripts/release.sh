#!/bin/bash
# builds, signs, notarizes and staples build/Glint-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
identity="${GLINT_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
profile="${GLINT_NOTARY_PROFILE:-glint-notary}"
if [[ -z "$identity" ]]; then
    echo "No Developer ID Application certificate found. Set GLINT_SIGNING_IDENTITY." >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
GLINT_SIGNING_IDENTITY="$identity" scripts/build-app.sh release
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
ditto build/Glint.app "$staging/Glint.app"
ln -s /Applications "$staging/Applications"
dmg="build/Glint-$version.dmg"
rm -f "$dmg"
hdiutil create -volname Glint -srcfolder "$staging" -format UDZO -quiet "$dmg"
codesign --force --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "$dmg"
