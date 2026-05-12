# Keychain Probe — Roblox-related items on the dev machine

> Captured 2026-05-12 from `/Users/estevanhernandez/Library/Keychains/login.keychain-db` on the dev machine running RORORO `fix/launcher-cookie-isolation` (post per-instance bundle ID rewrite). Feeds `RoblxKeychainProbeList.items` (App/RORORO/Domain/RoblxKeychainProbeList.swift). Untracked working notes — re-run when adding new accounts / launching RobloxStudio / observing new prompts.

## How to regenerate

```bash
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | \
  awk 'BEGIN{block=""; flag=0} \
       /^keychain:/{if (flag && tolower(block) ~ /roblox/) print "----\n" block; flag=0; block=""} \
       /attributes:/{if (flag && tolower(block) ~ /roblox/) print "----\n" block; flag=1; block=""; next} \
       flag{block=block $0 "\n"} \
       END{if (flag && tolower(block) ~ /roblox/) print "----\n" block}'
```

## Items found

### 1. SharedROBLOSECURITYForStudio (GenericPassword)

- **class:** `kSecClassGenericPassword` (`genp`)
- **service (kSecAttrService):** `https://www.roblox.com/:SharedROBLOSECURITYForStudio`
- **account (kSecAttrAccount):** `https://www.roblox.com/:SharedROBLOSECURITYForStudio`
- **created:** 2026-05-12 21:29:05 UTC (this dev session)
- **value:** opaque blob (not inspected)

Confirmed via `security find-generic-password -a "https://www.roblox.com/:SharedROBLOSECURITYForStudio"` returning the item. `find-internet-password` with the same account returns `errSecItemNotFound`, so it is NOT stored under the InternetPassword class — generic-password only.

This is the item the user observed in the macOS Keychain Access permission prompts that fire on each per-instance Launch As. The original `/Applications/Roblox.app` is presumably the only entity in the ACL.

## Items NOT found (probed for completeness)

- No internet password under service `www.roblox.com` or `roblox.com`.
- No generic password under service `roblox` (substring search by service).
- No `:SharedROBLOSECURITYForPlayer` variant — Roblox Player on macOS apparently does not create one; only the Studio-variant exists. Watch for this if a new prompt surfaces post-RobloxStudio install.

## What to do when new items appear

1. Re-run the probe block above on a machine where the new prompt fired.
2. Append the new item to `RoblxKeychainProbeList.items` with `.genericPassword` or `.internetPassword` kind matching the dump class.
3. Bump `RororoKeychainBootstrap.currentVersion` so existing installations re-run population on next launch (additions are idempotent — see `RororoKeychainItems.add`).
