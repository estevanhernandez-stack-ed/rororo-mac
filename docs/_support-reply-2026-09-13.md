# Support reply draft — 2026-09-13

> Reply to the "Another installer is already running" / "opens RORORO instead of Roblox" email. Name left off on purpose; add it before sending. Written for a non-technical Mac user.

---

Hi,

Thanks for the detailed write-up, and sorry for the slow reply. I was able to reproduce both problems, and they have the same root: some of RORORO's state lives outside the app icon, so dragging it to the Trash doesn't reset it. Here's what happened and how to get back to a clean install.

**"Another Installer is already running."** Roblox pushed an update, and the copy of Roblox in your Applications folder fell behind. RORORO runs each account from a copy of that app, so every account you launched tried to update itself at the same time, and Roblox's updater only allows one. The fix today is to open Roblox on its own from Applications, let it update, quit it, then use Launch As. RORORO 0.8.0 catches this before launching and offers an "Update Roblox" button that does it for you. Get 0.8.0 either way:

- Installer: https://github.com/estevanhernandez-stack-ed/rororo-mac/releases/download/v0.8.0/RORORO.pkg
- Release page: https://github.com/estevanhernandez-stack-ed/rororo-mac/releases/tag/v0.8.0
- Or, in an existing install, RORORO → Check for Updates… (Homebrew users: `brew upgrade --cask rororo`)

**Play buttons open RORORO instead of Roblox.** While RORORO runs, it takes over "roblox-player://" links so it can pick which account to launch, and it hands them back to Roblox when you quit. That handoff didn't complete before you deleted the app, so macOS kept pointing links at RORORO. Reinstalling RORORO put a new copy in the same spot, so links kept going there. 0.8.0 hands links back reliably on quit and adds a "Reset roblox-player link handler" button under Settings → Danger zone.

**The keychain prompt.** RORORO creates a small private keychain so Roblox can launch extra accounts without asking for your Mac password each time. The one-time setup needs you to enter your password and click "Always Allow." If that got denied or skipped, every launch asks for the password instead.

To get to a clean reinstall, follow this page in order. Steps 2 and 4 are the ones that matter for your two symptoms:

https://github.com/estevanhernandez-stack-ed/rororo-mac/blob/main/docs/user/uninstall-and-reset.md

Short version:

1. Quit RORORO and every Roblox window.
2. In Terminal, run:
   `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/RORORO.app`
   (that hands links back to Roblox)
3. Delete RORORO.app, then delete `~/Library/Application Support/RORORO`, `~/Applications/RORORO`, and `~/Library/Preferences/com.626labs.rororo-mac.plist`.
4. In Terminal, run `security delete-keychain ~/Library/Keychains/RORORO.keychain-db`.
5. Open Roblox from Applications once, let it update, quit it.
6. Install RORORO fresh, click Continue on the keychain setup sheet, enter your password, click Always Allow.
7. Add accounts and Launch As.

If anything still misbehaves after that, open Diagnostics in RORORO, click "Save bundle…", and send me the zip. It has version numbers and logs but no cookies or passwords.

Thanks for sticking with it.

Estevan
