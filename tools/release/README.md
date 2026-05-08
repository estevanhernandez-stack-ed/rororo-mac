# RORORO Mac release tooling

Operational scripts and the GitHub Actions workflow that turn a `v*` git
tag into a notarized DMG attached to a GitHub Release, plus a regenerated
Sparkle appcast published to gh-pages.

## How it works

```
git tag v0.2.5  →  push  →  .github/workflows/release.yml triggers
                                  │
                                  ├─ archive + sign .app (notarize.sh)
                                  ├─ productbuild signed .pkg
                                  ├─ submit .pkg to Apple notary, staple
                                  ├─ attach .pkg to Release page
                                  ├─ regenerate appcast (generate-appcast.sh)
                                  └─ publish dist/ to gh-pages
                                                │
                                                ▼
                       https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml
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
once locally), the helper binaries land in the SPM **artifacts** cache,
not the checkouts cache. The path is:

```
~/Library/Developer/Xcode/DerivedData/RORORO-*/SourcePackages/artifacts/sparkle/Sparkle/bin/
```

(Sparkle 2.9+ moved the modern utilities here; `SourcePackages/checkouts/Sparkle/bin/`
only carries the legacy DSA scripts now.)

Run `generate_keys`:

```bash
"$(find ~/Library/Developer/Xcode/DerivedData/RORORO-* -name generate_keys -type f | head -1)"
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

### 2. Apple Developer ID certificates (two of them)

We ship a signed `.pkg` installer, which needs **two** Developer ID certs:

- **Developer ID Application** — signs the `.app` bundle inside the pkg.
- **Developer ID Installer** — signs the `.pkg` envelope itself. Distinct
  cert. macOS Installer.app and Apple's notary check both.

If you don't have the Installer cert yet, generate it at
<https://developer.apple.com/account/resources/certificates/add> →
"Developer ID Installer" → upload a CSR (Keychain Access → Certificate
Assistant → Request a Certificate from a Certificate Authority…) →
download → double-click to install into Keychain.

Then in Keychain Access, find each cert. Right-click → Export each as
its own `.p12` (set a passphrase — same passphrase for both is fine).
For each:

```bash
base64 -i cert.p12 | pbcopy
```

Upload to GitHub Secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | base64 blob from the **Application** p12 |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` export passphrase (Application) |
| `MACOS_CERTIFICATE_NAME` | cert name, e.g., `Developer ID Application: Estevan Hernandez (XXXXXXXXXX)` |
| `MACOS_INSTALLER_CERTIFICATE` | base64 blob from the **Installer** p12 |
| `MACOS_INSTALLER_CERTIFICATE_PASSWORD` | `.p12` export passphrase (Installer) |
| `MACOS_INSTALLER_CERTIFICATE_NAME` | cert name, e.g., `Developer ID Installer: Estevan Hernandez (XXXXXXXXXX)` |

If the two p12 passphrases match, the workflow's keychain-import step
runs cleanly (it reuses one keychain unlock for both imports).

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

- The Release page shows the notarized PKG attached.
- `https://estevanhernandez-stack-ed.github.io/rororo-mac/appcast.xml` serves the new `<item>`.
- A pre-existing install (`v0.2.x`) prompts for the update on next launch.

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
export MACOS_INSTALLER_CERTIFICATE_NAME="Developer ID Installer: ... (XXXXXXXXXX)"
export TAG_NAME="v0.2.5"
export BUILD_NUMBER="$(git rev-list --count HEAD)"

bash tools/release/notarize.sh
```

The PKG lands at `build/RORORO.pkg`. Useful for a dry-run before tagging,
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
| `notarize.sh` | Archive → sign .app → notarize .app → staple → productbuild .pkg → notarize .pkg → staple |
| `exportOptions.plist` | `developer-id` distribution config for `xcodebuild -exportArchive` |
| `generate-appcast.sh` | Pulls `gh release list`, signs asset hashes (.pkg or legacy .dmg), writes `dist/appcast.xml` |
| `README.md` | This file |

The release workflow lives at `.github/workflows/release.yml`. The env
vars these scripts consume are documented in `.env.example` at the repo
root — real values live in GitHub Secrets / 1Password, never in the repo.
