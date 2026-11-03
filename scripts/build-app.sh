#!/bin/bash
# Builds Fanon.app and "Fanon Bridge.app" (Apple Silicon, or universal with --universal) into ./dist.
#
# SIGN_IDENTITY  signing identity (default "-", ad-hoc); use a "Developer ID Application" certificate to distribute
# VERSION        stamps CFBundleShortVersionString and CFBundleVersion into both apps
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHS=(--arch arm64)
if [[ "${1:-}" == "--universal" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi

IDENTITY="${SIGN_IDENTITY:--}"
SIGN=(codesign --force --options runtime --sign "$IDENTITY")
# Notarization needs a secure timestamp; ad-hoc signatures can't have one.
if [[ "$IDENTITY" != "-" ]]; then SIGN+=(--timestamp); fi

for product in FanonBridge FanonApp fanon; do
    swift build -c release "${ARCHS[@]}" --product "$product"
done
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift scripts/make-icon.swift "$ICONSET"
ICNS="$(dirname "$ICONSET")/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# make_app <bundle name> <executable> <Info.plist>
make_app() {
    local app="dist/$1.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$3" "$app/Contents/Info.plist"
    if [[ -n "${VERSION:-}" ]]; then
        plutil -replace CFBundleShortVersionString -string "$VERSION" "$app/Contents/Info.plist"
        plutil -replace CFBundleVersion -string "$VERSION" "$app/Contents/Info.plist"
    fi
    cp "$BIN/$2" "$app/Contents/MacOS/$2"
    cp "$BIN/fanon" "$app/Contents/MacOS/fanon"
    cp "$ICNS" "$app/Contents/Resources/AppIcon.icns"
    # Sign the helper first, then the bundle (which seals it), both with the hardened runtime.
    "${SIGN[@]}" "$app/Contents/MacOS/fanon"
    "${SIGN[@]}" "$app"
    codesign --verify --strict "$app"
    lipo -info "$app/Contents/MacOS/$2"
    echo "Built $app"
}

make_app "Fanon Bridge" FanonBridge Resources/FanonBridge-Info.plist
make_app Fanon FanonApp Resources/Fanon-Info.plist
