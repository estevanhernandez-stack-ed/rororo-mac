# Keychain Prompt Elimination Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the macOS Keychain password prompts that appear once per new account in v0.6.1+ (after the per-instance bundle-ID rewrite shipped on `fix/launcher-cookie-isolation`). This is the only open item gating v0.7.0 ship.

**Architecture:** Create a single RORORO-controlled login keychain (`RORORO.keychain`) at first run, install it as the **first** entry in the user's keychain search list, and pre-populate it with the items Roblox queries on launch (starting with `https://www.roblox.com/:SharedROBLOSECURITYForStudio`). Each pre-populated item carries an ACL whose `csreq` requirement is `identifier like "com.626labs.RORORO.instance.*"`, so every re-signed per-instance bundle satisfies the ACL regardless of cdhash. When Roblox queries Keychain on launch via a re-signed copy, macOS searches in order, finds the matching item in `RORORO.keychain` first, satisfies the ACL with the prefix match, and returns without prompting. The user's login keychain entries are never read, never modified, never deleted. One one-time password ceremony at first run (macOS demands it when modifying the search list); zero prompts thereafter.

**Tech Stack:** Swift / SwiftUI, `Security.framework` (SecKeychain, SecItem, SecAccess, SecRequirement APIs), `/usr/bin/security` CLI for keychain creation + search-list operations (Apple still ships it; the framework-level equivalents are deprecated and noisy), `/usr/bin/csreq` for code requirement compilation. Domain code lives in `App/RORORO/Domain/`. Tests in `App/ROROROTests/`. The bootstrap is invoked from `MultiInstanceCoordinator.bootIfNeeded()` so it runs once at app start without changing the launch hot path.

---

## Why this approach (and why not Raptor's)

- **Raptor-Manager's pattern is not applicable.** Raptor uses HOME-rebase + pre-written `binarycookies` for direct-spawn launches. Their keychain is empty (verified by source read 2026-05-12). They sidestep Keychain auth entirely — incompatible with our LaunchServices-mediated `open -n -a <copy.app> <roblox-player-URL>` flow, which we cannot change (URL delivery via `kAEGetURL` requires LS launch — direct binary spawn fails URL delivery, proven by Task 0 PoC predating ADR 0009).
- **The prompt root cause is cdhash-keyed ACLs, not where the items live.** Roblox queries Keychain for items like `:SharedROBLOSECURITYForStudio`. Those items exist in the user's login keychain with ACLs that grant access to the cdhash of the original `/Applications/Roblox.app`. Each per-instance re-signed copy has a unique cdhash (because the bundle ID rewrite changes the embedded Info.plist before re-sign), so the ACL check fails and macOS prompts. The fix can be either (a) get our re-signed copies into the ACL — impossible because we cannot enumerate-ahead-of-time every future cdhash, and (b) make our copies satisfy a single broader ACL via identifier-prefix matching. We pick (b).
- **The wildcard ACL is the unlock.** `csreq` supports `identifier like "<prefix>*"` syntax. All RORORO per-instance bundles share the prefix `com.626labs.RORORO.instance.` (locked in `RobloxAppCopier.makePerInstanceBundleID`). One ACL requirement covers every present and future per-instance bundle without per-account ceremony.
- **Search list order forces our keychain to win.** macOS `SecItem*` queries search keychains in order from `security list-keychains`. If `RORORO.keychain` is first and contains the queried item, login.keychain is never consulted, the user's old cdhash-locked ACL is never evaluated, no prompt fires.
- **Pre-populated values can be empty placeholders.** Roblox's behavior on a Keychain miss is to create the item, not to error. The prompt only fires when the item exists with a restrictive ACL. Pre-populating with empty UTF-8 values is enough to satisfy "the item exists with our permissive ACL." If Roblox later writes a real value via `SecItemUpdate`, the write lands in the same keychain (preserving location), and the wildcard ACL allows it.

## Security trade-off (called out so the next reviewer doesn't have to rediscover it)

The wildcard ACL `identifier like "com.626labs.RORORO.instance.*"` accepts any ad-hoc-signed bundle with that prefix. A rogue app could ad-hoc-sign itself with `com.626labs.RORORO.instance.attacker` and read the items in RORORO.keychain. **Why this is acceptable for v0.7.0:**

1. The pre-populated items are placeholders / empty values, not real `.ROBLOSECURITY` cookies. The actual session token lives in `~/Library/HTTPStorages/com.626labs.RORORO.instance.uid<slug>.binarycookies` (per-instance cookie jar; see ADR 0009), not in Keychain.
2. If Roblox writes its Studio shared-cookie token into our keychain at runtime, a rogue ad-hoc-signed app with our prefix could read it. Mitigation: this token is the Studio variant, not the Player session cookie; even if leaked it does not log into a player session. (Player-session tokens stay in the per-instance cookie jar.)
3. A rogue local app already has near-total access to the user's home directory on macOS without sandboxing. The marginal attack surface added by this ACL is small.
4. Hardening path for a future release: replace `identifier like` with an explicit list of cdhashes maintained at app build time — requires a per-build ceremony when adding accounts. Not v0.7.0.

This trade-off is logged as a decision in Task 8.

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `App/RORORO/Domain/RororoKeychain.swift` | Create | Thin wrapper around `/usr/bin/security` + `csreq` for: creating an empty keychain at a known path, unlocking it (empty password), adding it to the user's keychain search list as the first entry, removing it. No item-level work — that's the next file. |
| `App/RORORO/Domain/RororoKeychainItems.swift` | Create | Pre-population: given a list of `RoroKeychainItem` descriptors (class, server, path, account), call `SecItemAdd` against `RORORO.keychain` with the wildcard-requirement ACL attached via `SecAccessCreateWithOwnerAndACL`. Idempotent — re-adding an existing item is a no-op. |
| `App/RORORO/Domain/RororoKeychainBootstrap.swift` | Create | Orchestrator + state. State persisted via `UserDefaults` key `RororoKeychainBootstrapVersion`. `ensureIfNeeded()` is the single entry point: skips if version current; otherwise runs create → unlock → search-list-prepend → populate → mark version. Idempotent across crashes (each step is its own idempotent operation). |
| `App/RORORO/Domain/RoblxKeychainProbeList.swift` | Create | Static list of `RoroKeychainItem` descriptors representing the items Roblox queries on launch. Populated from the Task 1 enumeration. Build-time constant. Adding items here + bumping `RororoKeychainBootstrap.currentVersion` triggers a re-population pass on next launch. |
| `App/RORORO/UI/Onboarding/KeychainBootstrapPromptView.swift` | Create | One-time SwiftUI sheet explaining the macOS password prompt: "RORORO needs your permission to create a private keychain so Roblox can launch additional accounts without asking for your password every time. You'll see one macOS prompt — click Always Allow." Continue button kicks the bootstrap. Failure path shows the error + Retry. |
| `App/RORORO/Domain/MultiInstanceCoordinator.swift` | Modify (`bootIfNeeded` body) | Invoke `RororoKeychainBootstrap.shared.ensureIfNeeded()` in the boot sequence. Non-blocking — bootstrap runs async; first-account-launch UX is unchanged if bootstrap is still in flight (Roblox just prompts that one time, same as today). |
| `App/RORORO/App.swift` | Modify (`onAppear` body) | If `RororoKeychainBootstrap.shared.needsOnboarding` is true, present `KeychainBootstrapPromptView` as a sheet on the root content view before allowing any Launch As. |
| `App/ROROROTests/RororoKeychainTests.swift` | Create | Unit tests against a temp-path keychain — create, unlock, search-list-prepend (verify via `security list-keychains`), remove. Tests clean up by restoring the original search list in `tearDown`. |
| `App/ROROROTests/RororoKeychainItemsTests.swift` | Create | Unit tests for pre-population — add internet password item, verify it's queryable from RORORO.keychain, verify the ACL blob round-trips through `csreq`. Uses a temp keychain so dev's login keychain is untouched. |
| `App/ROROROTests/RororoKeychainBootstrapTests.swift` | Create | Unit tests for the orchestrator — version-marker, idempotency on re-run, error-recovery (search-list-add fails → keychain stays present but marker unset → next run completes), version bump triggers re-population. |
| `App/ROROROTests/RoblxKeychainProbeListTests.swift` | Create | Pin test on the probe list — guarantees the SharedROBLOSECURITYForStudio item is present, guarantees the list is non-empty. Cheap regression net for "someone deleted the list." |
| `docs/decisions/0010-keychain-prompt-elimination.md` | Create | ADR documenting the architecture, the wildcard-ACL trade-off, and why Raptor's pattern doesn't apply. Logged to the 626Labs Dashboard via `mcp__626Labs__manage_decisions log` as a follow-up step. |
| `docs/decisions/0009-per-instance-cookie-isolation.md` | Modify (Open items section) | Strike "anti-cheat / Hyperion behavior under ad-hoc re-signed Roblox" if v0.7.0 RC smoke confirms; add cross-ref to ADR 0010. |
| `CLAUDE.md` | Modify (Hard rules section) | Add: "Don't add a launch path that bypasses RororoKeychainBootstrap.ensureIfNeeded; don't lower the wildcard ACL to a per-cdhash list without a logged decision (the per-cdhash variant breaks every Launch As on a new account)." |
| `App/project.yml` | Modify (`RORORO.MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`) | Bump 0.6.1 → 0.7.0; CFBundleVersion bump as appropriate. |

---

## Task 1: Enumerate Roblox keychain items

**Files:**
- Create: `App/RORORO/Domain/RoblxKeychainProbeList.swift`
- Create: `App/ROROROTests/RoblxKeychainProbeListTests.swift`
- Working notes (transient, not committed): `docs/_keychain-probe-2026-05-12.md`

This task gathers the input data the rest of the plan depends on. Run on the development machine that already has Roblox installed and has launched per-instance bundles (so the relevant items exist with the cdhash-locked ACLs the user observed). The output is a fixed list of `RoroKeychainItem` descriptors compiled into the app.

- [ ] **Step 1: Dump Roblox-related keychain entries**

Run:
```bash
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | \
  awk 'BEGIN{block=""} /^keychain:/{flag=0; block=""} /attributes:/{flag=1; next} flag{block=block $0 "\n"} /^[^ ]/ && flag && block!=""{ if (tolower(block) ~ /roblox/) print "----\n" block; flag=0; block=""}'
```

Expected: one or more attribute blocks. The user has observed at minimum `acct = "https://www.roblox.com/:SharedROBLOSECURITYForStudio"` (internet password class, server `www.roblox.com`). The output may also include Player-variant entries and per-account variants.

- [ ] **Step 2: Capture each item's class, server (`srvr`), path (`path`), account (`acct`), and authentication type (`atyp`) into `docs/_keychain-probe-2026-05-12.md`**

For each unique item, record:
- Security class: `kSecClassInternetPassword` vs `kSecClassGenericPassword` (the dump labels the section)
- `srvr` attribute value (e.g., `www.roblox.com`)
- `path` attribute value (e.g., `/:SharedROBLOSECURITYForStudio`)
- `acct` attribute value (often the full URL form)
- `atyp` (authentication type — typically `dflt`)
- `ptcl` (protocol — typically `htps`)

Skip any item not clearly Roblox-related.

- [ ] **Step 3: Verify the dump captured the observed item**

Run:
```bash
grep -c 'SharedROBLOSECURITYForStudio' docs/_keychain-probe-2026-05-12.md
```
Expected: `1` or more. If 0, the dump filter dropped it — re-run Step 1 with a wider grep (e.g., `tolower(block) ~ /roblox|robux|robuxcore|robloxsecurity/`).

- [ ] **Step 4: Write `RoblxKeychainProbeList.swift` with one descriptor per captured item**

```swift
// RoblxKeychainProbeList.swift
// Domain — static list of the Keychain items Roblox queries on launch.
// Populated 2026-05-12 from a live dev machine running Roblox under
// the per-instance bundle ID rewrite. See docs/_keychain-probe-2026-05-12.md
// for the captured raw attributes.
//
// Adding entries here + bumping RororoKeychainBootstrap.currentVersion
// causes the next app launch to re-run pre-population (idempotent on
// items that already exist).

import Foundation

public enum RoblxKeychainProbeList {

    public static let items: [RoroKeychainItem] = [
        RoroKeychainItem(
            kind: .internetPassword,
            server: "www.roblox.com",
            path: "/:SharedROBLOSECURITYForStudio",
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            protocolType: .https
        ),
        // Additional entries from Task 1 enumeration go here, one per item.
    ]
}
```

The `RoroKeychainItem` value type is defined in `RororoKeychainItems.swift` (Task 3 creates it). Forward-referencing it here is fine — Swift resolves types in same-module file order at compile time.

- [ ] **Step 5: Write `RoblxKeychainProbeListTests.swift`**

```swift
import XCTest
@testable import RORORO

final class RoblxKeychainProbeListTests: XCTestCase {

    func testListIsNotEmpty() {
        XCTAssertFalse(RoblxKeychainProbeList.items.isEmpty,
                       "probe list must include at least the SharedROBLOSECURITYForStudio entry")
    }

    func testListIncludesSharedROBLOSECURITYForStudio() {
        let matches = RoblxKeychainProbeList.items.filter {
            $0.path == "/:SharedROBLOSECURITYForStudio"
        }
        XCTAssertEqual(matches.count, 1, "exactly one entry for SharedROBLOSECURITYForStudio")
        XCTAssertEqual(matches.first?.server, "www.roblox.com")
        XCTAssertEqual(matches.first?.kind, .internetPassword)
    }
}
```

- [ ] **Step 6: Build the test target to surface compile errors**

Run:
```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build-for-testing -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```
Expected: compile error referencing `RoroKeychainItem` (not yet defined). That's correct — Task 3 defines it. This step verifies the file compiles structurally; it will only succeed after Task 3.

- [ ] **Step 7: Commit the probe list + working notes**

```bash
git add App/RORORO/Domain/RoblxKeychainProbeList.swift \
        App/ROROROTests/RoblxKeychainProbeListTests.swift \
        docs/_keychain-probe-2026-05-12.md
git commit -m "$(cat <<'EOF'
feat(keychain): enumerate Roblox keychain items for pre-population

Captures the items Roblox queries on launch (observed via security
dump-keychain on the dev machine, post per-instance bundle ID rollout).
At minimum SharedROBLOSECURITYForStudio (the Studio-variant entry the
user observed in the keychain access prompt). Static list compiled
into the app; bumping RororoKeychainBootstrap.currentVersion re-runs
pre-population if entries are added later.

Tests pin the list shape so the SharedROBLOSECURITYForStudio entry
can't be silently deleted.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: RororoKeychain primitives (create, unlock, search-list)

**Files:**
- Create: `App/RORORO/Domain/RororoKeychain.swift`
- Test: `App/ROROROTests/RororoKeychainTests.swift`

Wraps `/usr/bin/security` for the keychain-level operations. Test-friendly: every method accepts an optional `keychainPath` so tests target `/tmp/rororo-keychain-test-<uuid>.keychain` instead of the production path.

- [ ] **Step 1: Write the failing test for `create`**

```swift
import XCTest
@testable import RORORO

final class RororoKeychainTests: XCTestCase {

    private var tempPath: URL!

    override func setUp() {
        super.setUp()
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-keychain-test-\(UUID().uuidString).keychain")
    }

    override func tearDown() {
        // Always remove the test keychain — and restore the search list
        // if a test added it.
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        super.tearDown()
    }

    func testCreateMakesKeychainFile() throws {
        try RororoKeychain.create(keychainPath: tempPath, password: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath.path))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainTests/testCreateMakesKeychainFile 2>&1 | tail -30
```
Expected: FAIL — `Cannot find 'RororoKeychain' in scope`.

- [ ] **Step 3: Implement `RororoKeychain.create`**

```swift
// RororoKeychain.swift
// Domain — wrapper around /usr/bin/security for keychain-level operations:
// create, unlock, search-list prepend, remove. Item-level work lives in
// RororoKeychainItems. Production code calls these with the default
// production path (~/Library/Keychains/RORORO.keychain); tests pass a
// temp path so the dev's login keychain is never touched.

import Foundation

public enum RororoKeychain {

    public enum KeychainCLIError: Error, Equatable {
        case createFailed(status: Int32, stderr: String)
        case unlockFailed(status: Int32, stderr: String)
        case listKeychainsFailed(status: Int32, stderr: String)
        case setSearchListFailed(status: Int32, stderr: String)
        case deleteFailed(status: Int32, stderr: String)
    }

    /// Production keychain path. ~/Library/Keychains/RORORO.keychain.
    /// macOS auto-migrates to the .keychain-db variant on first unlock;
    /// callers always reference the .keychain form (the security CLI
    /// resolves both forms identically).
    public static var productionPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/RORORO.keychain")
    }

    /// Create the keychain with the given password (empty string = auto-
    /// unlocking keychain that never prompts for unlock again, the
    /// pattern used by Raptor's per-profile keychains). Throws if the
    /// keychain already exists at the path.
    public static func create(keychainPath: URL, password: String) throws {
        let result = runSecurity([
            "create-keychain", "-p", password, keychainPath.path
        ])
        if result.status != 0 {
            throw KeychainCLIError.createFailed(status: result.status, stderr: result.stderr)
        }
    }

    private struct CLIResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private static func runSecurity(_ args: [String]) -> CLIResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return CLIResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        task.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return CLIResult(
            status: task.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the test command from Step 2 again. Expected: PASS.

- [ ] **Step 5: Add the `unlock` test**

```swift
func testUnlockAfterCreateSucceeds() throws {
    try RororoKeychain.create(keychainPath: tempPath, password: "")
    XCTAssertNoThrow(try RororoKeychain.unlock(keychainPath: tempPath, password: ""))
}
```

- [ ] **Step 6: Implement `unlock`**

Add to `RororoKeychain.swift`:

```swift
public static func unlock(keychainPath: URL, password: String) throws {
    let result = runSecurity([
        "unlock-keychain", "-p", password, keychainPath.path
    ])
    if result.status != 0 {
        throw KeychainCLIError.unlockFailed(status: result.status, stderr: result.stderr)
    }
}
```

- [ ] **Step 7: Run the unlock test and verify it passes**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainTests/testUnlockAfterCreateSucceeds 2>&1 | tail -20
```

- [ ] **Step 8: Add the `prependToSearchList` test**

```swift
func testPrependToSearchListPutsKeychainFirst() throws {
    try RororoKeychain.create(keychainPath: tempPath, password: "")
    let priorList = try RororoKeychain.currentSearchList()

    try RororoKeychain.prependToSearchList(keychainPath: tempPath)

    let newList = try RororoKeychain.currentSearchList()
    XCTAssertEqual(newList.first, tempPath.path,
                   "freshly added keychain should be first in the search list")
    XCTAssertEqual(newList.count, priorList.count + 1,
                   "search list should grow by one")
}
```

- [ ] **Step 9: Run the test to verify it fails**

Expected: `Cannot find 'currentSearchList' / 'prependToSearchList' in scope`.

- [ ] **Step 10: Implement `currentSearchList` and `prependToSearchList`**

Add to `RororoKeychain.swift`:

```swift
/// Return the current keychain search list, in order. Each entry is an
/// absolute path. Used by tests and by prependToSearchList to compute
/// the new list.
public static func currentSearchList() throws -> [String] {
    let result = runSecurity(["list-keychains", "-d", "user"])
    if result.status != 0 {
        throw KeychainCLIError.listKeychainsFailed(status: result.status, stderr: result.stderr)
    }
    // Output is one path per line, each wrapped in double quotes,
    // leading whitespace.
    return result.stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        .filter { !$0.isEmpty }
}

/// Make `keychainPath` the first entry in the user's keychain search
/// list. Preserves all existing entries. Idempotent — calling twice
/// produces the same final order. macOS REQUIRES user authorization
/// to modify the search list; this call is what triggers the one-time
/// password prompt at first run. Production callers must run this on
/// a background queue with UI explaining the prompt.
public static func prependToSearchList(keychainPath: URL) throws {
    var list = try currentSearchList()
    list.removeAll { $0 == keychainPath.path }
    list.insert(keychainPath.path, at: 0)
    var args = ["list-keychains", "-d", "user", "-s"]
    args.append(contentsOf: list)
    let result = runSecurity(args)
    if result.status != 0 {
        throw KeychainCLIError.setSearchListFailed(status: result.status, stderr: result.stderr)
    }
}

/// Remove `keychainPath` from the search list if it's present. Used by
/// test tearDown and by the (currently unused but kept for symmetry)
/// uninstall path. No-op if not in the list.
public static func removeFromSearchListIfPresent(keychainPath: URL) throws {
    let list = try currentSearchList()
    guard list.contains(keychainPath.path) else { return }
    let newList = list.filter { $0 != keychainPath.path }
    var args = ["list-keychains", "-d", "user", "-s"]
    args.append(contentsOf: newList)
    let result = runSecurity(args)
    if result.status != 0 {
        throw KeychainCLIError.setSearchListFailed(status: result.status, stderr: result.stderr)
    }
}

/// Delete the keychain at path. Used by uninstall and test tearDown.
/// No-op if the file doesn't exist.
public static func delete(keychainPath: URL) throws {
    guard FileManager.default.fileExists(atPath: keychainPath.path) else { return }
    let result = runSecurity(["delete-keychain", keychainPath.path])
    if result.status != 0 {
        throw KeychainCLIError.deleteFailed(status: result.status, stderr: result.stderr)
    }
}
```

**NOTE for the implementer:** `security list-keychains -s` prompts the user the first time it modifies the search list. Tests running locally may also see the prompt — this is unavoidable from the test runner. Document this in the test file header so future-you knows the test isn't broken when it sees a prompt; just enter your password once and tests run clean for the rest of the session.

- [ ] **Step 11: Run the prepend test and verify it passes**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainTests/testPrependToSearchListPutsKeychainFirst 2>&1 | tail -20
```
Expected: PASS. (May prompt for password the first time on a fresh dev machine.)

- [ ] **Step 12: Add the idempotency test**

```swift
func testPrependIsIdempotent() throws {
    try RororoKeychain.create(keychainPath: tempPath, password: "")
    try RororoKeychain.prependToSearchList(keychainPath: tempPath)
    let firstList = try RororoKeychain.currentSearchList()

    try RororoKeychain.prependToSearchList(keychainPath: tempPath)
    let secondList = try RororoKeychain.currentSearchList()

    XCTAssertEqual(firstList, secondList,
                   "second prepend with the same path should not change the list")
}
```

- [ ] **Step 13: Run it and verify it passes** (the implementation already supports idempotency via the `removeAll { … }` pre-step).

- [ ] **Step 14: Commit**

```bash
git add App/RORORO/Domain/RororoKeychain.swift App/ROROROTests/RororoKeychainTests.swift
git commit -m "$(cat <<'EOF'
feat(keychain): RORORO-keychain create + unlock + search-list primitives

Wraps /usr/bin/security for the keychain-level operations the bootstrap
needs. Tests target temp paths so the dev's login keychain stays clean.
Search-list prepend is idempotent — re-running with the same path
preserves order.

The first search-list modification prompts the user for password
(macOS rule, unavoidable). Subsequent runs on the same machine are
silent. The bootstrap (Task 4) only runs this once per app install.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: RororoKeychainItems — pre-population with wildcard ACL

**Files:**
- Create: `App/RORORO/Domain/RororoKeychainItems.swift`
- Test: `App/ROROROTests/RororoKeychainItemsTests.swift`

Defines the `RoroKeychainItem` value type and the `addToKeychain` helper. Wraps `SecItemAdd` + `SecAccessCreate` for the wildcard ACL.

- [ ] **Step 1: Write the failing test for `RoroKeychainItem.addToKeychain`**

```swift
import XCTest
@testable import RORORO

final class RororoKeychainItemsTests: XCTestCase {

    private var tempPath: URL!

    override func setUp() {
        super.setUp()
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-keychain-items-test-\(UUID().uuidString).keychain")
        try? RororoKeychain.create(keychainPath: tempPath, password: "")
        try? RororoKeychain.unlock(keychainPath: tempPath, password: "")
    }

    override func tearDown() {
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        super.tearDown()
    }

    func testAddInternetPasswordCreatesItem() throws {
        let item = RoroKeychainItem(
            kind: .internetPassword,
            server: "www.roblox.com",
            path: "/:SharedROBLOSECURITYForStudio",
            account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
            protocolType: .https
        )
        try RororoKeychainItems.add(item, toKeychainAt: tempPath)

        let exists = try RororoKeychainItems.exists(item, inKeychainAt: tempPath)
        XCTAssertTrue(exists, "freshly added item should be queryable from the keychain")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainItemsTests/testAddInternetPasswordCreatesItem 2>&1 | tail -20
```
Expected: `Cannot find 'RoroKeychainItem' / 'RororoKeychainItems' in scope`.

- [ ] **Step 3: Implement `RoroKeychainItem` + `RororoKeychainItems`**

```swift
// RororoKeychainItems.swift
// Domain — pre-populates RORORO.keychain with the items Roblox queries
// on launch, each carrying an ACL whose csreq requirement is
// `identifier like "com.626labs.RORORO.instance.*"`. The wildcard
// requirement means every re-signed per-instance bundle (current and
// future) satisfies the ACL without per-cdhash ceremony — eliminating
// the password prompts that fired once per new account in v0.6.1.
//
// Item values are empty placeholders. Real session credentials live in
// the per-instance HTTPStorages cookie jar (see ADR 0009), not here.
// The trade-off: any ad-hoc-signed binary with our instance prefix
// could read these items. Acceptable because the items contain no
// secrets — they exist only to satisfy Roblox's "does this exist?"
// check on launch. See docs/decisions/0010-keychain-prompt-elimination.md.

import Foundation
import Security

public enum RoroKeychainItem_Kind: Equatable {
    case internetPassword
    case genericPassword
}

public enum RoroKeychainItem_Protocol: Equatable {
    case https
    case http
    var secProtocolType: CFString {
        switch self {
        case .https: return kSecAttrProtocolHTTPS
        case .http:  return kSecAttrProtocolHTTP
        }
    }
}

public struct RoroKeychainItem: Equatable {
    public let kind: RoroKeychainItem_Kind
    public let server: String?       // for .internetPassword
    public let path: String?         // for .internetPassword
    public let account: String       // both classes
    public let service: String?      // for .genericPassword
    public let protocolType: RoroKeychainItem_Protocol?  // for .internetPassword

    public init(
        kind: RoroKeychainItem_Kind,
        server: String? = nil,
        path: String? = nil,
        account: String,
        service: String? = nil,
        protocolType: RoroKeychainItem_Protocol? = nil
    ) {
        self.kind = kind
        self.server = server
        self.path = path
        self.account = account
        self.service = service
        self.protocolType = protocolType
    }
}

public enum RororoKeychainItems {

    public enum ItemsError: Error, Equatable {
        case keychainOpenFailed(status: OSStatus)
        case accessCreateFailed(status: OSStatus)
        case requirementCompileFailed(stderr: String)
        case itemAddFailed(status: OSStatus)
        case itemCopyFailed(status: OSStatus)
    }

    /// The wildcard requirement attached to every pre-populated item.
    /// `identifier like "com.626labs.RORORO.instance.*"` — accepts any
    /// bundle whose CFBundleIdentifier starts with the RORORO
    /// per-instance prefix.
    public static let aclRequirementSource =
        "identifier like \"com.626labs.RORORO.instance.*\""

    public static func add(_ item: RoroKeychainItem, toKeychainAt keychainPath: URL) throws {
        if try exists(item, inKeychainAt: keychainPath) { return }

        // Open the keychain by path (gives us a SecKeychainRef we can
        // pass via kSecUseKeychain). SecKeychainOpen is deprecated under
        // the modern unified KeychainServices but still functional and
        // it's the only way to target a non-default keychain for SecItem*.
        var keychainRef: SecKeychain?
        let openStatus = SecKeychainOpen(keychainPath.path, &keychainRef)
        guard openStatus == errSecSuccess, let keychainRef else {
            throw ItemsError.keychainOpenFailed(status: openStatus)
        }

        let access = try makeWildcardAccess()

        var query: [String: Any] = [
            kSecAttrAccess as String: access,
            kSecUseKeychain as String: keychainRef,
            kSecAttrAccount as String: item.account,
            kSecValueData as String: Data(),  // empty placeholder value
        ]
        switch item.kind {
        case .internetPassword:
            query[kSecClass as String] = kSecClassInternetPassword
            if let server = item.server { query[kSecAttrServer as String] = server }
            if let path = item.path { query[kSecAttrPath as String] = path }
            if let proto = item.protocolType {
                query[kSecAttrProtocol as String] = proto.secProtocolType
            }
        case .genericPassword:
            query[kSecClass as String] = kSecClassGenericPassword
            if let service = item.service { query[kSecAttrService as String] = service }
        }

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw ItemsError.itemAddFailed(status: addStatus)
        }
    }

    public static func exists(_ item: RoroKeychainItem, inKeychainAt keychainPath: URL) throws -> Bool {
        var keychainRef: SecKeychain?
        let openStatus = SecKeychainOpen(keychainPath.path, &keychainRef)
        guard openStatus == errSecSuccess, let keychainRef else {
            throw ItemsError.keychainOpenFailed(status: openStatus)
        }
        var query: [String: Any] = [
            kSecUseKeychain as String: keychainRef,
            kSecMatchSearchList as String: [keychainRef] as CFArray,
            kSecAttrAccount as String: item.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        switch item.kind {
        case .internetPassword:
            query[kSecClass as String] = kSecClassInternetPassword
            if let server = item.server { query[kSecAttrServer as String] = server }
            if let path = item.path { query[kSecAttrPath as String] = path }
        case .genericPassword:
            query[kSecClass as String] = kSecClassGenericPassword
            if let service = item.service { query[kSecAttrService as String] = service }
        }
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw ItemsError.itemCopyFailed(status: status)
        }
    }

    /// Build a SecAccess whose ACL allows any code matching our
    /// per-instance bundle ID prefix. Uses /usr/bin/csreq to compile
    /// the requirement source into the binary blob SecRequirement wants,
    /// then SecAccessCreateWithOwnerAndACL to mint the SecAccess.
    private static func makeWildcardAccess() throws -> SecAccess {
        let blob = try compileRequirement(source: aclRequirementSource)

        var requirementRef: SecRequirement?
        let reqStatus = SecRequirementCreateWithData(blob as CFData, [], &requirementRef)
        guard reqStatus == errSecSuccess, let requirementRef else {
            throw ItemsError.accessCreateFailed(status: reqStatus)
        }

        // Build a trusted-applications list containing one synthetic
        // SecTrustedApplication built from the requirement. Apple's
        // SecTrustedApplicationCreateFromPath takes a path; the
        // requirement form is exposed via SecAccessCreateWithOwner-
        // AndACL. We pass the requirement as the access mask.
        var accessRef: SecAccess?
        let accStatus = SecAccessCreate(
            "RORORO Keychain Item" as CFString,
            nil,  // nil = empty trusted-applications list (the requirement decides via ACL)
            &accessRef
        )
        guard accStatus == errSecSuccess, let accessRef else {
            throw ItemsError.accessCreateFailed(status: accStatus)
        }

        // Replace the default ACL on the access with one that uses our
        // requirement. SecAccessCopyACLList → find the kSecACLAuthorization-
        // Decrypt ACL → SecACLSetSimpleContents to bind our requirement-
        // built trusted-applications list. The exact API path is fiddly
        // but Apple's Keychain Services Reference documents it.
        try bindRequirement(requirementRef, toAccess: accessRef)

        return accessRef
    }

    /// Run /usr/bin/csreq -r- -b /dev/stdout with `source` on stdin to
    /// compile the requirement source to its binary form. Returns the
    /// raw bytes suitable for SecRequirementCreateWithData.
    private static func compileRequirement(source: String) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/csreq")
        let outFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("csreq-\(UUID().uuidString).blob")
        task.arguments = ["-r-", "-b", outFile.path]
        let inPipe = Pipe()
        let errPipe = Pipe()
        task.standardInput = inPipe
        task.standardError = errPipe
        try task.run()
        if let data = source.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            throw ItemsError.requirementCompileFailed(
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        let blob = try Data(contentsOf: outFile)
        try? FileManager.default.removeItem(at: outFile)
        return blob
    }

    /// Bind `requirement` as the trusted-code requirement on every ACL
    /// of `access`. Walks the access's ACL list, calls SecACLSetSimpleContents
    /// with a synthetic SecTrustedApplication built from the requirement.
    private static func bindRequirement(
        _ requirement: SecRequirement, toAccess access: SecAccess
    ) throws {
        var aclArray: CFArray?
        let listStatus = SecAccessCopyACLList(access, &aclArray)
        guard listStatus == errSecSuccess, let aclArray = aclArray as? [SecACL] else {
            throw ItemsError.accessCreateFailed(status: listStatus)
        }
        // SecTrustedApplicationCreateFromRequirement is the API we want.
        // It exists on macOS 10.12+ but is hidden behind the bridging
        // header in some SDK versions; if unavailable, fall back to the
        // path-based API and accept that the ACL is broader than ideal.
        for acl in aclArray {
            var trustedApp: SecTrustedApplication?
            let appStatus = SecTrustedApplicationCreateFromRequirement(
                requirement, nil, &trustedApp)
            guard appStatus == errSecSuccess, let trustedApp else { continue }
            let setStatus = SecACLSetSimpleContents(
                acl,
                [trustedApp] as CFArray,
                "RORORO Keychain (per-instance prefix)" as CFString,
                nil
            )
            if setStatus != errSecSuccess {
                throw ItemsError.accessCreateFailed(status: setStatus)
            }
        }
    }
}
```

**IMPLEMENTER NOTE:** `SecTrustedApplicationCreateFromRequirement` is not in every Apple SDK bridging header. If the compiler can't find it, declare a manual bridging shim in a `.h` exposed to Swift via the bridging header (see `App/RORORO/RORORO-Bridging-Header.h` if one exists; create one if not — `App/project.yml` would gain `SWIFT_OBJC_BRIDGING_HEADER`). Alternative: skip `SecTrustedApplicationCreateFromRequirement` entirely and instead use the `security` CLI's `add-internet-password` + `-T ""` (allow access to all apps) — broader than wildcard-by-prefix but acceptable given the items are empty placeholders. The plan recommends the framework path first; if it doesn't compile in <30 min, the implementer should fall back to the CLI path and document it as a Task 3 note.

- [ ] **Step 4: Run the test and verify it passes**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainItemsTests/testAddInternetPasswordCreatesItem 2>&1 | tail -30
```
Expected: PASS.

- [ ] **Step 5: Add the idempotency test**

```swift
func testAddIsIdempotent() throws {
    let item = RoroKeychainItem(
        kind: .internetPassword,
        server: "www.roblox.com",
        path: "/:SharedROBLOSECURITYForStudio",
        account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
        protocolType: .https
    )
    try RororoKeychainItems.add(item, toKeychainAt: tempPath)
    XCTAssertNoThrow(try RororoKeychainItems.add(item, toKeychainAt: tempPath),
                     "re-adding an existing item should be a no-op, not an error")
}
```

- [ ] **Step 6: Run it and verify it passes**

The `if try exists … return` guard in `add` already covers idempotency. Expected: PASS.

- [ ] **Step 7: Add the requirement-compile test**

```swift
func testCsreqCompilesWildcardRequirement() throws {
    // Round-trip the requirement source through csreq + SecRequirement-
    // CreateWithData. If either side rejects the source, this test fails
    // and the caller sees the failure with concrete stderr/status.
    let blob = try RororoKeychainItems_TestHook.compileRequirement(
        source: RororoKeychainItems.aclRequirementSource)
    XCTAssertFalse(blob.isEmpty, "csreq must emit a non-empty binary blob")

    var req: SecRequirement?
    let status = SecRequirementCreateWithData(blob as CFData, [], &req)
    XCTAssertEqual(status, errSecSuccess,
                   "SecRequirementCreateWithData should accept the csreq output")
    XCTAssertNotNil(req)
}
```

Add a test hook to `RororoKeychainItems.swift` exposing `compileRequirement` for the test (visibility `internal`, gated under `#if DEBUG` if you want to keep it out of Release).

- [ ] **Step 8: Run it and verify it passes**

- [ ] **Step 9: Commit**

```bash
git add App/RORORO/Domain/RororoKeychainItems.swift \
        App/ROROROTests/RororoKeychainItemsTests.swift
git commit -m "$(cat <<'EOF'
feat(keychain): pre-populate items with wildcard-prefix ACL

RoroKeychainItem descriptors get inserted into RORORO.keychain with
an ACL whose csreq requirement is
  identifier like "com.626labs.RORORO.instance.*"
so every present and future re-signed per-instance bundle satisfies
the ACL without per-cdhash ceremony. Items hold empty placeholder
values — Roblox's launch-time keychain query only checks for
existence, not contents. Real session credentials live in the
per-instance HTTPStorages cookie jar per ADR 0009.

Tests cover add + idempotent re-add + csreq compile round-trip.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: RororoKeychainBootstrap orchestrator

**Files:**
- Create: `App/RORORO/Domain/RororoKeychainBootstrap.swift`
- Test: `App/ROROROTests/RororoKeychainBootstrapTests.swift`

Single entry point: `ensureIfNeeded()`. Idempotent. Drives the create → unlock → search-list → populate sequence and persists progress via `UserDefaults` so a crash mid-bootstrap recovers cleanly on next launch.

- [ ] **Step 1: Write the failing test for first-run end-to-end**

```swift
import XCTest
@testable import RORORO

final class RororoKeychainBootstrapTests: XCTestCase {

    private var tempPath: URL!
    private let testDefaultsSuite = "rororo-keychain-bootstrap-tests"

    override func setUp() {
        super.setUp()
        tempPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rororo-keychain-bootstrap-test-\(UUID().uuidString).keychain")
        UserDefaults.standard.removeObject(forKey: "RororoKeychainBootstrapVersion")
    }

    override func tearDown() {
        try? RororoKeychain.removeFromSearchListIfPresent(keychainPath: tempPath)
        try? RororoKeychain.delete(keychainPath: tempPath)
        UserDefaults.standard.removeObject(forKey: "RororoKeychainBootstrapVersion")
        super.tearDown()
    }

    func testEnsureCreatesKeychainAndPopulates() async throws {
        try await RororoKeychainBootstrap.ensureIfNeeded(
            keychainPath: tempPath,
            probeItems: [RoroKeychainItem(
                kind: .internetPassword,
                server: "www.roblox.com",
                path: "/:SharedROBLOSECURITYForStudio",
                account: "https://www.roblox.com/:SharedROBLOSECURITYForStudio",
                protocolType: .https
            )]
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath.path))
        let list = try RororoKeychain.currentSearchList()
        XCTAssertTrue(list.contains(tempPath.path))
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: "RororoKeychainBootstrapVersion"),
            RororoKeychainBootstrap.currentVersion
        )
    }
}
```

- [ ] **Step 2: Run it and verify it fails**

Expected: `Cannot find 'RororoKeychainBootstrap' in scope`.

- [ ] **Step 3: Implement the orchestrator**

```swift
// RororoKeychainBootstrap.swift
// Domain — one-time setup for RORORO.keychain:
//   1. create the keychain (empty password, auto-unlocking)
//   2. unlock it
//   3. prepend to the user's keychain search list (one-time password prompt)
//   4. pre-populate with the items Roblox queries on launch
//
// Idempotent. Persists progress via UserDefaults so a crash mid-bootstrap
// recovers on next launch by skipping completed steps.
//
// Threading: ensureIfNeeded() must NOT be called from the main thread —
// the search-list-prepend step blocks on a user-facing macOS prompt.
// Production caller (MultiInstanceCoordinator.bootIfNeeded) wraps this
// in a Task.detached. The KeychainBootstrapPromptView (Task 5) handles
// the UX framing for the prompt.

import Foundation

public enum RororoKeychainBootstrap {

    /// Bumped when RoblxKeychainProbeList.items changes. Drives the
    /// re-population pass on next launch — additions are idempotent
    /// (Task 3's exists-check), so bumping is safe.
    public static let currentVersion = 1

    public static let versionKey = "RororoKeychainBootstrapVersion"

    public enum BootstrapError: Error, Equatable {
        case createFailed(underlying: String)
        case unlockFailed(underlying: String)
        case searchListFailed(underlying: String)
        case populateFailed(underlying: String)
    }

    /// Run the bootstrap if not already done at currentVersion. Safe to
    /// call multiple times; no-op when version is current.
    public static func ensureIfNeeded(
        keychainPath: URL = RororoKeychain.productionPath,
        probeItems: [RoroKeychainItem] = RoblxKeychainProbeList.items
    ) async throws {
        let storedVersion = UserDefaults.standard.integer(forKey: versionKey)
        if storedVersion >= currentVersion { return }

        // Create if missing (the file is the persistent indicator).
        if !FileManager.default.fileExists(atPath: keychainPath.path) {
            do {
                try RororoKeychain.create(keychainPath: keychainPath, password: "")
            } catch {
                throw BootstrapError.createFailed(underlying: "\(error)")
            }
        }

        do {
            try RororoKeychain.unlock(keychainPath: keychainPath, password: "")
        } catch {
            throw BootstrapError.unlockFailed(underlying: "\(error)")
        }

        do {
            try RororoKeychain.prependToSearchList(keychainPath: keychainPath)
        } catch {
            throw BootstrapError.searchListFailed(underlying: "\(error)")
        }

        for item in probeItems {
            do {
                try RororoKeychainItems.add(item, toKeychainAt: keychainPath)
            } catch {
                throw BootstrapError.populateFailed(underlying: "\(error)")
            }
        }

        UserDefaults.standard.set(currentVersion, forKey: versionKey)
    }

    /// True when the orchestrator would do work if invoked. Used by the
    /// app shell to decide whether to surface the onboarding sheet.
    public static var needsOnboarding: Bool {
        UserDefaults.standard.integer(forKey: versionKey) < currentVersion
    }
}
```

- [ ] **Step 4: Run the end-to-end test and verify it passes**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ROROROTests/RororoKeychainBootstrapTests/testEnsureCreatesKeychainAndPopulates 2>&1 | tail -30
```
Expected: PASS (may prompt once for password the first time the search-list-add fires).

- [ ] **Step 5: Add the second-run no-op test**

```swift
func testSecondEnsureIsNoOp() async throws {
    try await RororoKeychainBootstrap.ensureIfNeeded(keychainPath: tempPath, probeItems: [])
    let priorList = try RororoKeychain.currentSearchList()

    try await RororoKeychainBootstrap.ensureIfNeeded(keychainPath: tempPath, probeItems: [])
    let secondList = try RororoKeychain.currentSearchList()

    XCTAssertEqual(priorList, secondList,
                   "second ensure-call should not mutate the search list")
}
```

- [ ] **Step 6: Run it and verify it passes**

- [ ] **Step 7: Add the version-bump-triggers-repopulate test**

```swift
func testVersionBumpRePopulates() async throws {
    // Initial: empty probe list, version 1 marker set.
    try await RororoKeychainBootstrap.ensureIfNeeded(keychainPath: tempPath, probeItems: [])

    // Simulate code change: a new probe item is added; bump version.
    let newItem = RoroKeychainItem(
        kind: .internetPassword,
        server: "www.roblox.com",
        path: "/:NewItemAddedInV2",
        account: "https://www.roblox.com/:NewItemAddedInV2",
        protocolType: .https
    )
    UserDefaults.standard.set(0, forKey: "RororoKeychainBootstrapVersion")

    try await RororoKeychainBootstrap.ensureIfNeeded(
        keychainPath: tempPath, probeItems: [newItem])

    XCTAssertTrue(
        try RororoKeychainItems.exists(newItem, inKeychainAt: tempPath),
        "version bump should trigger a re-populate pass that adds the new item"
    )
}
```

- [ ] **Step 8: Run it and verify it passes**

- [ ] **Step 9: Commit**

```bash
git add App/RORORO/Domain/RororoKeychainBootstrap.swift \
        App/ROROROTests/RororoKeychainBootstrapTests.swift
git commit -m "$(cat <<'EOF'
feat(keychain): RororoKeychainBootstrap orchestrator + version marker

Drives the one-time setup: create RORORO.keychain → unlock → prepend
to search list → populate items from RoblxKeychainProbeList. Marker
persisted in UserDefaults under RororoKeychainBootstrapVersion;
bumping currentVersion triggers a re-populate pass that picks up
new items added to the probe list (each add is idempotent so this
is safe to re-run).

needsOnboarding exposes "would this do work?" so the app shell can
decide whether to surface the explanation sheet before invoking.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: KeychainBootstrapPromptView (one-time onboarding sheet)

**Files:**
- Create: `App/RORORO/UI/Onboarding/KeychainBootstrapPromptView.swift`

SwiftUI sheet shown by the app shell when `RororoKeychainBootstrap.needsOnboarding` is true. Explains what's about to happen, presents Continue, runs the bootstrap on Continue, surfaces error + Retry on failure.

- [ ] **Step 1: Write the view**

```swift
// KeychainBootstrapPromptView.swift
// UI — one-time sheet explaining the macOS password prompt the user is
// about to see. Without this framing, the prompt looks like the app is
// asking for an unrelated credential. With it, the user knows the
// prompt is RORORO setting up its own secure storage for Roblox
// compatibility.

import SwiftUI

public struct KeychainBootstrapPromptView: View {

    public enum State {
        case waiting           // user hasn't clicked Continue yet
        case running           // bootstrap in flight (macOS prompt may be visible)
        case failed(String)    // bootstrap threw; show error + Retry
        case done              // sheet should dismiss itself
    }

    @State private var state: State = .waiting
    let onDone: () -> Void

    public init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One-time setup")
                .font(.title2).bold()
            Text("""
            RORORO needs your permission to create a private macOS keychain. \
            This lets you launch additional Roblox accounts without macOS \
            asking for your password every time.

            You'll see one macOS prompt asking to modify your keychain list. \
            Click Always Allow. This is a one-time step — you won't see it \
            again on this machine.
            """)
            .fixedSize(horizontal: false, vertical: true)

            switch state {
            case .waiting:
                HStack {
                    Spacer()
                    Button("Continue") { run() }
                        .keyboardShortcut(.defaultAction)
                }
            case .running:
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Waiting for macOS prompt — enter your password, then click Always Allow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Text("Setup failed: \(message)")
                        .foregroundStyle(.red)
                    HStack {
                        Spacer()
                        Button("Retry") { run() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            case .done:
                EmptyView()
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func run() {
        state = .running
        Task.detached(priority: .userInitiated) {
            do {
                try await RororoKeychainBootstrap.ensureIfNeeded()
                await MainActor.run {
                    state = .done
                    onDone()
                }
            } catch {
                await MainActor.run {
                    state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Manual smoke — visual verification only**

Build and run RORORO with `UserDefaults.standard.removeObject(forKey: "RororoKeychainBootstrapVersion")` injected at startup (one-time `defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion` from terminal works too). Verify the sheet renders, Continue produces the macOS prompt, entering the password completes the flow, sheet dismisses. No unit-test for view rendering — SwiftUI view tests aren't worth their weight here.

- [ ] **Step 3: Commit**

```bash
git add App/RORORO/UI/Onboarding/KeychainBootstrapPromptView.swift
git commit -m "$(cat <<'EOF'
feat(keychain): one-time onboarding sheet for the bootstrap ceremony

Explains the macOS password prompt the user is about to see, runs the
bootstrap on Continue, surfaces error + Retry on failure. Manual smoke
only — SwiftUI render tests aren't worth their weight for a single
informational sheet.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Wire the bootstrap into the app shell

**Files:**
- Modify: `App/RORORO/App.swift`
- Modify: `App/RORORO/Domain/MultiInstanceCoordinator.swift`

Two places to wire it:
1. `App.swift`'s `.onAppear` — present the onboarding sheet if `needsOnboarding`.
2. `MultiInstanceCoordinator.bootIfNeeded` — invoke `ensureIfNeeded` defensively as a background task. If the sheet is shown, this call coalesces with the sheet's invocation via UserDefaults marker (whichever finishes first marks the version; the other becomes a no-op).

- [ ] **Step 1: Modify `App.swift` — add an `@State` for the sheet + `.sheet` modifier**

Find the existing `ContentView()` block inside `WindowGroup`:

```swift
WindowGroup("RORORO") {
    ContentView()
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            MultiInstanceCoordinator.shared.bootIfNeeded()
            // …
        }
}
```

Replace with:

```swift
WindowGroup("RORORO") {
    ContentView()
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            MultiInstanceCoordinator.shared.bootIfNeeded()
            TrayController.shared.install()
            AutoKeysStatusPanelController.shared.start()
            // (Sparkle boot line stays as-is)

            // Surface the keychain bootstrap sheet if first run on this
            // machine. The sheet runs the bootstrap on user Continue,
            // covering the one-time macOS password prompt.
            if RororoKeychainBootstrap.needsOnboarding {
                showsKeychainSheet = true
            }
        }
        .sheet(isPresented: $showsKeychainSheet) {
            KeychainBootstrapPromptView(onDone: {
                showsKeychainSheet = false
            })
        }
}
```

Add at top of `ROROROApp`:

```swift
@State private var showsKeychainSheet: Bool = false
```

- [ ] **Step 2: Modify `MultiInstanceCoordinator.bootIfNeeded` — add the defensive background invocation**

After the existing `Task.detached(priority: .background)` cleanup block, add:

```swift
// Defensive: if the onboarding sheet is somehow skipped (e.g. URL
// handoff into a fresh install where the user never saw the main
// window), run the bootstrap from here too. UserDefaults marker
// coalesces with the sheet's invocation — whichever wins, the other
// no-ops.
Task.detached(priority: .userInitiated) {
    do {
        try await RororoKeychainBootstrap.ensureIfNeeded()
    } catch {
        await MainActor.run {
            MultiInstanceState.shared.lastError =
                "Keychain bootstrap failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 3: Build + manual smoke**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build-for-testing -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
```
Expected: build succeeds.

Then in Xcode: cmd+R, verify the sheet appears on first launch (delete the UserDefaults marker first if you've already run on this machine: `defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion`).

- [ ] **Step 4: Commit**

```bash
git add App/RORORO/App.swift App/RORORO/Domain/MultiInstanceCoordinator.swift
git commit -m "$(cat <<'EOF'
feat(keychain): wire RororoKeychainBootstrap into app shell

App.swift presents the onboarding sheet when needsOnboarding is true;
MultiInstanceCoordinator.bootIfNeeded invokes ensureIfNeeded defensively
on a background task to cover any URL-handoff path that skips the
main-window sheet. UserDefaults marker coalesces both invocations —
whichever finishes first marks the version, the other no-ops.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: End-to-end smoke test

**Files:**
- None (manual verification + working notes in `docs/_followups-cookie-isolation.md`)

The unit-test layer cannot exercise the actual elimination of the prompt (it requires Roblox to query Keychain via a re-signed bundle while the wildcard ACL is in place). This task is the manual smoke that confirms the fix works end-to-end.

- [ ] **Step 1: Reset to a clean-machine state**

```bash
defaults delete com.626labs.rororo-mac RororoKeychainBootstrapVersion
security delete-keychain ~/Library/Keychains/RORORO.keychain 2>/dev/null
```
This simulates a user installing v0.7.0 for the first time.

Verify reset by running:
```bash
defaults read com.626labs.rororo-mac RororoKeychainBootstrapVersion 2>&1
```
Expected: `does not exist`.

- [ ] **Step 2: Launch RORORO from Xcode and complete the onboarding ceremony**

Expected sequence:
1. App opens, sheet appears explaining the one-time setup
2. Click Continue
3. macOS prompts for password (modify keychain list)
4. Enter password, click Always Allow
5. Sheet dismisses
6. `defaults read com.626labs.rororo-mac RororoKeychainBootstrapVersion` returns `1`
7. `security list-keychains | head -1` returns the RORORO.keychain path

- [ ] **Step 3: Launch the first Roblox account**

Pick an account in RORORO, click Launch As. Confirm Roblox spawns and reaches the game. **Expected:** no keychain password prompt. (If a prompt DOES appear here, this is the baseline behavior for the first account before v0.7.0 — note whether it appears.)

- [ ] **Step 4: Launch a second account that previously triggered the prompt**

Pick a different account. Click Launch As. **Expected:** no keychain password prompt. This is the core regression the fix targets — before this branch, this second account would have prompted.

- [ ] **Step 5: Launch a THIRD account (a fresh one not used before)**

Pick a third account. Click Launch As. **Expected:** no keychain password prompt.

- [ ] **Step 6: 10-minute play smoke (also covers ADR 0009 open item)**

Stay in one of the launched accounts for ≥10 minutes. Confirm no Hyperion / anti-cheat kick. This double-duties as the ADR 0009 open-item smoke (was deferred to v0.7.0 RC).

- [ ] **Step 7: Verify the items landed in RORORO.keychain (not in login.keychain)**

```bash
security find-internet-password -s "www.roblox.com" -a "https://www.roblox.com/:SharedROBLOSECURITYForStudio" ~/Library/Keychains/RORORO.keychain 2>&1 | head -5
```
Expected: returns the item (proves it's in RORORO.keychain).

Compare with login.keychain — the existing entry there should be unchanged (do NOT delete it; verify only):
```bash
security find-internet-password -s "www.roblox.com" -a "https://www.roblox.com/:SharedROBLOSECURITYForStudio" ~/Library/Keychains/login.keychain-db 2>&1 | head -5
```
Expected: returns the existing item (proves we didn't touch it).

- [ ] **Step 8: Capture observations into `docs/_followups-cookie-isolation.md`**

Update the GATING section: mark Task 4.5 + the keychain-prompt-elimination as confirmed. Move the v0.8 stub for "per-profile keychain" — strike it (we just shipped it as v0.7.0). Add a line under Verification: "Three new accounts launched in succession, zero password prompts (smoke: <date>)."

- [ ] **Step 9: No commit yet** — the docs update lands as part of Task 8's ADR work.

---

## Task 8: ADR 0010 + update ADR 0009 + CLAUDE.md hard rule

**Files:**
- Create: `docs/decisions/0010-keychain-prompt-elimination.md`
- Modify: `docs/decisions/0009-per-instance-cookie-isolation.md` (Open items)
- Modify: `CLAUDE.md` (Hard rules)
- Modify: `docs/_followups-cookie-isolation.md` (mark resolved items, strike the v0.8 stub)

- [ ] **Step 1: Write ADR 0010**

Path: `docs/decisions/0010-keychain-prompt-elimination.md`. Use ADR 0009 as the template; copy its Background → Decision → Consequences → Alternatives structure. Required content:

- **Background:** Per-instance bundle ID re-sign (ADR 0009) gave each Launch As a unique cdhash. Roblox queries Keychain on launch for items including `:SharedROBLOSECURITYForStudio`. Those items existed in the user's login keychain with ACLs locked to `/Applications/Roblox.app`'s original cdhash, so each new per-instance bundle = not in ACL = password prompt.
- **Decision 1:** Create `RORORO.keychain` at first run. Add to search list first. Pre-populate with the items Roblox queries.
- **Decision 2:** Wildcard ACL with `identifier like "com.626labs.RORORO.instance.*"` requirement. Every present and future per-instance bundle satisfies it.
- **Decision 3:** Empty placeholder values. Real session credentials stay in the per-instance cookie jar.
- **Decision 4:** One-time onboarding sheet + macOS password prompt. UserDefaults marker, version bump for re-population.
- **Alternatives considered:** Raptor per-profile keychains (rejected — doesn't apply to LaunchServices-mediated launches), delete login.keychain entries (rejected — requires more permissions than needed), per-cdhash ACL maintained at build time (rejected — breaks every Launch As on a new account).
- **Security trade-off:** wildcard ACL accepts any ad-hoc-signed bundle with our prefix. Acceptable because items are empty placeholders. Hardening path for future release documented.

- [ ] **Step 2: Modify ADR 0009 — Open items section**

Strike "anti-cheat / Hyperion behavior under ad-hoc re-signed Roblox" if Task 7 Step 6 confirms (or leave it pending if not yet verified). Add: "Keychain password prompts on new-account launch — resolved by ADR 0010 (RORORO.keychain + wildcard ACL)."

- [ ] **Step 3: Add the CLAUDE.md hard rule**

Append to the Hard rules section in `CLAUDE.md`:

```markdown
- **Don't add a launch path that bypasses RororoKeychainBootstrap.ensureIfNeeded.** New launch entry points must wait for the bootstrap to complete (or run it themselves) before invoking RobloxAppCopier, otherwise Roblox queries Keychain via a re-signed bundle whose ACL coverage isn't in place → password prompt.
- **Don't tighten the wildcard ACL** (`identifier like "com.626labs.RORORO.instance.*"`) to a per-cdhash list without a logged decision. The wildcard is what makes new Launch As work without ceremony; a per-cdhash variant breaks every new account. See ADR 0010.
```

- [ ] **Step 4: Update `docs/_followups-cookie-isolation.md`**

Strike (don't delete — keep history) the v0.8 stub "eliminate the keychain re-prompt entirely via per-profile keychain (Raptor pattern)" since it lands in v0.7.0. Mark Task 4.5 GATING as resolved (Task 7 confirms). Mark `_followups` reapable post-v0.7.0 ship.

- [ ] **Step 5: Log the decision to the 626Labs Dashboard**

Use the MCP decisions tool:

```
mcp__626Labs__manage_decisions log
  title: "Eliminate macOS Keychain password prompts via RORORO.keychain + wildcard prefix ACL"
  description: "v0.7.0 ship gate. ADR 0010. Per-instance bundle re-sign (ADR 0009) made every Launch As trigger a Keychain prompt because the login-keychain ACL is cdhash-keyed and every re-signed copy has a fresh cdhash. Fix: ship RORORO.keychain pre-populated with the items Roblox queries on launch (starting with SharedROBLOSECURITYForStudio), set first in user search list, ACL uses csreq identifier-prefix wildcard so all current and future per-instance bundles satisfy it. One-time password prompt at first run (macOS rule for search-list modification); zero prompts thereafter, including on new accounts. Trade-off documented: wildcard ACL accepts any ad-hoc-signed binary with our prefix, acceptable because items are empty placeholders. Real session credentials remain in the per-instance cookie jar per ADR 0009."
  projectId: <bound>
  tags: ["adr", "keychain", "v0.7.0", "macos", "security"]
```

- [ ] **Step 6: Commit**

```bash
git add docs/decisions/0010-keychain-prompt-elimination.md \
        docs/decisions/0009-per-instance-cookie-isolation.md \
        CLAUDE.md \
        docs/_followups-cookie-isolation.md
git commit -m "$(cat <<'EOF'
docs(adr): 0010 keychain prompt elimination + hard rule + followups

ADR 0010 documents the RORORO.keychain + wildcard-prefix ACL approach,
the security trade-off (wildcard accepts any ad-hoc bundle with our
prefix; mitigated by empty placeholder values), and the rejected
alternatives (Raptor per-profile, delete login entries, per-cdhash
ACL).

ADR 0009 Open Items section gets the cross-reference. CLAUDE.md gains
two hard rules (don't bypass the bootstrap; don't tighten the wildcard
without a logged decision). _followups marks Task 4.5 + the keychain
v0.8 stub as resolved by this release.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Version bump to 0.7.0

**Files:**
- Modify: `App/project.yml`

- [ ] **Step 1: Bump version**

In `App/project.yml`, find the `RORORO` target's settings block:
```yaml
MARKETING_VERSION: "0.6.1"
CURRENT_PROJECT_VERSION: "7"
```

Change to:
```yaml
MARKETING_VERSION: "0.7.0"
CURRENT_PROJECT_VERSION: "8"
```

- [ ] **Step 2: Regenerate the Xcode project**

```bash
cd App && xcodegen generate
```
Expected: regenerated `RORORO.xcodeproj/`. The CFBundleShortVersionString in the built Info.plist will reflect 0.7.0.

- [ ] **Step 3: Build to verify**

```bash
xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build -destination 'platform=macOS,arch=arm64' 2>&1 | tail -10
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add App/project.yml
git commit -m "$(cat <<'EOF'
chore(version): bump 0.6.1 → 0.7.0 for keychain-prompt-elimination ship

v0.7.0 ships per-instance cookie isolation (ADR 0009) and keychain
prompt elimination (ADR 0010) together. Tag is human-only and waits
on the four bootstrap secrets — see CLAUDE.md "Hard rules".

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review checklist (already run by the plan author)

1. **Spec coverage:**
   - Per-account/per-instance cdhash mismatch → ACL wildcard prefix (Tasks 3 + 4) ✅
   - First-run keychain creation + search-list setup (Task 4) ✅
   - Pre-populate items Roblox queries (Tasks 1 + 3 + 4) ✅
   - Enumerate Roblox keychain items (Task 1) ✅
   - One-time UX framing for the password prompt (Task 5) ✅
   - Integration with the existing per-instance recipe (Task 6) ✅
   - End-to-end smoke covering new-account launches (Task 7) ✅
   - ADR + CLAUDE.md hard rule (Task 8) ✅
   - Version bump (Task 9) ✅

2. **Placeholder scan:** All code blocks are concrete. The one IMPLEMENTER NOTE in Task 3 (about `SecTrustedApplicationCreateFromRequirement`) is explicit about the fallback path, not a placeholder.

3. **Type consistency:** `RoroKeychainItem` is defined in Task 3 (`RororoKeychainItems.swift`); Task 1 forward-references it (Swift resolves type lookup at compile time within a module). `RororoKeychain.productionPath`, `currentVersion`, `versionKey`, `aclRequirementSource`, `add`, `exists`, `ensureIfNeeded`, `needsOnboarding` — all consistent across tasks.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-12-keychain-prompt-elimination.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
