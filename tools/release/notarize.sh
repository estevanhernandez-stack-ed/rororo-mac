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

echo "==> [2/8] Extract .app from archive"
# We bypass `xcodebuild -exportArchive` here. exportArchive has a long
# history of failing with "No signing certificate 'Developer ID Application'
# found" in CI environments where the archive step succeeded — the two
# code paths resolve signing identities differently and exportArchive's
# search-list handling is finicky across step boundaries. The archive
# step already signed the .app with the Developer ID cert + Hardened
# Runtime (required for notarization), so the .xcarchive's
# Products/Applications/RORORO.app is essentially what exportArchive
# would have produced for `developer-id` distribution.
#
# Verified by `codesign --verify` below — if the archive's signature
# isn't intact, this fails fast before notarization gets the work.
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE_PATH/Products/Applications/RORORO.app" "$APP_PATH"
codesign --verify --verbose=4 "$APP_PATH"

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::App copy failed — $APP_PATH not found."
  exit 1
fi

echo "==> [2.5/8] Re-sign nested binaries with secure timestamp + Hardened Runtime"
# Sparkle ships pre-signed helper binaries (Updater.app, Autoupdate,
# XPCServices/Downloader.xpc, XPCServices/Installer.xpc) signed by the
# Sparkle Project's cert. Notarization requires every binary in the
# bundle signed with our Developer ID + secure timestamp + Hardened Runtime.
#
# `--deep` descends into all code-signable nested binaries (.xpc, embedded
# .app, helper executables, frameworks) and re-signs each with our cert.
# Apple discourages --deep for general use because it applies the parent's
# entitlements to children, but Sparkle's helpers ship without conflicting
# entitlements so this is safe here. We --verify --deep --strict afterward
# to fail fast if anything is mis-signed before the notary submission.

codesign --force --deep --timestamp --options runtime \
  --sign "$MACOS_CERTIFICATE_NAME" "$APP_PATH"

echo "    verify: --deep --strict"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "==> [3/8] Zip the .app for notarytool submission"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> [4/8] Submit to Apple notary service (waits for ticket)"
SUBMIT_OUTPUT="$(xcrun notarytool submit "$ZIP_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --wait 2>&1)"
echo "$SUBMIT_OUTPUT"

# notarytool exits 0 even on `status: Invalid` — Apple's "we accepted the
# submission but rejected the binary". Catch that explicitly + fetch the
# detailed log so future-us doesn't have to chase the submission id.
SUBMISSION_ID="$(echo "$SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*id:[[:space:]]+([a-f0-9-]+).*/\1/p' | head -n 1)"
NOTARY_STATUS="$(echo "$SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*status:[[:space:]]+(.+)$/\1/p' | tail -n 1)"

if [[ "$NOTARY_STATUS" != "Accepted" ]]; then
  echo "::error::Notarization status is '$NOTARY_STATUS' (id=$SUBMISSION_ID)."
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "==> Fetching notarization log for diagnostic"
    xcrun notarytool log "$SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_NOTARY_PASSWORD" || true
  fi
  exit 1
fi

echo "==> [5/8] Staple the notary ticket onto the .app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

echo "==> [6/8] Build a DMG from the stapled .app"
hdiutil create \
  -volname RORORO \
  -srcfolder "$EXPORT_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> [6.5/8] Submit the DMG to the notary service"
# The .app's notary ticket lives inside the .app and survives DMG copy,
# but the DMG envelope itself also needs a ticket so first-mount Gatekeeper
# checks pass without a network round-trip. Submit + wait + staple.
DMG_SUBMIT_OUTPUT="$(xcrun notarytool submit "$DMG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --wait 2>&1)"
echo "$DMG_SUBMIT_OUTPUT"
DMG_STATUS="$(echo "$DMG_SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*status:[[:space:]]+(.+)$/\1/p' | tail -n 1)"
DMG_SUBMISSION_ID="$(echo "$DMG_SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*id:[[:space:]]+([a-f0-9-]+).*/\1/p' | head -n 1)"

if [[ "$DMG_STATUS" != "Accepted" ]]; then
  echo "::error::DMG notarization status is '$DMG_STATUS' (id=$DMG_SUBMISSION_ID)."
  if [[ -n "$DMG_SUBMISSION_ID" ]]; then
    xcrun notarytool log "$DMG_SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_NOTARY_PASSWORD" || true
  fi
  exit 1
fi

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
