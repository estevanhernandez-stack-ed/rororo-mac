# RORORO Mac release tooling

Operational scripts and the GitHub Actions workflow that turn a `v*` git
tag into a notarized DMG attached to a GitHub Release, plus a regenerated
Sparkle appcast published to gh-pages.

## How it works

```
git tag v0.1.0  →  push  →  .github/workflows/release.yml triggers
                                  │
                                  ├─ archive + sign (notarize.sh)
                                  ├─ submit to Apple notary, staple
                                  ├─ build + staple DMG
                                  ├─ attach DMG to Release page
                                  ├─ regenerate appcast (generate-appcast.sh)
                                  └─ publish dist/ to gh-pages
                                                │
                                                ▼
                       https://626labs.github.io/rororo-mac/appcast.xml
                                                │
                                                ▼
                    Sparkle clients next-launch → prompt + download
```

The workflow lives at `.github/workflows/release.yml`. The two scripts
(`notarize.sh`, `generate-appcast.sh`) work locally too — useful for
dry-runs before tagging.

## Bootstrap (one-time, before the first `v*` tag)

CI is red on tag pushes until all four steps are done. That's the
deferred-bootstrap contract — code lands now, secrets get uploaded later.

### 1. Generate the Sparkle EdDSA keypair

After `xcodebuild -resolvePackageDependencies` resolves Sparkle (run it
once locally), the helper binaries are at
`~/Library/Developer/Xcode/DerivedData/RORORO-*/SourcePackages/checkouts/Sparkle/bin/`.

Run `generate_keys`:

```bash
cd ~/Library/Developer/Xcode/DerivedData/RORORO-*/SourcePackages/checkouts/Sparkle/bin
./generate_keys
```

It prints:

```
Public key:  <base64-string>
```

…and stores the private key in the macOS Keychain under
`https://sparkle-project.org`.

Three things happen with those:

- **Public key** — paste it into `App/RORORO/Info.plist`, replacing
  `REPLACE_WITH_GENERATED_PUBLIC_KEY` in the `SUPublicEDKey` entry. In the
  same commit, flip `SUEnableAutomaticChecks` to `<true/>` and change
  `UpdaterHost.bootIfNeeded()`'s `startingUpdater: false` → `true`. Commit.
- **Private key** — export from Keychain:

  ```bash
  security find-generic-password -s "https://sparkle-project.org" -w
  ```

  Store the output in 1Password under `RORORO Mac / Sparkle Private Key`.

- **Private key (CI)** — upload the same value to GitHub Secrets as
  `SPARKLE_ED_PRIVATE_KEY` (Settings → Secrets and variables → Actions →
  New repository secret).

If the private key is ever lost, every existing Sparkle client refuses to
update from the new key (one-way break). Don't lose it.

### 2. Apple Developer ID certificate

In Keychain Access, find your Developer ID Application cert. Export as
`cert.p12` (right-click → Export → set a passphrase). Then:

```bash
base64 -i cert.p12 | pbcopy
```

Upload to GitHub Secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | the base64 blob just copied to your clipboard |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export passphrase you set |
| `MACOS_CERTIFICATE_NAME` | the cert's exact name, e.g., `Developer ID Application: Estevan Hernandez (XXXXXXXXXX)` |

### 3. Apple notarization credentials

Generate an app-specific password at <https://appleid.apple.com> → App-Specific
Passwords → "+". Find your team ID at <https://developer.apple.com/account>
→ Membership.

Upload to GitHub Secrets:

| Secret | Value |
| --- | --- |
| `APPLE_ID` | your Apple Developer ID email |
| `APPLE_TEAM_ID` | 10-char team ID |
| `APPLE_NOTARY_PASSWORD` | the app-specific password from the step above |

### 4. Enable GitHub Pages

Repo Settings → Pages:

- **Source:** Deploy from a branch
- **Branch:** `gh-pages` (the branch will be created on the first tag
  push — configure this *after* the first run, or pre-create it as an
  empty orphan branch with `git checkout --orphan gh-pages && git rm -rf .
  && git commit --allow-empty -m "init gh-pages" && git push origin gh-pages`)
- **Folder:** `/ (root)`

Save. The appcast publishes to `https://<owner>.github.io/rororo-mac/appcast.xml`,
which is the URL Sparkle reads from `SUFeedURL`.

## Cutting a release

```bash
git tag v0.1.0
git push origin v0.1.0
```

Watch GitHub Actions. Then verify:

- The Release page shows the notarized DMG attached.
- `https://626labs.github.io/rororo-mac/appcast.xml` serves the new `<item>`.
- A pre-existing install (`v0.0.x`) prompts for the update on next launch.

## Rolling back a broken release

If a release is broken in the wild, mark it as **pre-release** in the
GitHub Release UI. Sparkle clients on the stable channel skip pre-release
items, so the prompt stops. Then publish a hotfix `v0.x.y+1` to fan out
the fix.

**Don't delete releases** — Sparkle clients may have already cached the
URL, and resurrected URLs causing 404s are a worse failure mode than a
visible "this release is pre-release" flag.

## Local-only notarize

Both scripts work locally if you export the env vars:

```bash
export APPLE_ID="..."
export APPLE_TEAM_ID="..."
export APPLE_NOTARY_PASSWORD="..."
export MACOS_CERTIFICATE_NAME="Developer ID Application: ... (XXXXXXXXXX)"

bash tools/release/notarize.sh
```

The DMG lands at `build/RORORO.dmg`. Useful for a dry-run before tagging,
or for ad-hoc handoff to a tester.

`generate-appcast.sh` additionally needs:

```bash
export SPARKLE_ED_PRIVATE_KEY="$(security find-generic-password -s 'https://sparkle-project.org' -w)"
export GITHUB_REPO="estevanhernandez-stack-ed/rororo-mac"
export GH_TOKEN="$(gh auth token)"

bash tools/release/generate-appcast.sh
# → dist/appcast.xml
```

## Files in this directory

| Path | What it is |
| --- | --- |
| `notarize.sh` | Archive → export → notarize → staple → DMG → staple |
| `exportOptions.plist` | `developer-id` distribution config for `xcodebuild -exportArchive` |
| `generate-appcast.sh` | Pulls `gh release list`, signs DMG hashes, writes `dist/appcast.xml` |
| `README.md` | This file |

The release workflow lives at `.github/workflows/release.yml`. The env
vars these scripts consume are documented in `.env.example` at the repo
root — real values live in GitHub Secrets / 1Password, never in the repo.
