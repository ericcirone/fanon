#!/bin/bash
# Builds a signed, notarized and stapled dist/Fanon-<version>.dmg holding both apps, plus its SHA-256.
#
# Usage: scripts/release.sh [version]        (version defaults to the one in Resources/Fanon-Info.plist)
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool keychain profile,
# created once with:
#   xcrun notarytool store-credentials fanon --apple-id <apple id> --team-id <team id>
#
# SIGN_IDENTITY   signing identity (default "Developer ID Application", which works if you have one such certificate)
# NOTARY_PROFILE  notarytool keychain profile (default "fanon")
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(plutil -extract CFBundleShortVersionString raw Resources/Fanon-Info.plist)}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-fanon}"
DMG="dist/Fanon-$VERSION.dmg"

SIGN_IDENTITY="$IDENTITY" VERSION="$VERSION" ./scripts/build-app.sh

# Disk image with both apps and a shortcut to drag them into.
STAGE="$(mktemp -d)/Fanon"
mkdir -p "$STAGE"
ditto "dist/Fanon.app" "$STAGE/Fanon.app"
ditto "dist/Fanon Bridge.app" "$STAGE/Fanon Bridge.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Fanon $VERSION" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "Submitting $DMG for notarization (this usually takes a few minutes)…"
RESULT="$(mktemp)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$RESULT" || true
STATUS="$(plutil -extract status raw "$RESULT" 2>/dev/null || echo unknown)"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization failed: $STATUS" >&2
    cat "$RESULT" >&2
    if ID="$(plutil -extract id raw "$RESULT" 2>/dev/null)"; then
        xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2
    fi
    exit 1
fi

xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"

( cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
echo "Ready: $DMG"
cat "$DMG.sha256"
