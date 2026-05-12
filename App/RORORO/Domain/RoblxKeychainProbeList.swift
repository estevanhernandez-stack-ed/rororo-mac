// RoblxKeychainProbeList.swift
// Domain — the items Roblox queries from the macOS Keychain on launch.
// Each entry is pre-populated into RORORO.keychain (with our wildcard
// prefix ACL) at first-run by RororoKeychainBootstrap so re-signed
// per-instance bundles find a match before the search falls through
// to the user's login keychain (where the original Roblox.app's cdhash-
// locked ACL would trigger a password prompt).
//
// Sourced 2026-05-12 from the dev machine's login keychain after a
// per-instance Launch As session — see docs/_keychain-probe-2026-05-12.md
// for the raw dump and re-run instructions. Only one Roblox item exists
// at v0.7.0 ship time. Additional items get appended here as the
// Player / Studio surface area grows.
//
// To extend:
//   1. Re-run the probe block in docs/_keychain-probe-2026-05-12.md.
//   2. Append a new RoroKeychainItem here with the matching class +
//      service / account / etc.
//   3. Bump RororoKeychainBootstrap.currentVersion so existing installs
//      re-run population on next launch. Additions are idempotent
//      (RororoKeychainItems.add checks exists() first).

import Foundation

public enum RoblxKeychainProbeList {

    public static let items: [RoroKeychainItem] = [
        // SharedROBLOSECURITYForStudio — the lone Roblox keychain item
        // observed on the dev machine post per-instance bundle rewrite.
        // GenericPassword class; service and account both set to the
        // full URL form (Roblox's chosen attribute layout).
        RoroKeychainItem(
            kind: .genericPassword,
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            service: "https://www.roblox.com/:SharedROBLOSECURITYForStudio"
        ),
    ]
}
