# Per-Instance Cookie Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Plan version:** v2 (2026-05-11). v1 was authored against a HOME-injection + direct-binary-spawn architecture; a Task 0 PoC discovered that architecture cannot deliver URLs (LaunchServices registration is required for AppleEvent-based URL delivery, and direct binary spawn skips LS). v2 pivots to re-sign + unique bundle ID per instance, validated end-to-end before this rewrite. See "PoC findings" below for the audit trail.

**Goal:** Stop cross-instance cookie / preferences collision so each running Roblox window keeps its own session identity even when sessions refresh.

**Architecture:** Per-instance Roblox bundle copies get a **unique `CFBundleIdentifier`** (`com.626labs.RORORO.instance.<uuid>`) plus an **`LSMultipleInstancesProhibited = false`** override, then are **re-signed** with our Developer ID using a relaxed-library-validation entitlement before `open -n -a` launches them. macOS keys cookies, NSUserDefaults, HTTPStorages, and WebKit storage by `CFBundleIdentifier` — unique IDs → per-instance storage automatically, with zero `$HOME` redirection or binary-spawn surgery. The original `open -n -a` URL delivery path is preserved unchanged because re-signed copies are still LaunchServices-launched and still receive `kAEGetURL` normally.

**Tech Stack:** Swift, Foundation/FileManager (directory + plist ops), `PropertyListSerialization` (Info.plist edit in-process), `/usr/bin/codesign` shelled out (the Apple-supported re-signing entry point), existing `Process` + `/usr/bin/open` invocation pattern.

---

## Problem context

Both per-instance Roblox bundle copies declare the same `CFBundleIdentifier = com.roblox.RobloxPlayer`. macOS keys cookies, NSUserDefaults, HTTPStorages, and WebKit storage by bundle ID — not bundle path — so all running copies share these files:

```
~/Library/HTTPStorages/com.roblox.RobloxPlayer.binarycookies   <- cookie jar
~/Library/HTTPStorages/com.roblox.RobloxPlayer/                <- HTTP cache + transient
~/Library/Preferences/com.roblox.RobloxPlayer.plist            <- NSUserDefaults
~/Library/WebKit/com.roblox.RobloxPlayer/                      <- WebKit storage
~/Library/Caches/com.roblox.RobloxPlayer/                      <- caches (safe to share)
~/Library/Roblox/                                              <- engine assets (safe to share)
```

When account B launches after account A, the engine's cookie write into `com.roblox.RobloxPlayer.binarycookies` clobbers A's. When A's running engine hits a session refresh, it reads the same file and "logs back in" as B. Per-instance bundle paths don't help — `LSMultipleInstancesProhibited=false` lets two processes run, but they share data because they share bundle ID.

The bug has been latent since multi-instance shipped (`e734409`, 2026-05-07). No prior commit ever isolated cookies.

## Approach

Give each per-instance copy a unique `CFBundleIdentifier` so macOS's native per-bundle storage layout delivers the isolation automatically. Modifying the Info.plist invalidates the cdhash, so we re-sign the copy with our Developer ID Application certificate using a relaxed-library-validation entitlement (so the re-signed parent can still load Roblox-team-signed embedded helpers under Hardened Runtime). URL delivery, semaphore-break, and the rest of the existing multi-instance flow are unchanged.

The key insight: we don't need `$HOME` redirection at all. `cfprefsd`-routed NSUserDefaults writes (which ignore `HOME`) and bundle-ID-keyed HTTPStorages writes both end up at per-instance paths automatically once the bundle ID differs.

### Re-sign recipe (validated by PoC 2026-05-11)

```
codesign --force \
  --sign "Developer ID Application: Estevan Hernandez (82BSR56X5J)" \
  --options runtime \
  --entitlements <relax-libval.entitlements> \
  <copy.app>
```

Three things to NOT do (these were the prior re-sign failure modes from commit `95d72fe`):
- **No `--deep`** — re-signs embedded helpers and breaks their original team-signed library validation chain. The outer .app shell is the only thing that needs a new signature.
- **No ad-hoc `-` identity** — strips the team identifier; library validation rejects loading Roblox-team-signed embedded code from a no-team parent.
- **Don't omit the entitlement** — without `com.apple.security.cs.disable-library-validation`, the parent's team (ours) must match every embedded library's team (Roblox's). The entitlement tells the kernel "this parent vouches for any signed library, regardless of team."

The entitlements file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
```

Ships as a bundle resource in RORORO.app (`Contents/Resources/roblox-resign.entitlements`) so the runtime re-sign can reference it without writing a tempfile.

## PoC findings (Task 0 — completed 2026-05-11)

A throwaway PoC at `tools/spawn-poc/` (deleted in Task 5 cleanup) tested three URL-delivery mechanisms under the v1 HOME-injection architecture:

| Mode | Result |
|---|---|
| `argv[1]` | Roblox landed at login — does not read URLs from argv |
| `osascript "tell app … to open location"` | `-609 connectionInvalid` — bundle-ID resolution incompatible with multi-instance (resolves to one of N same-bundle-ID copies, picks wrong one) |
| `aevent` direct AE to pid via `NSAppleEventDescriptor(processIdentifier:)` | `-600 procNotFound` — process exists and renders UI, but isn't a registered AE target because LaunchServices didn't launch it |

Diagnosis: direct binary spawn (`Process` running `Contents/MacOS/RobloxPlayer`) skips LaunchServices registration. Cocoa apps register `kAEGetURL` handlers as part of `NSApplication.run()`, but the registration is mediated by LS — direct-spawned processes are alive and rendering windows but invisible to AE dispatch. Architecture dead-end.

While ruling out v1, the PoC also surfaced two facts worth keeping in the ADR:
1. **HOME-injection isolates filesystem writes but NOT cfprefsd-routed NSUserDefaults.** `cfprefsd` resolves the prefs path from the requesting UID, not from `$HOME`. v1's plan assumed plist isolation would work; it would not have.
2. **Roblox's NSUserDefaults footprint is identity-free** — observed plist content was `WebKitLegacyPluginQuirkForMailSignaturesEnabled`, `NSDisabledCharacterPaletteMenuItem`, `NSWindow Frame Main Window`. Zero account or session state. Even if v1 had failed to isolate preferences (which it would have), the bug we're fixing wouldn't have surfaced through that channel.

Validated v2 architecture under the same PoC harness:
- Copy `/Applications/Roblox.app` → `/tmp/roblox-resign-<uuid>.app`
- `PlistBuddy -c "Set :CFBundleIdentifier com.626labs.RORORO.instance.<uuid>"`
- `codesign --force --sign "Developer ID Application: …" --options runtime --entitlements <relax-libval>` (no `--deep`)
- `open -n -a <copy>` (no URL — landed at Roblox login normally)
- User logged in, joined a game, played ~12 minutes, exited gracefully

Results: zero anti-cheat / integrity / kick hits in Roblox's player log; cookie jar at `~/Library/HTTPStorages/com.626labs.RORORO.instance.<uuid>.binarycookies` grew to 1961 bytes of real session state; preferences plist at `~/Library/Preferences/com.626labs.RORORO.instance.<uuid>.plist` was created cleanly; the original `com.roblox.RobloxPlayer.binarycookies` mtime stayed put while the re-signed copy was running. End-to-end isolation confirmed.

## Out of scope

- The `RunningAccountTracker.backfillFromRunningProcesses()` displayName-collision (`App/RORORO/Domain/RunningAccountTracker.swift:96-123`) — separate plan. Bundle path changes in this plan may incidentally simplify it; capture as `0010-tracker-keyed-by-userid.md` follow-up.
- The cycler / window-layout impact of that collision — same plan as above.
- **End-user distribution.** The PoC validated re-signing with Este's Developer ID cert in keychain. Users running the shipped DMG won't have that cert. See "Open question gating production shipping" below.

## Open question gating production shipping

**Does `--sign -` (ad-hoc) re-sign work on end-user machines?**

The PoC proved the architecture for local dev use (Este on his Mac, signing with his Developer ID cert). End-user machines lack that cert. Two possible end-user signing identities:

- **Ad-hoc (`-`):** historically the failure mode in `95d72fe`, but that failure had `--deep` and no entitlement. Whether the v2 recipe (no `--deep`, with `disable-library-validation` entitlement) survives ad-hoc is **untested**. Apple docs are ambiguous about whether entitlements take effect with ad-hoc signatures.
- **None:** ship pre-signed wrapper bundles with the RORORO DMG. Hard because each bundle needs a unique ID per instance, but you can't know in advance how many instances a user will run.

**Resolution:** Schedule a 30-minute follow-up PoC (Task 4.5 below) that runs the same re-sign recipe with `--sign -` instead of the Developer ID, then verifies Roblox launches and plays normally. Outcome determines whether this fix can ship to users or stays a local-dev-only improvement until we solve distribution.

This plan can be **built and shipped to Este's local builds in full** regardless of that outcome — the helper signature accepts any identity string. Shipping to the public DMG is gated on Task 4.5's result.

## File structure

**Create:**
- `App/RORORO/Domain/BundleIDRewriter.swift` — pure helper: rewrite Info.plist bundle ID + flip LSMultipleInstancesProhibited, then shell out to `codesign` with the relaxed-libval entitlement
- `App/RORORO/Resources/roblox-resign.entitlements` — bundle resource containing the `disable-library-validation` entitlement
- `App/ROROROTests/BundleIDRewriterTests.swift` — unit tests against ad-hoc-signed fixture bundles (real `codesign` invocations; no mocks)
- `docs/decisions/0009-per-instance-cookie-isolation.md` — ADR

**Modify:**
- `App/project.yml` — register the new entitlements file as a bundled resource so the runtime can find it
- `App/RORORO/Domain/RobloxAppCopier.swift` — `copyAppForInstance` calls `BundleIDRewriter.rewrite(at:identity:entitlements:)` after the copy + quarantine strip. The result is a copy with a unique bundle ID, `LSMultipleInstancesProhibited=false` already set, and a valid re-signed cdhash. The previous "modify plist AFTER launch" dance is no longer needed — the re-sign IS the cdhash refresh, so plist edits before launch are safe.
- `App/RORORO/Domain/MultiInstanceCoordinator.swift` — drop the post-launch `setMultipleInstancesProhibitionPostLaunch` call (now handled in copy). Drop the `/tmp/rororo-last-launch-url.txt` debug dump added during the PoC. **Keep** the `NSLog %@` fix from the same debug pass — it's a real bug fix for URL logging.
- `CLAUDE.md` — add the bundle-ID rule to the Hard rules section.

**Delete:**
- `tools/spawn-poc/` — Task 0 artifact, no longer needed.

**Tests use existing target structure.** The test target needs a fixture .app bundle to operate on; build one inline in the test setUp (a minimal Info.plist + a placeholder executable) so tests don't depend on `/Applications/Roblox.app` being present on CI.

---

## Task 1: `BundleIDRewriter` — Info.plist edit + re-sign helper

**Files:**
- Create: `App/RORORO/Domain/BundleIDRewriter.swift`
- Create: `App/RORORO/Resources/roblox-resign.entitlements`
- Create: `App/ROROROTests/BundleIDRewriterTests.swift`
- Modify: `App/project.yml` (add the entitlements as a bundled resource)

**Steps:**

- [ ] **Step 1: Write the entitlements file**

`App/RORORO/Resources/roblox-resign.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
```

- [ ] **Step 2: Update `App/project.yml` to bundle the resource**

Add to the `RORORO` target's `sources` list (or under a `resources` section if XcodeGen requires it):

```yaml
    sources:
      - path: RORORO
        excludes:
          - "Info.plist"
          - "RORORO.entitlements"
      - path: RORORO/Resources/roblox-resign.entitlements
        type: file
        buildPhase: resources
```

(Verify against the project's existing patterns — adjust if a different resources idiom is already in use.)

- [ ] **Step 3: Write the failing test**

`App/ROROROTests/BundleIDRewriterTests.swift`:

```swift
import XCTest
@testable import RORORO

final class BundleIDRewriterTests: XCTestCase {

    private var tempRoot: URL!
    private var entitlementsURL: URL!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-rewriter-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        // Write a real entitlements file for the re-sign call to reference.
        entitlementsURL = tempRoot.appendingPathComponent("test.entitlements")
        try? """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>com.apple.security.cs.disable-library-validation</key><true/>
        </dict></plist>
        """.write(to: entitlementsURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testRewritesBundleIDAndFlipsMultiInstanceFlag() throws {
        let fixtureApp = try makeFixtureApp(
            bundleID: "com.example.original",
            multipleInstancesProhibited: true
        )

        let newID = "com.626labs.RORORO.instance.test-\(UUID().uuidString.lowercased())"
        try BundleIDRewriter.rewrite(
            at: fixtureApp,
            newBundleID: newID,
            signingIdentity: "-",                      // ad-hoc OK for tests
            entitlementsPath: entitlementsURL.path
        )

        let plistURL = fixtureApp.appendingPathComponent("Contents/Info.plist")
        let plist = try plistDict(at: plistURL)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, newID)
        XCTAssertEqual(plist["LSMultipleInstancesProhibited"] as? Bool, false)
    }

    func testReSignedBundleReportsNewIdentifierToCodesign() throws {
        let fixtureApp = try makeFixtureApp(
            bundleID: "com.example.fixture",
            multipleInstancesProhibited: true
        )

        let newID = "com.626labs.RORORO.instance.test-\(UUID().uuidString.lowercased())"
        try BundleIDRewriter.rewrite(
            at: fixtureApp,
            newBundleID: newID,
            signingIdentity: "-",
            entitlementsPath: entitlementsURL.path
        )

        // codesign -dvv should now report the new identifier on the .app shell.
        let output = try runCodesign(["-dvv", fixtureApp.path])
        XCTAssertTrue(output.contains("Identifier=\(newID)"),
                      "codesign -dvv output should include new identifier, got:\n\(output)")
    }

    // MARK: helpers

    private func makeFixtureApp(bundleID: String, multipleInstancesProhibited: Bool) throws -> URL {
        let appURL = tempRoot.appendingPathComponent("Fixture-\(UUID().uuidString).app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        // Minimal executable — a placeholder shell-script masquerading.
        let exec = appURL.appendingPathComponent("Contents/MacOS/Fixture")
        try "#!/bin/sh\nexit 0\n".write(to: exec, atomically: true, encoding: .utf8)
        var attrs = try FileManager.default.attributesOfItem(atPath: exec.path)
        attrs[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attrs, ofItemAtPath: exec.path)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleExecutable": "Fixture",
            "CFBundleName": "Fixture",
            "LSMultipleInstancesProhibited": multipleInstancesProhibited
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: appURL.appendingPathComponent("Contents/Info.plist"))

        // Ad-hoc sign so we have a starting signature to replace.
        _ = try runCodesign(["--force", "--sign", "-", appURL.path])
        return appURL
    }

    private func plistDict(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var fmt: PropertyListSerialization.PropertyListFormat = .xml
        let obj = try PropertyListSerialization.propertyList(from: data, format: &fmt)
        return (obj as? [String: Any]) ?? [:]
    }

    private func runCodesign(_ args: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out + err  // codesign writes its descriptive output to stderr
    }
}
```

- [ ] **Step 4: Run test, verify it fails (no `BundleIDRewriter` type yet)**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/BundleIDRewriterTests 2>&1 | tail -20
```

Expected: build fails with "use of unresolved identifier 'BundleIDRewriter'".

- [ ] **Step 5: Implement `BundleIDRewriter`**

```swift
// BundleIDRewriter.swift
// Domain — rewrites a per-instance Roblox bundle copy with a unique
// CFBundleIdentifier, flips LSMultipleInstancesProhibited to false in
// the same Info.plist edit pass, then re-signs the outer .app shell
// with the supplied identity using a relaxed-library-validation
// entitlement.
//
// Why this exists: macOS keys cookies, NSUserDefaults, HTTPStorages,
// and WebKit storage by CFBundleIdentifier, not bundle path. Multi-
// instance per-account isolation requires per-instance bundle IDs.
// Editing Info.plist invalidates the bundle's cdhash; the re-sign
// recomputes it so amfid accepts the launch under Hardened Runtime.
//
// Re-sign recipe (validated by PoC 2026-05-11, see plan v2):
//   codesign --force \
//     --sign <identity> \
//     --options runtime \
//     --entitlements <relax-libval.entitlements> \
//     <copy.app>
//
// Three things we deliberately DON'T do:
//   - --deep: would re-sign embedded helpers and break their Roblox-
//     team-signed library validation chain.
//   - Ad-hoc identity by default: prior failure mode (commit 95d72fe).
//     The caller passes the identity string; for shipped RORORO that's
//     a Developer ID; tests use "-" because Hardened Runtime + library
//     validation aren't enforced for ad-hoc-signed test fixtures.
//   - Omit the entitlement: without disable-library-validation, the
//     re-signed parent (our team) can't load Roblox-team-signed
//     embedded code under Hardened Runtime.

import Foundation

public enum BundleIDRewriter {

    public enum RewriteError: Error, Equatable {
        case infoPlistReadFailed(underlying: String)
        case infoPlistWriteFailed(underlying: String)
        case codesignFailed(status: Int32, stderr: String)
        case entitlementsMissing(path: String)
    }

    /// Mutate the bundle at `appURL` so it has a unique bundle ID,
    /// `LSMultipleInstancesProhibited=false`, and a fresh signature
    /// matching the new cdhash. Idempotent — calling twice with the
    /// same `newBundleID` results in two valid re-signs of the same
    /// modified plist.
    public static func rewrite(
        at appURL: URL,
        newBundleID: String,
        signingIdentity: String,
        entitlementsPath: String
    ) throws {
        // Pre-flight: entitlements file must exist; codesign fails
        // cryptically if the path is wrong.
        guard FileManager.default.fileExists(atPath: entitlementsPath) else {
            throw RewriteError.entitlementsMissing(path: entitlementsPath)
        }

        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        try editInfoPlist(at: plistURL, newBundleID: newBundleID)
        try resign(appURL: appURL, identity: signingIdentity, entitlementsPath: entitlementsPath)
    }

    private static func editInfoPlist(at plistURL: URL, newBundleID: String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: plistURL)
        } catch {
            throw RewriteError.infoPlistReadFailed(underlying: error.localizedDescription)
        }

        var format: PropertyListSerialization.PropertyListFormat = .xml
        let obj: Any
        do {
            obj = try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format
            )
        } catch {
            throw RewriteError.infoPlistReadFailed(underlying: error.localizedDescription)
        }
        guard var plist = obj as? [String: Any] else {
            throw RewriteError.infoPlistReadFailed(underlying: "Info.plist root is not a dictionary")
        }

        plist["CFBundleIdentifier"] = newBundleID
        plist["LSMultipleInstancesProhibited"] = false

        let outData: Data
        do {
            outData = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: format,
                options: 0
            )
        } catch {
            throw RewriteError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
        do {
            try outData.write(to: plistURL, options: .atomic)
        } catch {
            throw RewriteError.infoPlistWriteFailed(underlying: error.localizedDescription)
        }
    }

    private static func resign(appURL: URL, identity: String, entitlementsPath: String) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = [
            "--force",
            "--sign", identity,
            "--options", "runtime",
            "--entitlements", entitlementsPath,
            appURL.path
        ]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            throw RewriteError.codesignFailed(
                status: task.terminationStatus,
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
```

- [ ] **Step 6: Run tests, verify pass**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' \
  -only-testing:ROROROTests/BundleIDRewriterTests 2>&1 | tail -20
```

Expected: both tests PASS.

- [ ] **Step 7: Commit**

```bash
git add App/RORORO/Domain/BundleIDRewriter.swift \
        App/RORORO/Resources/roblox-resign.entitlements \
        App/ROROROTests/BundleIDRewriterTests.swift \
        App/project.yml
git commit -m "$(cat <<'EOF'
feat(launcher): BundleIDRewriter — per-instance bundle ID + re-sign

Foundation for cookie-jar isolation across multi-instance Roblox.
Rewrites a copied .app's Info.plist with a unique CFBundleIdentifier
and LSMultipleInstancesProhibited=false, then re-signs the outer
shell with the supplied identity + disable-library-validation
entitlement. Embedded helpers' Roblox-team signatures stay intact
(no --deep).

Idempotent. No callers yet — wired through RobloxAppCopier in the
follow-up commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Wire `BundleIDRewriter` into `RobloxAppCopier.copyAppForInstance`

**Files:**
- Modify: `App/RORORO/Domain/RobloxAppCopier.swift`

**Steps:**

- [ ] **Step 1: Add a per-instance bundle-ID builder helper**

In `RobloxAppCopier`, add:

```swift
/// Build a unique bundle ID for one per-instance copy. The UUID lower-
/// cased matches macOS's canonical-id normalization (LaunchServices
/// stores `com.foo.UUID` and `com.foo.uuid` as the same ID; we use
/// lowercase to keep the runtime ID and the on-disk paths consistent).
public static func makePerInstanceBundleID() -> String {
    let suffix = UUID().uuidString.lowercased()
    return "com.626labs.RORORO.instance.\(suffix)"
}

/// Path to the bundled re-sign entitlements file. `Bundle.main` resolves
/// to RORORO.app at runtime; tests inject an override path.
public static func defaultEntitlementsPath() -> String? {
    return Bundle.main.path(forResource: "roblox-resign", ofType: "entitlements")
}

/// Signing identity for runtime re-sign. Returns the project's
/// Developer ID Application identity for shipped builds; tests inject
/// `-` (ad-hoc).
public static func defaultSigningIdentity() -> String {
    return "Developer ID Application: Estevan Hernandez (82BSR56X5J)"
}
```

- [ ] **Step 2: Call `BundleIDRewriter.rewrite` at the end of `copyAppForInstance`**

Replace the final lines of `copyAppForInstance` (currently `try removeQuarantine(at: destURL); return destURL`) with:

```swift
// Strip any inherited quarantine xattr.
try removeQuarantine(at: destURL)

// Rewrite bundle ID + flip LSMultipleInstancesProhibited + re-sign.
// macOS keys bundle storage (cookies, NSUserDefaults, HTTPStorages,
// WebKit) by CFBundleIdentifier; unique IDs deliver per-instance
// isolation natively without HOME redirection or binary spawn.
guard let entitlementsPath = Self.defaultEntitlementsPath() else {
    throw CopyError.copyFailed(
        underlying: "roblox-resign.entitlements missing from RORORO.app bundle"
    )
}
do {
    try BundleIDRewriter.rewrite(
        at: destURL,
        newBundleID: Self.makePerInstanceBundleID(),
        signingIdentity: Self.defaultSigningIdentity(),
        entitlementsPath: entitlementsPath
    )
} catch {
    throw CopyError.copyFailed(
        underlying: "bundle ID rewrite / re-sign failed: \(error.localizedDescription)"
    )
}

return destURL
```

- [ ] **Step 3: Build + run all existing tests**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -30
```

Expected: build succeeds, all existing tests pass. The new BundleIDRewriter tests from Task 1 still pass.

- [ ] **Step 4: Commit**

```bash
git add App/RORORO/Domain/RobloxAppCopier.swift
git commit -m "$(cat <<'EOF'
feat(launcher): rewrite + re-sign per-instance copies with unique bundle IDs

copyAppForInstance now finishes by handing the copy to
BundleIDRewriter — each per-instance Roblox bundle gets a unique
CFBundleIdentifier (com.626labs.RORORO.instance.<uuid>), has its
LSMultipleInstancesProhibited flag flipped off in the same pass, and
is re-signed with our Developer ID + disable-library-validation
entitlement. macOS keys cookies, NSUserDefaults, HTTPStorages, and
WebKit storage by bundle ID — per-instance IDs deliver per-instance
storage natively. No HOME injection, no binary spawn.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Simplify `MultiInstanceCoordinator.performLaunch` + retire PoC debug

**Files:**
- Modify: `App/RORORO/Domain/MultiInstanceCoordinator.swift`

**Steps:**

- [ ] **Step 1: Remove the post-launch `setMultipleInstancesProhibitionPostLaunch` call**

The whole "modify plist AFTER launch to dodge the cdhash invalidation" dance is obsolete now — `BundleIDRewriter` does the plist edit AND the re-sign in `copyAppForInstance` before the `open -n -a` runs. The Info.plist is already correctly configured by the time we reach the spawn.

In `performLaunch`'s success branch (around `App/RORORO/Domain/MultiInstanceCoordinator.swift:377-381`):

```swift
// BEFORE:
let copy = try RobloxAppCopier.copyAppForInstance(bundleLabel: displayLabel)
_ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)
try await openRoblox(at: copy, with: url)
try? RobloxAppCopier.setMultipleInstancesProhibitionPostLaunch(at: copy)
_ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)

// AFTER:
let copy = try RobloxAppCopier.copyAppForInstance(bundleLabel: displayLabel)
_ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)
try await openRoblox(at: copy, with: url)
_ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)
```

Update the explanatory comment block at the top of the `do` block — the v1 ordering rationale ("modify plist BEFORE the open call invalidates the bundle's cdhash") no longer applies; the new rationale is "rewriter recomputed the cdhash already, plist edits are pre-launch and safe."

- [ ] **Step 2: Remove the PoC debug URL dump**

In `openRoblox` (around the NSLog call):

```swift
// REMOVE this block (PoC debug, added 2026-05-11):
try? url.absoluteString.write(
    to: URL(fileURLWithPath: "/tmp/rororo-last-launch-url.txt"),
    atomically: true,
    encoding: .utf8
)
```

**KEEP** the `NSLog %@` placeholder fix from the same PoC — it's a real bug fix for printf-formatter-eating-URL-bytes. The comment should stay explaining why we use `%@` instead of Swift interpolation.

- [ ] **Step 3: (Optional) Remove `setMultipleInstancesProhibitionPostLaunch` from `RobloxAppCopier`**

The method is no longer called. Two options:
- **Delete it.** Cleaner, no dead code.
- **Keep it.** Future emergency rollback could need a "set this flag without a full re-sign" path.

Recommendation: delete. The plan rollback (see below) is a `git revert`, not a code-level fallback path.

- [ ] **Step 4: Build + run all tests**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=x86_64' 2>&1 | tail -30
```

Expected: build succeeds, all existing tests pass. New BundleIDRewriter tests still pass.

- [ ] **Step 5: Commit**

```bash
git add App/RORORO/Domain/MultiInstanceCoordinator.swift \
        App/RORORO/Domain/RobloxAppCopier.swift
git commit -m "$(cat <<'EOF'
refactor(launcher): retire post-launch plist edit + PoC debug dump

BundleIDRewriter rewrites the plist + re-signs the copy before
open -n -a runs, so the post-launch setMultipleInstancesProhibition-
PostLaunch dance is no longer needed. Drop the call site, drop the
helper (no callers), update the rationale comment in performLaunch.

Also drops the /tmp/rororo-last-launch-url.txt PoC instrumentation
(temporary aid for the 2026-05-11 spawn-poc round, now obsolete).
Keeps the NSLog %@ format-string fix — that's a real bug fix worth
preserving.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Verify cleanup-on-boot covers per-instance bundles

**Files:**
- Modify (verify only): `App/RORORO/Domain/RobloxAppCopier.swift`

**Steps:**

- [ ] **Step 1: Read existing cleanup walker**

`cleanupStaleInstances` at `RobloxAppCopier.swift:172-190` walks `instancesRoot()` and removes top-level entries older than 24h. Each per-instance copy lives at `instances/<uuid>/<label>.app/` — the UUID parent dir is what the walker sees. **Verify the walker deletes the UUID parent dir wholesale.**

- [ ] **Step 2: No code change expected**

The walker already operates on the right granularity. No code change needed. If reading reveals a bundle-specific filter that would miss the new layout, file a follow-up.

- [ ] **Step 3: No commit unless code changed.**

---

## Task 4.5: PoC — does `--sign -` (ad-hoc) re-sign work for end-user distribution?

**This task is the open question gating production shipping** (see "Open question gating production shipping" above). Must be answered before the fix ships to users via DMG.

**Procedure:**

- [ ] **Step 1: Re-run the Task 0 validated recipe, but with `-` instead of Developer ID**

```bash
COPY="/tmp/roblox-adhoc-$(uuidgen).app"
cp -R /Applications/Roblox.app "$COPY"
xattr -dr com.apple.quarantine "$COPY" 2>/dev/null || true

NEW_ID="com.626labs.RORORO.instance.adhoc-$(uuidgen | tr A-Z a-z)"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_ID" "$COPY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMultipleInstancesProhibited false" "$COPY/Contents/Info.plist"

cat > /tmp/relax-libval.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
EOF
codesign --force --sign - --options runtime \
  --entitlements /tmp/relax-libval.entitlements "$COPY"

codesign -dvv "$COPY"
open -n -a "$COPY"
```

- [ ] **Step 2: Observe**

- Does Roblox launch (no Gatekeeper popup, no "can't be opened")?
- Can you log in and join a game?
- Does the new bundle ID get its own `~/Library/HTTPStorages/$NEW_ID.binarycookies`?
- Any anti-cheat issues over a ~10 minute session?

- [ ] **Step 3: Decide**

- **All green:** ship as-is to public DMG with ad-hoc as the runtime identity. Update `RobloxAppCopier.defaultSigningIdentity()` to detect "shipped vs. dev" and pick `-` for the former, Developer ID for the latter (or just `-` always — works in both contexts).
- **Launches but kicked at join:** anti-cheat takes the bait. Investigate Hyperion fingerprinting; consider not shipping cookie isolation to public until we solve.
- **Doesn't launch:** ad-hoc + entitlement isn't enough. Update the plan to "local dev only" and surface the limitation in CLAUDE.md until distribution is solved.

---

## Task 5: Smoke matrix — verify the fix on actual hardware

**This task is human-attended.** No automation; the bug only manifests against the real Roblox engine over a real session.

**Steps:**

- [ ] **Step 1: Build a signed dev build**

```bash
cd App && xcodegen generate
xcodebuild -project RORORO.xcodeproj -scheme RORORO build 2>&1 | tail -10
```

- [ ] **Step 2: Launch RORORO**

```bash
open ~/Library/Developer/Xcode/DerivedData/RORORO-*/Build/Products/Debug/RORORO.app
```

- [ ] **Step 3: Reproduce the original collision scenario**

- Two accounts saved (e.g., @estehernandez and @celcpapa).
- Click Launch As on the first account. Wait until Roblox window appears + you're in a world.
- Click Launch As on the second account. Wait until second Roblox window appears.
- Note both windows in the Dock; confirm both show their owning account in-game.
- Leave both windows running idle for 5–10 min. (The cookie-refresh / session-check tick is what triggered the original collision.)

- [ ] **Step 4: Verify no identity swap**

Both windows should still show their original account. No re-login prompts. No "Loading…" spinners that resolve to the wrong avatar.

- [ ] **Step 5: Verify on-disk isolation**

```bash
# List per-instance bundle IDs that wrote cookies during the session.
ls ~/Library/HTTPStorages/com.626labs.RORORO.instance.*.binarycookies 2>/dev/null

# Both should be present, each ~1-2KB. Confirm the real Roblox cookie
# jar's mtime DID NOT advance during the test:
stat -f '%Sm  %z bytes  %N' ~/Library/HTTPStorages/com.roblox.RobloxPlayer.binarycookies
```

- [ ] **Step 6: Verify Dock + foreground UX hasn't degraded**

- Both Roblox windows have Dock entries with the expected per-account labels.
- Cmd-Tab finds both.
- Clicking either Dock entry brings the right window forward.
- No "no signature" / "from unidentified developer" Gatekeeper warnings.

- [ ] **Step 7: Capture findings**

If anything failed, stop and reassess. The PoC and Task 4.5 should have caught most issues, but live multi-instance sometimes does things single-instance smoke missed.

---

## Task 6: ADR + decision log + cleanup

**Files:**
- Create: `docs/decisions/0009-per-instance-cookie-isolation.md`
- Modify: `CLAUDE.md` (add Hard rule about bundle-ID-shared storage + the re-sign architecture)
- Delete: `tools/spawn-poc/`

**Steps:**

- [ ] **Step 1: Write ADR 0009**

Use the format from `docs/decisions/0008-macro-library-refactor.md`. Cover:
- **Context:** bundle-ID-keyed storage collision, latent since multi-instance shipped. v1 plan attempted HOME injection; Task 0 PoC found it cannot deliver URLs because direct binary spawn skips LaunchServices registration.
- **Decision 1:** per-instance unique bundle ID + re-sign with Developer ID + disable-library-validation entitlement, leveraging macOS's native per-bundle storage isolation. Existing `open -n -a` URL delivery path unchanged.
- **Decision 2:** distribution shipping gated on Task 4.5 (ad-hoc re-sign viability for end-user machines).
- **Consequences:** copyAppForInstance gains a re-sign step (adds ~1-2s per launch). Future Roblox versions that change embedded helper signing requirements may need entitlement updates. Engine binary upgrades land via Roblox's auto-updater into `/Applications/Roblox.app` and are picked up by the next launch's `cp -R`.
- **Alternatives considered:**
  - HOME injection + direct binary spawn (v1) — rejected after PoC; URL delivery impossible.
  - App Sandbox containers — rejected; requires entitlements + re-sign + sandbox profile changes that affect entitled APIs.
  - `LSEnvironment` in Info.plist without ID rewrite — feasible but addresses only cookies, not preferences; doesn't solve the cfprefsd-bypass quirk.
  - Bundle-ID rewrite WITHOUT re-sign — explicitly tested (v1 rejection rationale), invalidates cdhash, amfid refuses spawn.
- Reference PoC findings (this plan, "PoC findings" section) as evidence.

- [ ] **Step 2: Add the Hard rule to `CLAUDE.md`**

Insert under `## Hard rules` in the project `CLAUDE.md`:

```markdown
- **Bundle-ID-keyed storage is shared across all running per-instance copies unless bundle IDs differ.** macOS keys cookies (`~/Library/HTTPStorages/<bundle>.binarycookies`), NSUserDefaults (`~/Library/Preferences/<bundle>.plist`), HTTPStorages, and WebKit storage by `CFBundleIdentifier`, not by bundle path. Multi-instance isolation requires each per-instance copy to have a unique bundle ID — `BundleIDRewriter` handles this at copy time + re-signs with our Developer ID + disable-library-validation entitlement so Roblox's Roblox-team-signed embedded helpers still load under Hardened Runtime. Don't add a launch path that bypasses `BundleIDRewriter`; don't reuse a bundle ID across instances.
```

- [ ] **Step 3: Delete the PoC**

```bash
rm -rf tools/spawn-poc
```

- [ ] **Step 4: Log the decision via 626Labs Dashboard MCP**

This is an architectural choice + an "overcame a momentous hurdle" event (per `~/.claude/CLAUDE.md`'s decision-log bar). Log via `mcp__626Labs__manage_decisions` with action `log`, scope `architectural`, tag with the bound project ID.

If the MCP isn't online yet, the decision content is drafted at `docs/decisions/_pending-dashboard-log.md` (see Phase 2 of this plan's roll-up commit). Paste from there once the MCP is wired up.

- [ ] **Step 5: Final commit**

```bash
git add docs/decisions/0009-per-instance-cookie-isolation.md CLAUDE.md
git rm -r tools/spawn-poc
git rm -f docs/decisions/_pending-dashboard-log.md  # only if it was already pasted
git commit -m "$(cat <<'EOF'
docs(adr): 0009 per-instance cookie isolation + CLAUDE.md hard rule

Captures the architectural decision for the multi-instance cookie-jar
isolation fix: per-instance unique bundle ID + Developer ID re-sign +
disable-library-validation entitlement; macOS's native per-bundle
storage layout delivers isolation. Removes the spawn-PoC scaffold
(Task 0 artifact, v1 architecture).

Adds a Hard rule in CLAUDE.md so future contributors don't bypass
BundleIDRewriter or reuse a bundle ID across instances.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Smoke-failure rollback

If Task 5 reveals a regression that can't be fixed inside Task 5 itself (e.g., anti-cheat begins kicking re-signed copies after a Roblox engine update), the rollback path is:

```bash
git revert <Task-2-commit> <Task-3-commit>  # restores the v1 multi-instance path with post-launch plist flip
```

`BundleIDRewriter` and the entitlements resource stay in the tree (unused) for a follow-up attempt. The cookie collision bug returns; mitigation: surface a warning in RORORO's UI ("multi-instance with multiple accounts may collide — re-launch if you see a session swap") until the next attempt lands.

---

## Self-review checklist (completed inline at write time)

- [x] Spec coverage: each section of the problem context maps to a task — Task 1 builds the rewriter, Task 2 wires it through copyAppForInstance, Task 3 simplifies the launch path, Task 4 verifies cleanup, Task 4.5 gates shipping, Task 5 verifies the live fix, Task 6 documents.
- [x] No "TBD", "TODO", "implement later" — verified by file scan before save.
- [x] Type consistency: `BundleIDRewriter.rewrite(at:newBundleID:signingIdentity:entitlementsPath:)`, `RobloxAppCopier.makePerInstanceBundleID()`, `RobloxAppCopier.defaultEntitlementsPath()`, `RobloxAppCopier.defaultSigningIdentity()` are consistent across all task references.
- [x] Out-of-scope items called out at top (`RunningAccountTracker` displayName collision → separate plan; end-user distribution → Task 4.5 gate).
- [x] PoC findings recorded inline so the next person sees the evidence trail, not just the conclusion.
- [x] Rollback path described (git revert specific commits; UI mitigation for the interim).
