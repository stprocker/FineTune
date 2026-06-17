#!/bin/bash
#
# FineTune Fork — local Release build + DMG packaging (personal use).
#
# Produces a Developer ID-signed "FineTune Fork.app" and wraps it in a
# drag-to-Applications .dmg under ./build/. No notarization: this is for
# running on your own Mac, and a locally built app carries no quarantine
# flag, so Gatekeeper does not block it.
#
# Why this was rewritten: the old script targeted "FineTune.xcodeproj"
# (the real project is "finetune_fork.xcodeproj"), expected a product named
# "FineTune.app" (it is now "FineTune Fork.app"), and relied on an
# archive/exportArchive flow with a TEAM_ID_PLACEHOLDER plus `npx create-dmg`
# (Node + GraphicsMagick). It now builds directly and packages with hdiutil,
# so the only dependency is Xcode.
#
# Usage:   scripts/build-dmg.sh
#
# Override signing via env vars if needed:
#   SIGN_IDENTITY="-" scripts/build-dmg.sh                       # ad-hoc sign
#   SIGN_IDENTITY="Developer ID Application: ..." TEAM_ID=XXXXXX scripts/build-dmg.sh
#
# For real distribution (outside your own Mac) you would additionally
# notarize + staple the .app/.dmg with `xcrun notarytool` and `xcrun stapler`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DIR="$PROJECT_DIR/.build_release"

PROJECT="$PROJECT_DIR/finetune_fork.xcodeproj"
SCHEME="FineTune"
APP_NAME="FineTune Fork"

# Defaults to Alex's Developer ID; override with the env vars above.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Alexander Copp (LPC54PBK79)}"
TEAM_ID="${TEAM_ID:-LPC54PBK79}"

echo "==> Cleaning build output..."
rm -rf "$BUILD_DIR" "$DERIVED_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building Release ($APP_NAME, signing identity: $SIGN_IDENTITY)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    build

APP_PATH="$DERIVED_DIR/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: expected build product not found: $APP_PATH" >&2
    exit 1
fi

echo "==> Verifying signature..."
codesign --verify --deep --strict --verbose=1 "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo '1.0')"
DMG_PATH="$BUILD_DIR/$APP_NAME $VERSION.dmg"

echo "==> Staging DMG contents..."
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag-to-install target

echo "==> Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

# Sign the DMG too (optional; harmless for local use).
if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH" \
        || echo "WARN: could not sign the DMG (continuing; the .app inside is signed)."
fi

echo ""
echo "==> Done."
echo "    App: $APP_PATH"
echo "    DMG: $DMG_PATH"
ls -lh "$DMG_PATH"
