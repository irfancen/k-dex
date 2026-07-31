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
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    # Every nested Sparkle executable must carry Developer ID + hardened
    # runtime + timestamp itself, or notarization rejects the DMG. Preserve
    # entitlements — the XPC services are sandboxed.
    for nested in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE/Versions/B/Updater.app"; do
        if [ -e "$nested" ]; then
            codesign --force --timestamp --options runtime \
                --preserve-metadata=entitlements --sign "$IDENTITY" "$nested"
        fi
    done
    codesign --force --timestamp --options runtime --sign "$IDENTITY" "$SPARKLE"
fi
# The final bundle signature occasionally fails with a transient
# errSecInternalComponent (keychain/security-agent hiccup); retry.
for attempt in 1 2 3; do
    if codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"; then
        break
    fi
    if [ "$attempt" = 3 ]; then echo "error: codesign failed after retries"; exit 1; fi
    echo "    transient codesign failure, retrying…"
    sleep 3
done
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

SHA256=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$SHA256  $DMG"

# Keep the cask template in sync; it still has to be copied to the tap repo.
CASK=packaging/homebrew/k-dex.rb
if [ -f "$CASK" ]; then
    sed -i '' \
        -e "s/^  version \".*\"/  version \"$VERSION\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" "$CASK"
    echo "==> Updated $CASK — copy it to the tap repo (Casks/k-dex.rb)"
fi
echo "==> Done: $DMG"
