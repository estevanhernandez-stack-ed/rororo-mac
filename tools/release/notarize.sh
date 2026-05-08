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
: "${MACOS_CERTIFICATE_NAME:?MACOS_CERTIFICATE_NAME is required (e.g., \"Developer ID Application: Estevan Hernandez (XXXXXXXXXX)\") — signs the .app}"
: "${MACOS_INSTALLER_CERTIFICATE_NAME:?MACOS_INSTALLER_CERTIFICATE_NAME is required (e.g., \"Developer ID Installer: Estevan Hernandez (XXXXXXXXXX)\") — signs the .pkg. Distinct cert from the Application cert; generate at https://developer.apple.com/account/resources/certificates/add and upload as a separate p12 secret. See tools/release/README.md.}"
: "${TAG_NAME:?TAG_NAME is required (the v* tag firing the release)}"

# Marketing version is the human-readable version (e.g. "0.2.3"); build
# number is monotonic across all commits (commit count from git). The
# build number drives Sparkle's update detection — v0.2.0..v0.2.2 all
# shipped with CFBundleVersion=2 (frozen at Phase 0), so existing clients
# saw appcast versions like "0.2.x" and Sparkle's dotted-numeric compare
# treated their local "2" (= "2.0.0") as NEWER than "0.2.x". Caught at
# v0.2.2 manual smoke 2026-05-07: "You're up to date" lie.
#
# Computing build number from `git rev-list --count HEAD` gives a
# monotonic integer well past 2, so existing v0.2.x users ("2") will
# correctly see the appcast as offering an update. release.yml passes
# BUILD_NUMBER explicitly via env to avoid relying on git availability
# inside this script.
: "${BUILD_NUMBER:?BUILD_NUMBER is required (monotonic build number; computed in release.yml from git rev-list --count HEAD)}"

VERSION_NUMBER="${TAG_NAME#v}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/RORORO.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$REPO_ROOT/tools/release/exportOptions.plist"
APP_PATH="$EXPORT_DIR/RORORO.app"
ZIP_PATH="$BUILD_DIR/RORORO.zip"
PKG_PATH="$BUILD_DIR/RORORO.pkg"
PROJECT_PATH="$REPO_ROOT/App/RORORO.xcodeproj"
SCHEME="RORORO"

mkdir -p "$BUILD_DIR"

echo "==> [1/8] Archive (xcodebuild archive, Release config, manual signing)"
echo "    MARKETING_VERSION=$VERSION_NUMBER  CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$MACOS_CERTIFICATE_NAME" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  MARKETING_VERSION="$VERSION_NUMBER" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
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

echo "==> [6/8] Build a signed .pkg installer wrapping the stapled .app"
# v0.2.5: pivoted from .dmg to .pkg. Across v0.2.0..v0.2.4 the DMG path
# never converged on a clean install UX — branded DMG fought Finder
# layout cache, barebones DMG made users drag the .app to /Applications
# manually (which several missed, ending up running RORORO from
# /Volumes/RORORO indefinitely until the launch surface broke).
#
# .pkg is the right shape: user double-clicks → macOS Installer.app
# walks the standard "Continue / Install" flow → admin password →
# .app lands in /Applications atomically. No layout, no drag, no
# "did you remember to move it?" footgun.
#
# productbuild's --component flag wraps a single .app into a flat .pkg
# whose payload installs to /Applications. Signed with the Developer ID
# Installer cert (distinct from the Developer ID Application cert that
# signed the .app — Apple separates "I made this app" trust from
# "I made this installer" trust, and notarization checks both).
rm -f "$PKG_PATH"
productbuild \
  --component "$APP_PATH" /Applications \
  --sign "$MACOS_INSTALLER_CERTIFICATE_NAME" \
  --version "$VERSION_NUMBER" \
  "$PKG_PATH"

if [[ ! -f "$PKG_PATH" ]]; then
  echo "::error::productbuild failed — $PKG_PATH not created."
  exit 1
fi

# Sanity: confirm the pkg is signed before submitting to notary.
echo "    verify: pkgutil --check-signature"
pkgutil --check-signature "$PKG_PATH"

echo "==> [6.5/8] Submit the .pkg to the notary service"
# notarytool ingests .pkg natively. Apple's notary checks both the
# pkg's installer signature (Developer ID Installer) and every
# binary in the payload (Developer ID Application). Both must
# resolve cleanly or notarization rejects.
PKG_SUBMIT_OUTPUT="$(xcrun notarytool submit "$PKG_PATH" \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --wait 2>&1)"
echo "$PKG_SUBMIT_OUTPUT"
PKG_STATUS="$(echo "$PKG_SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*status:[[:space:]]+(.+)$/\1/p' | tail -n 1)"
PKG_SUBMISSION_ID="$(echo "$PKG_SUBMIT_OUTPUT" | sed -nE 's/^[[:space:]]*id:[[:space:]]+([a-f0-9-]+).*/\1/p' | head -n 1)"

if [[ "$PKG_STATUS" != "Accepted" ]]; then
  echo "::error::PKG notarization status is '$PKG_STATUS' (id=$PKG_SUBMISSION_ID)."
  if [[ -n "$PKG_SUBMISSION_ID" ]]; then
    xcrun notarytool log "$PKG_SUBMISSION_ID" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_NOTARY_PASSWORD" || true
  fi
  exit 1
fi

echo "==> [7/8] Staple the .pkg"
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"

echo "==> [8/8] Done"
echo "PKG: $PKG_PATH"

# GitHub Actions output (modern + legacy syntax for compatibility).
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "pkg=$PKG_PATH" >> "$GITHUB_OUTPUT"
fi
echo "::set-output name=pkg::$PKG_PATH"
