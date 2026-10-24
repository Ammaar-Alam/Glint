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
# signs the dmg with the update key in the login keychain and lists it first in appcast.xml
signature="$(.build/artifacts/sparkle/Sparkle/bin/sign_update "$dmg")"
build="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)"
minimum="$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" Resources/Info.plist)"
item="    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <link>https://github.com/Ammaar-Alam/Glint/releases/tag/$version</link>
      <enclosure url=\"https://github.com/Ammaar-Alam/Glint/releases/download/$version/Glint-$version.dmg\" type=\"application/octet-stream\" $signature/>
    </item>"
# a rerun replaces this version's entry instead of adding a second one
VERSION="$version" perl -0pi -e 's{\n\s*<item>(?:(?!</item>).)*?<sparkle:shortVersionString>\Q$ENV{VERSION}\E</sparkle:shortVersionString>.*?</item>}{}s' appcast.xml
ITEM="$item" perl -0pi -e 's{(<title>Glint</title>\n)}{$1$ENV{ITEM}\n}' appcast.xml
echo "$dmg"
echo "Publish the release, then push appcast.xml to main so installed copies see it"
