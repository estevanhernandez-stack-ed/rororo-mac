#!/usr/bin/env bash
# tools/release/generate-appcast.sh — emit dist/appcast.xml from GitHub
# releases, signed with the Sparkle EdDSA private key.

set -euo pipefail

# ---------------------------------------------------------------------------
# Required env vars.
# ---------------------------------------------------------------------------
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required (raw EdDSA private key from generate_keys; lives in 1Password + GitHub Secrets)}"
: "${GITHUB_REPO:?GITHUB_REPO is required (owner/repo, e.g., estevanhernandez-stack-ed/rororo-mac)}"
: "${GH_TOKEN:?GH_TOKEN is required (GitHub auth for gh CLI)}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APPCAST_PATH="$DIST_DIR/appcast.xml"
DOWNLOAD_DIR="$REPO_ROOT/build/appcast"
APPCAST_FEED_URL="https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml"
COMPAT_SOURCE="$REPO_ROOT/tools/release/roblox-compat.json"
COMPAT_DEST="$DIST_DIR/roblox-compat.json"

mkdir -p "$DIST_DIR" "$DOWNLOAD_DIR"

# Copy the compat config (semaphore name + known-good Roblox version)
# to dist/ so it gets published to gh-pages alongside the appcast. The
# in-app RobloxCompatStore fetches this URL at boot — lets us patch
# semaphore-name renames within minutes without cutting an app release.
# For OUT-OF-BAND updates (no new tag), git-push the updated file
# directly to the gh-pages branch.
if [[ -f "$COMPAT_SOURCE" ]]; then
  cp "$COMPAT_SOURCE" "$COMPAT_DEST"
  echo "Copied roblox-compat.json into dist/"
else
  echo "::warning::roblox-compat.json source missing at $COMPAT_SOURCE; gh-pages will not include it this run."
fi

# ---------------------------------------------------------------------------
# Resolve sign_update binary.
# ---------------------------------------------------------------------------
resolve_sign_update() {
  if [[ -n "${SPARKLE_SIGN_UPDATE_PATH:-}" && -x "$SPARKLE_SIGN_UPDATE_PATH" ]]; then
    echo "$SPARKLE_SIGN_UPDATE_PATH"
    return 0
  fi
  local candidate
  # Sparkle 2.9+ ships sign_update under SourcePackages/artifacts/sparkle/...,
  # not SourcePackages/checkouts/Sparkle/bin/ (that path only carries the
  # legacy DSA scripts). The find below catches both layouts but excludes
  # old_dsa_scripts so we don't accidentally pick up the legacy DSA-only
  # tool against an EdDSA key.
  candidate="$(find "$HOME/Library/Developer/Xcode/DerivedData" -name sign_update -type f -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -n 1 || true)"
  if [[ -z "$candidate" ]]; then
    candidate="$(find "$REPO_ROOT" -name sign_update -type f -not -path '*/old_dsa_scripts/*' 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$candidate" ]]; then
    echo "::error::Could not locate Sparkle's sign_update utility. Resolve SPM dependencies first (xcodebuild -resolvePackageDependencies), then re-run." >&2
    exit 1
  fi
  echo "$candidate"
}

SIGN_UPDATE="$(resolve_sign_update)"
echo "Using sign_update: $SIGN_UPDATE"

# Write the EdDSA private key to a tmp file (sign_update -f reads from path).
TMP_KEY="$(mktemp -t sparkle_ed_key.XXXXXX)"
trap 'rm -f "$TMP_KEY"' EXIT
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$TMP_KEY"
chmod 600 "$TMP_KEY"

# ---------------------------------------------------------------------------
# Pull the release list (newest-first by createdAt) directly from the GitHub
# REST API — `gh release list --json` doesn't expose `assets` in older gh
# CLI versions (and the runner version varies). The REST endpoint is stable.
# Normalize field names so the rest of the script is unchanged.
# ---------------------------------------------------------------------------
RELEASES_JSON="$(gh api "repos/$GITHUB_REPO/releases?per_page=50" \
  --jq '[.[] | {
    tagName: .tag_name,
    name: (.name // .tag_name),
    createdAt: .created_at,
    isPrerelease: .prerelease,
    assets: [.assets[] | {name: .name, url: .url, browser_download_url: .browser_download_url}]
  }] | sort_by(.createdAt) | reverse')"

# ---------------------------------------------------------------------------
# Render appcast head.
# ---------------------------------------------------------------------------
{
  cat <<XMLHEAD
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>RORORO Updates</title>
        <link>${APPCAST_FEED_URL}</link>
        <description>Latest RORORO updates</description>
        <language>en</language>
XMLHEAD
} > "$APPCAST_PATH"

# ---------------------------------------------------------------------------
# Per-release: download DMG asset, compute EdDSA signature, emit <item>.
# ---------------------------------------------------------------------------
RELEASE_COUNT="$(echo "$RELEASES_JSON" | jq 'length')"
echo "Processing $RELEASE_COUNT releases"

for i in $(seq 0 $((RELEASE_COUNT - 1))); do
  RELEASE="$(echo "$RELEASES_JSON" | jq ".[$i]")"
  TAG="$(echo "$RELEASE" | jq -r '.tagName')"
  NAME="$(echo "$RELEASE" | jq -r '.name // .tagName')"
  CREATED_AT="$(echo "$RELEASE" | jq -r '.createdAt')"
  IS_PRERELEASE="$(echo "$RELEASE" | jq -r '.isPrerelease')"

  DMG_ASSET_URL="$(echo "$RELEASE" | jq -r '[.assets[] | select(.name | endswith(".dmg"))][0].url // empty')"
  DMG_ASSET_NAME="$(echo "$RELEASE" | jq -r '[.assets[] | select(.name | endswith(".dmg"))][0].name // empty')"
  if [[ -z "$DMG_ASSET_URL" ]]; then
    echo "  skip $TAG — no .dmg asset"
    continue
  fi

  VERSION="${TAG#v}"

  TAG_DIR="$DOWNLOAD_DIR/$TAG"
  mkdir -p "$TAG_DIR"
  echo "  download $TAG → $TAG_DIR/$DMG_ASSET_NAME"
  gh release download "$TAG" \
    --repo "$GITHUB_REPO" \
    --pattern '*.dmg' \
    --dir "$TAG_DIR" \
    --clobber

  DMG_LOCAL="$TAG_DIR/$DMG_ASSET_NAME"
  if [[ ! -f "$DMG_LOCAL" ]]; then
    echo "::warning::Download failed for $TAG — skipping."
    continue
  fi

  LENGTH="$(stat -f%z "$DMG_LOCAL")"

  SIGN_OUTPUT="$("$SIGN_UPDATE" -f "$TMP_KEY" "$DMG_LOCAL")"
  ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -nE 's/.*sparkle:edSignature="([^"]+)".*/\1/p')"
  if [[ -z "$ED_SIGNATURE" ]]; then
    echo "::error::sign_update produced no signature for $TAG. Output: $SIGN_OUTPUT"
    exit 1
  fi

  PUBLIC_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$DMG_ASSET_NAME"

  PUB_DATE="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$CREATED_AT" "+%a, %d %b %Y %H:%M:%S +0000" 2>/dev/null \
             || echo "$CREATED_AT")"

  CHANNEL_BLOCK=""
  if [[ "$IS_PRERELEASE" == "true" ]]; then
    CHANNEL_BLOCK="            <sparkle:channel>prerelease</sparkle:channel>"
  fi

  cat <<XMLITEM >> "$APPCAST_PATH"
        <item>
            <title>${NAME}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
${CHANNEL_BLOCK}
            <enclosure
                url="${PUBLIC_DOWNLOAD_URL}"
                length="${LENGTH}"
                type="application/octet-stream"
                sparkle:edSignature="${ED_SIGNATURE}"/>
        </item>
XMLITEM
  echo "  emitted item for $TAG (prerelease=$IS_PRERELEASE)"
done

# ---------------------------------------------------------------------------
# Render appcast tail.
# ---------------------------------------------------------------------------
{
  cat <<XMLTAIL
    </channel>
</rss>
XMLTAIL
} >> "$APPCAST_PATH"

echo "Wrote $APPCAST_PATH"
