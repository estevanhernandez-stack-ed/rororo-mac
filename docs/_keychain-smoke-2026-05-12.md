# Keychain prompt elimination — manual smoke 2026-05-12

> Captured during the autonomous build of the v0.7.0 keychain-prompt-elimination plan. Tasks 1-6 + 8-9 landed via /vibe-cartographer:build; this file holds the end-to-end Launch-As smoke that requires user interaction (Task 7 of the plan).

## Pre-smoke state (already done by build)

- Branch: `fix/launcher-cookie-isolation`
- 13 keychain tests green: probe pin (2) + primitives (4) + items (3) + bootstrap (4)
- `xcodebuild build` succeeds against the wired app
- Code path: `App.swift .sheet → KeychainBootstrapPromptSheet.run → RororoKeychainBootstrap.ensureIfNeeded → RororoKeychain.{create,unlock,prependToSearchList} + RororoKeychainItems.add`
- One macOS password prompt at first run (search-list modification, unavoidable)

## To reset to "clean-machine" state

```bash
defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion 2>/dev/null
security delete-keychain ~/Library/Keychains/RORORO.keychain 2>/dev/null
defaults read com.626labs.rororo-mac RororoKeychainBootstrapVersion 2>&1 | head -1
# Expected: "does not exist"
```

## Smoke steps

### 1. Launch RORORO from Xcode and complete onboarding

- Open `App/RORORO.xcodeproj` in Xcode, cmd+R.
- **Expected:** Onboarding sheet appears explaining the one-time setup.
- Click **Continue**.
- **Expected:** macOS prompts for the login keychain password ("'security' wants to use your confidential information stored in 'login' in your keychain" or similar).
- Enter password, click **Always Allow**.
- **Expected:** Sheet dismisses.
- Verify in terminal:
  ```bash
  defaults read com.626labs.rororo-mac RororoKeychainBootstrapVersion
  # Expected: 1
  security list-keychains -d user | head -1
  # Expected: contains RORORO.keychain
  ```

### 2. Launch first Roblox account

- Pick an account in RORORO, click **Launch As**.
- **Expected:** Roblox spawns and reaches the game.
- **Watch for keychain prompts.** Document: yes / no.

### 3. Launch second account (one that previously triggered prompts)

- Pick a different account. Click **Launch As**.
- **Expected:** no keychain password prompt.
- **Document:** yes / no prompt.

### 4. Launch third account (fresh, not previously used)

- Pick a third account. Click **Launch As**.
- **Expected:** no keychain password prompt.
- **Document:** yes / no prompt.

### 5. 10-minute play smoke (also covers ADR 0009 Hyperion open item)

- Stay in one of the launched accounts ≥10 minutes.
- **Watch for Hyperion / anti-cheat kicks.** Document: yes / no kick.

### 6. Verify storage routing

```bash
security find-generic-password \
  -a "https://www.roblox.com/:SharedROBLOSECURITYForStudio" \
  ~/Library/Keychains/RORORO.keychain | head -5
# Expected: returns the item (proves it's in RORORO.keychain)

security find-generic-password \
  -a "https://www.roblox.com/:SharedROBLOSECURITYForStudio" \
  ~/Library/Keychains/login.keychain-db | head -5
# Expected: returns the existing item unchanged (we didn't touch login.keychain)
```

## After smoke

Append results to this file, then:

- If all clean (zero prompts on accounts 2+3, no Hyperion kick): mark Task 4.5 + the keychain-prompt-elimination as confirmed in `docs/_followups-cookie-isolation.md`. Update ADR 0010's Verification section with the captured results. v0.7.0 is ready to tag.
- If prompts still fire on account 2/3: re-run the probe block at the top of `docs/_keychain-probe-2026-05-12.md` to see if there are additional Roblox keychain items we missed. Append to `RoblxKeychainProbeList.items`, bump `RororoKeychainBootstrap.currentVersion`, re-run smoke.
- If Hyperion kicks: separate open item; not blocked by this change. Roll back if reproducible.
