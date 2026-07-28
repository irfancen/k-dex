#!/bin/bash
# Builds, signs, notarizes, and packages K-Dex as a distributable DMG.
#
# One-time prerequisites:
#   1. A "Developer ID Application" certificate in your keychain:
#      Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
#   2. Stored notarization credentials (uses an app-specific password from
#      appleid.apple.com):
#      xcrun notarytool store-credentials kdex-notary \
#        --apple-id <your-apple-id> --team-id <your-team-id> \
#        --password <app-specific-password>
#
# Usage:
#   scripts/release.sh                # full: build → sign → DMG → notarize → staple
#   SKIP_NOTARIZE=1 scripts/release.sh  # stop after the signed DMG
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' k-dex.xcodeproj/project.pbxproj | head -1)
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)
if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' certificate found in the keychain."
    echo "Create one: Xcode → Settings → Accounts → Manage Certificates → +"
    exit 1
fi
echo "==> Version $VERSION, signing as: $IDENTITY"

BUILD_DIR="$PWD/build/release"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building Release"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild -project k-dex.xcodeproj -scheme k-dex -configuration Release \
    -destination 'platform=macOS' \
    CONFIGURATION_BUILD_DIR="$BUILD_DIR" build | grep -E "error|warning: [^M]|BUILD" || true

APP="$BUILD_DIR/K-Dex.app"
[ -d "$APP" ] || { echo "error: build product missing"; exit 1; }

echo "==> Re-signing with Developer ID (hardened runtime, secure timestamp)"
if [ -x "$APP/Contents/Helpers/kubectl" ]; then
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Helpers/kubectl"
fi
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "    signature OK"

DMG="build/K-Dex-$VERSION.dmg"
echo "==> Creating $DMG"
rm -f "$DMG"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "K-Dex" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGING"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
    echo "==> Skipping notarization (SKIP_NOTARIZE=1)"
else
    echo "==> Notarizing (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile kdex-notary --wait
    xcrun stapler staple "$DMG"
    echo "    notarized + stapled"
fi

echo "==> Generating Sparkle appcast"
SPARKLE_BIN=$(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -path "*artifacts/sparkle/Sparkle/bin" 2>/dev/null | head -1)
if [ -n "$SPARKLE_BIN" ]; then
    "$SPARKLE_BIN/generate_appcast" build \
        --download-url-prefix "https://github.com/irfancen/k-dex/releases/download/v$VERSION/" \
        -o build/appcast.xml
    echo "    build/appcast.xml (upload as a release asset alongside the DMG)"
else
    echo "warning: Sparkle tools not found in DerivedData; skipping appcast"
fi

shasum -a 256 "$DMG"
echo "==> Done: $DMG"
