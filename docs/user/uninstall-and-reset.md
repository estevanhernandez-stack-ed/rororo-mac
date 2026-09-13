# Uninstall, reset, and reinstall RORORO

RORORO leaves more behind than the app icon. This page lists every piece, what it does, and the order to remove things in so a reinstall comes up clean. It also covers the two symptoms that usually send people here.

## Two symptoms this page fixes

**"Another Installer is already running" when launching a second account.**
Roblox shipped an update and `/Applications/Roblox.app` is behind. Each per-account copy RORORO makes is a copy of that stale app, so each one tries to update itself. Roblox's updater only allows one at a time. Fix: quit everything, open Roblox from `/Applications` once, let it update, quit it, then use Launch As again. The next RORORO release checks for this before launching and tells you instead of showing the dialog.

**Play buttons on roblox.com open RORORO instead of Roblox, even after deleting RORORO.**
RORORO registers itself as the handler for `roblox-player://` links while it runs and hands the link back to Roblox on quit. If the handoff didn't happen before you deleted the app, macOS keeps pointing links at RORORO. Fix: reset the handler (step 2 below).

## Full uninstall

Do the steps in this order.

### 1. Quit everything

Quit RORORO from the menu bar tray or with Cmd+Q. Quit every Roblox window. Check Activity Monitor for `RobloxPlayer` and `RobloxPlayerInstaller` and quit those too.

### 2. Hand `roblox-player://` links back to Roblox

Pick one:

- **In the next RORORO release (after 0.7.0):** Settings → Danger zone → **Reset roblox-player link handler**. Then quit RORORO.
- **From Terminal, with RORORO still installed:**

  ```sh
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/RORORO.app
  ```

  This unregisters RORORO from Launch Services. Links fall back to `/Applications/Roblox.app`. If you already moved RORORO to the Trash, run the same command against `~/.Trash/RORORO.app`, then empty the Trash.
- **With Homebrew:** `brew install duti` then `duti -s com.roblox.RobloxPlayer roblox-player`.

Verify: open Terminal and run `open "roblox-player://"`. Roblox should launch, not RORORO.

### 3. Remove the app and its files

```sh
# The app itself
rm -rf /Applications/RORORO.app

# Per-account Roblox copies RORORO made for multi-instance
rm -rf ~/Applications/RORORO

# Saved account profiles (no secrets), favorites, macros, private servers
rm -rf ~/Library/Application\ Support/RORORO

# Preferences: RORORO's own plus one per per-account Roblox copy
rm -f ~/Library/Preferences/com.626labs.rororo-mac.plist
rm -f ~/Library/Preferences/com.626labs.RORORO.instance.*.plist

# Cookie jars and web storage macOS created for the per-account copies
rm -f ~/Library/HTTPStorages/com.626labs.rororo-mac.binarycookies
rm -rf ~/Library/HTTPStorages/com.626labs.rororo-mac
rm -rf ~/Library/HTTPStorages/com.626labs.RORORO.instance.*
rm -rf ~/Library/WebKit/com.626labs.RORORO.instance.*

# Sparkle update cache, if present
rm -rf ~/Library/Caches/com.626labs.rororo-mac
```

### 4. Remove the RORORO keychain

RORORO creates a private keychain so Roblox can launch extra accounts without asking for your macOS password. Delete it with the `security` tool so it also drops out of your keychain search list:

```sh
security delete-keychain ~/Library/Keychains/RORORO.keychain-db
```

Your saved Roblox session cookies live in your **login** keychain as items named `com.626labs.rororo-mac.account-cookie`. Open Keychain Access, search for `rororo`, and delete them.

If you want the Roblox login prompt behaviour fully back to stock, also open Keychain Access, search for `SharedROBLOSECURITYForStudio`, and delete that item. Roblox recreates it on the next login.

### 5. Optional: undo RORORO's Roblox-side writes

Only needed if you used the FFlag editor or the frame-rate cap.

- FFlags: delete `/Applications/Roblox.app/Contents/MacOS/ClientSettings/ClientAppSettings.json`. RORORO normally removes this when the last Roblox window closes.
- Frame-rate cap: open Roblox, Settings, and set the frame-rate cap back to what you want. RORORO wrote it into `~/Library/Roblox/GlobalBasicSettings_13.xml`.

## Reinstall to a working state

1. Do the full uninstall above. Step 2 and step 4 are the ones people skip, and they cause the two symptoms at the top.
2. Open Roblox from `/Applications` on its own once. Let it update if it wants to. Quit it.
3. Install RORORO fresh from the [latest release](https://github.com/estevanhernandez-stack-ed/rororo-mac/releases/latest) or `brew install --cask rororo`.
4. Launch RORORO. The one-time keychain setup sheet appears. Click **Continue**, enter your macOS password in the prompt, and click **Always Allow**. If you click Deny or Not now, every account launch will ask for your password until you redo this.
5. Add your accounts, then Launch As.

## Reset without uninstalling

**Keychain setup went wrong or you deleted the keychain by hand:** quit RORORO, run the `security delete-keychain` command from step 4, and relaunch RORORO. The setup sheet comes back. (The next RORORO release notices the missing keychain on its own.)

**Links open the wrong app:** step 2.

**Second account won't launch:** open Roblox from `/Applications` once so it updates, quit it, try again.

## Still stuck

In RORORO, open **Diagnostics** and click **Save bundle…**. Attach the zip to your email. It contains version numbers, the current link handler, recent RORORO logs, and your account list without any cookies or passwords.
