#!/usr/bin/env bash
# tools/release/notarize.sh — sign + notarize + DMG the RORORO app.
#
# Local + CI runner. Preconditions:
#   1. xcodegen has produced App/RORORO.xcodeproj.
#   2. The Apple Developer ID Application cert is in the active keychain
#      (or imported by the GitHub Actions workflow before this runs).
#   3. The four env vars below are set.

set -euo pipefail

# ---------------------------------------------------------------------------
# Required env vars — fail fast with a clear error if any are missing.
# ---------------------------------------------------------------------------
: "${APPLE_ID:?APPLE_ID is required (Apple Developer Apple ID email)}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required (10-char Apple Developer team ID)}"
: "${APPLE_NOTARY_PASSWORD:?APPLE_NOTARY_PASSWORD is required (app-specific password from appleid.apple.com)}"
: "${MACOS_CERTIFICATE_NAME:?MACOS_CERTIFICATE_NAME is required (e.g., \"Developer ID Application: Estevan Hernandez (XXXXXXXXXX)\")}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/RORORO.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/tools/release/exportOptions.plist"
APP_PATH="$EXPORT_DIR/RORORO.app"
ZIP_PATH="$BUILD_DIR/RORORO.zip"
DMG_PATH="$BUILD_DIR/RORORO.dmg"
PROJECT_PATH="$REPO_ROOT/App/RORORO.xcodeproj"
SCHEME="RORORO"

mkdir -p "$BUILD_DIR"

echo "==> [1/8] Archive (xcodebuild archive, Release config, manual signing)"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$MACOS_CERTIFICATE_NAME" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  | xcpretty || true
# xcpretty is optional — if not installed, xcodebuild still ran. Verify the
# archive landed.
if [[ ! -d "$ARCHIVE_PATH" ]]; then
  echo "::error::Archive failed — $ARCHIVE_PATH not created."
  exit 1
fi

echo "==> [2/8] Export archive (developer-id distribution)"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::Export failed — $APP_PATH not found."
  exit 1
fi

echo "==> [3/8] Zip the .app for notarytool submission"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> [4/8] Submit to Apple notary service (waits for ticket)"
xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --wait

echo "==> [5/8] Staple the notary ticket onto the .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> [6/8] Build a notarized DMG"
hdiutil create \
  -volname RORORO \
  -srcfolder "$EXPORT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> [7/8] Staple the DMG"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> [8/8] Done"
echo "DMG: $DMG_PATH"

# GitHub Actions output (modern + legacy syntax for compatibility).
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "dmg=$DMG_PATH" >> "$GITHUB_OUTPUT"
fi
echo "::set-output name=dmg::$DMG_PATH"
