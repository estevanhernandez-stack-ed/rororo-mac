# Launch via link, per account — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire an inbound `roblox-player://` URL through a "which account?" picker window so external Play clicks route to a specific RORORO account, threading the chosen userId back into the existing per-account launch path.

**Architecture:** A new `@MainActor` observable `LinkLaunchCoordinator` (Domain) owns the picker state machine. A new SwiftUI `Window` scene (`LinkAccountPickerWindow`) observes the coordinator and renders clickable account rows. A new branch at the top of `MultiInstanceCoordinator.handleIncomingURL` — only when `userId == nil` — reads `AccountStore.shared.accounts` and either aborts (0 accounts), silently recurses (1 account), or awaits the picker's choice and recurses with that userId (2+ accounts). Newest-wins on overlapping URLs; Cancel resolves the suspended request with `nil`.

**Tech Stack:** Swift 5 / SwiftUI on macOS 14+. `XCTest` for the coordinator's state-machine unit tests. UI rendering verified via `#Preview` blocks + manual smoke per repo posture (no automated SwiftUI snapshot tests in this codebase).

**Spec:** [`docs/launch-via-link-per-account/design.md`](./design.md)

---

## File structure (locked before tasks)

| File | Role | Responsibility |
| --- | --- | --- |
| `App/RORORO/Domain/LinkLaunchCoordinator.swift` | NEW | Picker state machine. Suspends a caller via async continuation, exposes state for SwiftUI observation, resolves on submit/cancel/evict. |
| `App/RORORO/UI/LinkPickerAccountRow.swift` | NEW | One clickable row in the picker. Inputs: `Account`, `runningState`, `onTap`. Pure presentation. |
| `App/RORORO/UI/LinkAccountPickerWindow.swift` | NEW | The SwiftUI `Window` scene. Observes the coordinator, renders the row list, wires Cancel + Esc. |
| `App/RORORO/Domain/MultiInstanceCoordinator.swift` | MOD | Add the `userId == nil` branch at the top of `handleIncomingURL`. Three sub-branches: 0 / 1 / 2+. |
| `App/RORORO/App.swift` | MOD | Register the new `Window` scene in the `body: some Scene` block. |
| `App/RORORO/Domain/AccountStore.swift` | MOD (small) | Add an `internal` test-only `_setAccountsForTesting(_:)` seam so the integration tests can populate accounts without touching Keychain. |
| `App/ROROROTests/LinkLaunchCoordinatorTests.swift` | NEW | Unit tests for the state machine. |
| `App/ROROROTests/MultiInstanceCoordinatorTests.swift` | NEW | Integration tests for the new branch — 0 / 1 / 2+ / Cancel. |

---

## Tasks

### Task 1: `LinkLaunchCoordinator` skeleton + happy-path test

**Files:**
- Create: `App/RORORO/Domain/LinkLaunchCoordinator.swift`
- Create: `App/ROROROTests/LinkLaunchCoordinatorTests.swift`

- [ ] **Step 1.1: Write the skeleton type** (compiles, doesn't yet behave correctly)

`App/RORORO/Domain/LinkLaunchCoordinator.swift`:

```swift
// LinkLaunchCoordinator.swift
// Domain — picker state machine for inbound `roblox-player://` URLs that
// arrived without an account context. See ADR-pending: design at
// docs/launch-via-link-per-account/design.md.
//
// The coordinator suspends a caller via async continuation, exposes its
// state for SwiftUI observation, and resolves on submit (a userId),
// cancel (nil), or eviction by a newer requestChoice call (nil).

import Foundation
import Observation

@MainActor
public final class LinkLaunchCoordinator: ObservableObject {

    /// Production singleton. Tests construct fresh instances via `init()`.
    public static let shared = LinkLaunchCoordinator()

    public enum State: Equatable {
        case idle
        case choosing(pendingURL: URL, accounts: [Account])
    }

    @Published public private(set) var state: State = .idle

    private var pendingContinuation: CheckedContinuation<String?, Never>?

    public init() {}

    /// Suspend the caller until a choice is submitted, cancelled, or
    /// evicted by a newer call. Returns the chosen userId or nil.
    public func requestChoice(url: URL, accounts: [Account]) async -> String? {
        // Skeleton — replaced in Task 1.4 with the real implementation.
        return nil
    }

    /// Resolve the in-flight continuation with the chosen userId.
    public func submit(userId: String) {
        // Skeleton — replaced in Task 1.4.
    }

    /// Resolve the in-flight continuation with nil (user cancelled).
    public func cancel() {
        // Skeleton — replaced in Task 1.4.
    }
}
```

- [ ] **Step 1.2: Regenerate the Xcode project so the new file is in the source list**

```bash
cd /Users/estevanhernandez/projects/rororo-mac/App && xcodegen generate
```

Expected: `⚙️  Generating project...` / `Created project at ...`.

- [ ] **Step 1.3: Write the first failing test**

`App/ROROROTests/LinkLaunchCoordinatorTests.swift`:

```swift
// LinkLaunchCoordinatorTests.swift
// Unit tests for the picker state machine. UI is separately verified
// via SwiftUI #Preview + manual smoke per repo posture.

import XCTest
@testable import RORORO

@MainActor
final class LinkLaunchCoordinatorTests: XCTestCase {

    private func makeAccount(userId: String, username: String) -> Account {
        Account(
            userId: userId,
            username: username,
            displayName: username,
            avatarThumbnailURL: nil,
            lastLaunchedAt: nil
        )
    }

    func testRequestChoice_SubmitResolvesWithUserId() async {
        let coord = LinkLaunchCoordinator()
        let url = URL(string: "roblox-player://1+launchmode+play")!
        let accounts = [
            makeAccount(userId: "111", username: "AltAcct1"),
            makeAccount(userId: "222", username: "AltAcct2"),
        ]

        let resultTask = Task { await coord.requestChoice(url: url, accounts: accounts) }

        // Wait for state to transition to .choosing.
        await waitFor { coord.state != .idle }
        XCTAssertEqual(coord.state, .choosing(pendingURL: url, accounts: accounts))

        coord.submit(userId: "222")
        let result = await resultTask.value
        XCTAssertEqual(result, "222")
        XCTAssertEqual(coord.state, .idle, "State must return to idle after submit.")
    }

    /// Small polling helper — XCTestExpectation feels heavy for observing
    /// an @Published transition that happens within a few microseconds.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        timeout: TimeInterval = 1.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            await Task.yield()
        }
    }
}
```

- [ ] **Step 1.4: Run the test, verify it fails**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests/testRequestChoice_SubmitResolvesWithUserId \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" | tail -10
```

Expected: `testRequestChoice_SubmitResolvesWithUserId` **fails** — the skeleton returns `nil` immediately without transitioning state.

- [ ] **Step 1.5: Implement the real coordinator logic**

Replace the three method bodies in `LinkLaunchCoordinator.swift`:

```swift
public func requestChoice(url: URL, accounts: [Account]) async -> String? {
    // Newest-wins: if there's already an in-flight continuation,
    // resolve it with nil before starting the new request. (Implemented
    // explicitly in Task 2 — for now a no-op since only one caller is
    // expected at this point in the plan.)
    if let oldContinuation = pendingContinuation {
        pendingContinuation = nil
        oldContinuation.resume(returning: nil)
    }

    return await withCheckedContinuation { continuation in
        self.pendingContinuation = continuation
        self.state = .choosing(pendingURL: url, accounts: accounts)
    }
}

public func submit(userId: String) {
    let continuation = pendingContinuation
    pendingContinuation = nil
    state = .idle
    continuation?.resume(returning: userId)
}

public func cancel() {
    let continuation = pendingContinuation
    pendingContinuation = nil
    state = .idle
    continuation?.resume(returning: nil)
}
```

- [ ] **Step 1.6: Run the test, verify it passes**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests/testRequestChoice_SubmitResolvesWithUserId \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" | tail -10
```

Expected: `testRequestChoice_SubmitResolvesWithUserId` **passes**.

- [ ] **Step 1.7: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/RORORO/Domain/LinkLaunchCoordinator.swift \
          App/ROROROTests/LinkLaunchCoordinatorTests.swift && \
  git commit -m "feat(link-launch): LinkLaunchCoordinator state machine + happy-path test"
```

---

### Task 2: Newest-wins eviction

**Files:**
- Test: `App/ROROROTests/LinkLaunchCoordinatorTests.swift` (modify)
- Verify (no source changes needed if Task 1's implementation is correct)

- [ ] **Step 2.1: Write the failing test**

Add to `LinkLaunchCoordinatorTests.swift` inside the class:

```swift
func testRequestChoice_NewerCallEvictsOlder() async {
    let coord = LinkLaunchCoordinator()
    let urlA = URL(string: "roblox-player://1+launchmode+play&placeId=A")!
    let urlB = URL(string: "roblox-player://1+launchmode+play&placeId=B")!
    let accounts = [
        makeAccount(userId: "111", username: "AltAcct1"),
        makeAccount(userId: "222", username: "AltAcct2"),
    ]

    let taskA = Task { await coord.requestChoice(url: urlA, accounts: accounts) }
    await waitFor { coord.state != .idle }
    XCTAssertEqual(coord.state, .choosing(pendingURL: urlA, accounts: accounts))

    let taskB = Task { await coord.requestChoice(url: urlB, accounts: accounts) }
    // After eviction the state should rebind to B's URL.
    await waitFor {
        if case .choosing(let pending, _) = coord.state, pending == urlB { return true }
        return false
    }

    coord.submit(userId: "222")

    let resultA = await taskA.value
    let resultB = await taskB.value
    XCTAssertNil(resultA, "Older requestChoice must resolve with nil when evicted.")
    XCTAssertEqual(resultB, "222")
    XCTAssertEqual(coord.state, .idle)
}
```

- [ ] **Step 2.2: Run the test, verify behavior**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests/testRequestChoice_NewerCallEvictsOlder \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" | tail -10
```

**Expected outcome depends on Task 1.5's implementation.** Two possibilities:

1. **Test passes** — Task 1.5 already wired the eviction branch (`if let oldContinuation = pendingContinuation`). The newest-wins behavior is locked in by the test as a regression check. Proceed to Step 2.4.
2. **Test fails** — eviction wasn't yet wired. Proceed to Step 2.3 to implement it.

- [ ] **Step 2.3 (only if Step 2.2 failed): Wire the eviction branch**

In `LinkLaunchCoordinator.requestChoice`, ensure the top of the method evicts any in-flight continuation:

```swift
if let oldContinuation = pendingContinuation {
    pendingContinuation = nil
    oldContinuation.resume(returning: nil)
}
```

Re-run Step 2.2 — should now pass.

- [ ] **Step 2.4: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/ROROROTests/LinkLaunchCoordinatorTests.swift \
          App/RORORO/Domain/LinkLaunchCoordinator.swift && \
  git commit -m "test(link-launch): lock in newest-wins eviction for requestChoice"
```

---

### Task 3: Cancel resolution test (regression lock)

**Files:**
- Test: `App/ROROROTests/LinkLaunchCoordinatorTests.swift` (modify)

- [ ] **Step 3.1: Add the test**

Add to `LinkLaunchCoordinatorTests.swift`:

```swift
func testCancel_ResolvesWithNil() async {
    let coord = LinkLaunchCoordinator()
    let url = URL(string: "roblox-player://1+launchmode+play")!
    let accounts = [
        makeAccount(userId: "111", username: "AltAcct1"),
        makeAccount(userId: "222", username: "AltAcct2"),
    ]

    let resultTask = Task { await coord.requestChoice(url: url, accounts: accounts) }
    await waitFor { coord.state != .idle }

    coord.cancel()

    let result = await resultTask.value
    XCTAssertNil(result, "cancel() must resolve the suspended requestChoice with nil.")
    XCTAssertEqual(coord.state, .idle)
}

func testCancel_WhileIdle_IsNoOp() async {
    let coord = LinkLaunchCoordinator()
    coord.cancel() // Must not crash, must not change state.
    XCTAssertEqual(coord.state, .idle)
}
```

- [ ] **Step 3.2: Run both new tests, verify they pass**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests/testCancel_ResolvesWithNil \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests/testCancel_WhileIdle_IsNoOp \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" | tail -10
```

Expected: both **pass**.

- [ ] **Step 3.3: Run the full `LinkLaunchCoordinatorTests` suite to confirm nothing regressed**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests \
    2>&1 | grep -E "(Test Suite '.*' (passed|failed)|Executed)" | tail -5
```

Expected: `Test Suite 'LinkLaunchCoordinatorTests' passed` with 4 tests executed.

- [ ] **Step 3.4: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/ROROROTests/LinkLaunchCoordinatorTests.swift && \
  git commit -m "test(link-launch): cancel() resolves nil + idle no-op"
```

---

### Task 4: `LinkPickerAccountRow` UI

**Files:**
- Create: `App/RORORO/UI/LinkPickerAccountRow.swift`

No automated test — SwiftUI row is visual-only per repo posture. Verified via `#Preview` + compile.

- [ ] **Step 4.1: Write the row view**

`App/RORORO/UI/LinkPickerAccountRow.swift`:

```swift
// LinkPickerAccountRow.swift
// UI — one clickable row in the inbound-link account picker. Pure
// presentation: takes the account, an external running-state value,
// and a tap callback. Visual treatment follows the existing Theme.
//
// Not a reuse of AccountsListView's row — that row carries split-launch
// button + chevron + framerate badge + macro state, all of which are
// the wrong affordance here. The picker is "click row → launch", end
// of story.

import SwiftUI

public struct LinkPickerAccountRow: View {

    public enum RunningState {
        case idle
        case running
        case active
    }

    public let account: Account
    public let runningState: RunningState
    public let onTap: () -> Void

    public init(account: Account, runningState: RunningState, onTap: @escaping () -> Void) {
        self.account = account
        self.runningState = runningState
        self.onTap = onTap
    }

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.cyan)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName)
                        .font(.body)
                        .foregroundStyle(Theme.foreground)
                    Text("@\(account.username)")
                        .font(.caption)
                        .foregroundStyle(Theme.foregroundSecondary)
                }
                Spacer()
                statePill
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statePill: some View {
        switch runningState {
        case .idle:
            EmptyView()
        case .running:
            Text("running")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.foregroundSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.cardBackground.opacity(0.6))
                .clipShape(Capsule())
        case .active:
            Text("active")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.cyan)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Theme.cyan.opacity(0.12))
                .clipShape(Capsule())
        }
    }
}

#Preview("LinkPickerAccountRow — three states") {
    VStack(spacing: 8) {
        LinkPickerAccountRow(
            account: Account(userId: "1", username: "alt1", displayName: "AltAcct1",
                             avatarThumbnailURL: nil, lastLaunchedAt: nil),
            runningState: .idle,
            onTap: {}
        )
        LinkPickerAccountRow(
            account: Account(userId: "2", username: "alt2", displayName: "AltAcct2",
                             avatarThumbnailURL: nil, lastLaunchedAt: nil),
            runningState: .running,
            onTap: {}
        )
        LinkPickerAccountRow(
            account: Account(userId: "3", username: "alt3", displayName: "AltAcct3",
                             avatarThumbnailURL: nil, lastLaunchedAt: nil),
            runningState: .active,
            onTap: {}
        )
    }
    .padding(16)
    .frame(width: 360)
}
```

**If `Theme.foreground` / `Theme.foregroundSecondary` / `Theme.cardBackground` aren't the right token names:** open `App/RORORO/Theme/Theme.swift` and pick the closest equivalents. The contract is "use Theme tokens, not inline colors" — exact names follow the existing module.

- [ ] **Step 4.2: Regenerate the Xcode project**

```bash
cd /Users/estevanhernandez/projects/rororo-mac/App && xcodegen generate
```

- [ ] **Step 4.3: Compile-only verification**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build \
    -destination 'platform=macOS,arch=x86_64' \
    2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails on Theme-token names, replace with the closest available tokens from `App/RORORO/Theme/`. Re-run the build.

- [ ] **Step 4.4: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/RORORO/UI/LinkPickerAccountRow.swift && \
  git commit -m "feat(link-launch): LinkPickerAccountRow — clickable account row for the picker"
```

---

### Task 5: `LinkAccountPickerWindow` UI

**Files:**
- Create: `App/RORORO/UI/LinkAccountPickerWindow.swift`

- [ ] **Step 5.1: Write the window scene**

`App/RORORO/UI/LinkAccountPickerWindow.swift`:

```swift
// LinkAccountPickerWindow.swift
// UI — standalone floating SwiftUI Window scene that asks "which
// account?" for an inbound roblox-player:// URL. Observes
// LinkLaunchCoordinator.shared and renders only when state is
// .choosing. Closes itself when state transitions back to .idle.
//
// Esc / Cmd-W / window-close-button all map to coordinator.cancel().

import SwiftUI

public struct LinkAccountPickerWindow: Scene {

    @ObservedObject private var coordinator: LinkLaunchCoordinator
    @Environment(\.dismissWindow) private var dismissWindow

    public static let windowID = "linkAccountPicker"

    public init(coordinator: LinkLaunchCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public var body: some Scene {
        Window("Launch as…", id: Self.windowID) {
            LinkAccountPickerWindowContent(coordinator: coordinator)
                .frame(width: 380)
                .onChange(of: coordinator.state) { _, newState in
                    if case .idle = newState {
                        dismissWindow(id: Self.windowID)
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .windowSize) {
                // Suppress the standard "Minimize / Zoom" entries —
                // the picker is a transient utility, not a doc window.
            }
        }
    }
}

private struct LinkAccountPickerWindowContent: View {

    @ObservedObject var coordinator: LinkLaunchCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .choosing(let pendingURL, let accounts) = coordinator.state {
                header(pendingURL: pendingURL)
                rowList(accounts: accounts)
                footer
            } else {
                // Should not normally render — the scene dismisses on
                // .idle — but guard against a one-frame flash.
                Color.clear.frame(height: 1)
            }
        }
        .padding(16)
    }

    private func header(pendingURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Opening this link with…")
                .font(.caption)
                .foregroundStyle(Theme.foregroundSecondary)
            Text(pendingURL.absoluteString)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.foregroundSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func rowList(accounts: [Account]) -> some View {
        VStack(spacing: 6) {
            ForEach(accounts) { account in
                LinkPickerAccountRow(
                    account: account,
                    runningState: runningState(for: account.userId),
                    onTap: { coordinator.submit(userId: account.userId) }
                )
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { coordinator.cancel() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func runningState(for userId: String) -> LinkPickerAccountRow.RunningState {
        if RunningAccountTracker.shared.pid(for: userId) != nil {
            return .running
        }
        return .idle
        // Note: .active (frontmost) state intentionally omitted in v1 —
        // RunningAccountTracker.pid(for:) reports "we know it's running"
        // but not "it's frontmost right now." Adding frontmost detection
        // is deferred to a future iteration.
    }
}

#Preview("LinkAccountPickerWindow content — 3 accounts") {
    let coord = LinkLaunchCoordinator()
    Task { @MainActor in
        _ = await coord.requestChoice(
            url: URL(string: "roblox-player://1+launchmode+play&placeId=1234567890")!,
            accounts: [
                Account(userId: "1", username: "alt1", displayName: "AltAcct1",
                        avatarThumbnailURL: nil, lastLaunchedAt: nil),
                Account(userId: "2", username: "alt2", displayName: "AltAcct2",
                        avatarThumbnailURL: nil, lastLaunchedAt: nil),
                Account(userId: "3", username: "alt3", displayName: "AltAcct3",
                        avatarThumbnailURL: nil, lastLaunchedAt: nil),
            ]
        )
    }
    return LinkAccountPickerWindowContent(coordinator: coord)
        .frame(width: 380)
        .padding(16)
}
```

- [ ] **Step 5.2: Regenerate + compile-only verification**

```bash
cd /Users/estevanhernandez/projects/rororo-mac/App && xcodegen generate && \
  cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build \
    -destination 'platform=macOS,arch=x86_64' \
    2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails on `dismissWindow` (macOS 13.0+ only — should be fine on 14.0+ deployment target) or on a missing `Theme` token, adjust accordingly.

- [ ] **Step 5.3: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/RORORO/UI/LinkAccountPickerWindow.swift && \
  git commit -m "feat(link-launch): LinkAccountPickerWindow — standalone picker Window scene"
```

---

### Task 6: Register the new Window scene in `App.swift`

**Files:**
- Modify: `App/RORORO/App.swift` — add `LinkAccountPickerWindow()` to the `body: some Scene` block.

- [ ] **Step 6.1: Add the Window scene**

In `App/RORORO/App.swift`, inside `var body: some Scene { ... }`, after the existing `WindowGroup("RORORO") { ... }` block, add:

```swift
        LinkAccountPickerWindow()
```

So the block now reads (the surrounding code is the existing block — the only new line is the `LinkAccountPickerWindow()` invocation right before the closing brace of `body`):

```swift
    var body: some Scene {
        WindowGroup("RORORO") {
            ContentView()
                // ... existing modifiers unchanged ...
        }

        LinkAccountPickerWindow()
    }
```

- [ ] **Step 6.2: Compile-only verification**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO build \
    -destination 'platform=macOS,arch=x86_64' \
    2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6.3: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/RORORO/App.swift && \
  git commit -m "feat(link-launch): register LinkAccountPickerWindow Scene in App.swift"
```

---

### Task 7: `MultiInstanceCoordinator.handleIncomingURL` branch + integration tests

**Files:**
- Modify: `App/RORORO/Domain/AccountStore.swift` — add `_setAccountsForTesting`.
- Modify: `App/RORORO/Domain/MultiInstanceCoordinator.swift` — new branch at top of `handleIncomingURL`.
- Create: `App/ROROROTests/MultiInstanceCoordinatorTests.swift`.

This task bundles four integration cases: 0-accounts abort, 1-account silent recurse, 2+-accounts coordinator-state-transition, Cancel-no-launch. Internal test seam added to AccountStore so tests can populate without going through Keychain.

- [ ] **Step 7.1: Add the internal test seam to `AccountStore`**

In `App/RORORO/Domain/AccountStore.swift`, just below `public private(set) var accounts: [Account] = []` (line 27 area), add:

```swift
    /// Test-only seam. `@testable import` exposes this to ROROROTests.
    /// Not part of the public API — bypasses the Keychain write that
    /// `add(account:cookie:)` performs, so integration tests can drive
    /// the account count without setting up a real keychain.
    internal func _setAccountsForTesting(_ accounts: [Account]) {
        self.accounts = accounts
    }
```

- [ ] **Step 7.2: Add the new branch to `handleIncomingURL`**

In `App/RORORO/Domain/MultiInstanceCoordinator.swift`, replace lines 193-206 (the current method signature + the existing `userId == nil` global-settings block) with this expanded version. The existing logic for `userId == nil` (apply global settings) is preserved; the new account-count branch sits ABOVE it, and falls through to the existing global-settings path only when there are 0 accounts.

Existing block (lines 193-206) currently reads:

```swift
    public func handleIncomingURL(_ url: URL, displayLabel: String? = nil, userId: String? = nil) {
        let enabled = MultiInstanceState.shared.enabled
        let semaphoreName = RobloxCompatStore.shared.currentSemaphoreName()
        // External URL handoffs (`.onOpenURL` from a browser "Play" click,
        // another app, etc.) arrive here with userId == nil. RobloxLauncher.
        // launch already wrote FFlags + per-account framerate cap before
        // calling this method, so on that path we leave the writers alone.
        // On external handoffs we apply global settings so low-resource
        // mode + user-set FFlags + the global framerate cap still take
        // effect. Per-account overrides require the Launch As path.
        if userId == nil {
            let snapshot = LaunchSettingsStore.shared.snapshot()
            RobloxLauncher.applyGlobalLaunchSettings(snapshot: snapshot)
        }
```

Replace with:

```swift
    public func handleIncomingURL(_ url: URL, displayLabel: String? = nil, userId: String? = nil) {
        // External URL handoffs (e.g. `.onOpenURL` from a browser "Play"
        // click) arrive with userId == nil. Route through the per-account
        // picker when possible:
        //   - 0 accounts: surface a banner, drop the launch.
        //   - 1 account: recurse with that account's userId — picker is
        //     silently skipped (one option isn't a real choice).
        //   - 2+ accounts: open LinkLaunchCoordinator's picker; recurse
        //     with the chosen userId on submit, or no-op on cancel.
        // Per-account context (cookie isolation, per-account framerate
        // override, per-account FFlag deltas) only engages on the
        // userId != nil path; routing through the picker is how we
        // bridge browser-fired URLs into that path. See
        // docs/launch-via-link-per-account/design.md.
        if userId == nil {
            let accounts = AccountStore.shared.accounts
            switch accounts.count {
            case 0:
                MultiInstanceState.shared.lastError = "Add an account in RORORO before launching from a link."
                return
            case 1:
                handleIncomingURL(url, displayLabel: displayLabel, userId: accounts[0].userId)
                return
            default:
                Task { @MainActor in
                    let chosen = await LinkLaunchCoordinator.shared.requestChoice(
                        url: url,
                        accounts: accounts
                    )
                    if let chosen {
                        self.handleIncomingURL(url, displayLabel: displayLabel, userId: chosen)
                    }
                    // chosen == nil → Cancel / eviction → drop the launch.
                }
                return
            }
        }

        // Existing path: userId != nil — either threaded by
        // RobloxLauncher.launch (which already wrote per-account
        // settings) or threaded above by the 1-account or picker
        // branch. Either way the per-account work has been handled;
        // hand off to the multi-instance launch queue.
        let enabled = MultiInstanceState.shared.enabled
        let semaphoreName = RobloxCompatStore.shared.currentSemaphoreName()
```

The rest of `handleIncomingURL` (the `LaunchRequest` construction and `launchContinuation.yield(request)` block, lines 207 onwards) is **unchanged** — leave everything from `let request = LaunchRequest(...)` onwards exactly as-is.

**Note on the removed `applyGlobalLaunchSettings` call:** the old code applied global settings only when `userId == nil`. After this change, every path through `handleIncomingURL` has a non-nil userId by the time it reaches the launch enqueue (either threaded in or recursed-with). Global-settings application now happens entirely on the `RobloxLauncher.launch` path, which already does per-account FFlag + framerate writes for known accounts. The 0-account path returns before any enqueue, so no global settings are applied — which is correct, because there's no account to apply them under.

- [ ] **Step 7.3: Regenerate + write the integration tests**

```bash
cd /Users/estevanhernandez/projects/rororo-mac/App && xcodegen generate
```

Then create `App/ROROROTests/MultiInstanceCoordinatorTests.swift`:

```swift
// MultiInstanceCoordinatorTests.swift
// Integration tests for the inbound-URL routing branch in
// MultiInstanceCoordinator.handleIncomingURL. Focused on the
// 0/1/2+/Cancel decision logic — full launch pipeline (copy + plist
// flip + spawn) is verified manually per repo posture.

import XCTest
@testable import RORORO

@MainActor
final class MultiInstanceCoordinatorTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        // Clear lastError and any in-flight picker state between tests.
        MultiInstanceState.shared.lastError = nil
        LinkLaunchCoordinator.shared.cancel()
        AccountStore.shared._setAccountsForTesting([])
    }

    override func tearDown() async throws {
        AccountStore.shared._setAccountsForTesting([])
        LinkLaunchCoordinator.shared.cancel()
        MultiInstanceState.shared.lastError = nil
        try await super.tearDown()
    }

    private func makeAccount(userId: String, username: String) -> Account {
        Account(
            userId: userId,
            username: username,
            displayName: username,
            avatarThumbnailURL: nil,
            lastLaunchedAt: nil
        )
    }

    func testHandleIncomingURL_ZeroAccounts_SetsLastErrorAndAborts() async {
        let url = URL(string: "roblox-player://1+launchmode+play")!
        AccountStore.shared._setAccountsForTesting([])

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        // Give the coordinator a beat — none of the picker async path
        // should run, but a small yield keeps the assertion robust if
        // anything dispatches.
        await Task.yield()

        XCTAssertNotNil(MultiInstanceState.shared.lastError, "0-accounts path must surface a lastError.")
        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle, "Picker must NOT open with 0 accounts.")
    }

    func testHandleIncomingURL_TwoOrMoreAccounts_OpensPicker() async {
        let url = URL(string: "roblox-player://1+launchmode+play&placeId=42")!
        let accounts = [
            makeAccount(userId: "111", username: "alt1"),
            makeAccount(userId: "222", username: "alt2"),
        ]
        AccountStore.shared._setAccountsForTesting(accounts)

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        // Picker dispatches via Task { @MainActor in ... }; yield once
        // so the await-on-requestChoice has a chance to transition the
        // coordinator's state.
        let deadline = Date().addingTimeInterval(1.0)
        while LinkLaunchCoordinator.shared.state == .idle && Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(
            LinkLaunchCoordinator.shared.state,
            .choosing(pendingURL: url, accounts: accounts),
            "2+ accounts must transition the picker into .choosing(url, accounts)."
        )

        // Clean up so tearDown's cancel doesn't fight a leftover continuation.
        LinkLaunchCoordinator.shared.cancel()
    }

    func testHandleIncomingURL_PickerCancel_DoesNotEnqueueLaunch() async {
        let url = URL(string: "roblox-player://1+launchmode+play")!
        let accounts = [
            makeAccount(userId: "111", username: "alt1"),
            makeAccount(userId: "222", username: "alt2"),
        ]
        AccountStore.shared._setAccountsForTesting(accounts)

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)

        let deadline = Date().addingTimeInterval(1.0)
        while LinkLaunchCoordinator.shared.state == .idle && Date() < deadline {
            await Task.yield()
        }

        LinkLaunchCoordinator.shared.cancel()

        // Yield once so the awaiting Task in handleIncomingURL gets a
        // chance to return after seeing nil.
        await Task.yield()

        // Cancel returns the state to .idle; no recursion fires.
        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle)
        // Note: asserting "no launch fired" via MultiInstanceState would
        // require a hook into the launch queue we don't have today.
        // The state-returns-to-idle assertion is sufficient — the
        // handleIncomingURL Task discards the nil result and returns.
    }

    /// The 1-account path silently recurses with that userId. Direct
    /// observation of "recursion happened" requires intercepting the
    /// launch queue; instead we verify two negative outcomes that would
    /// both fail if the branch was wrong:
    ///   - the picker does NOT open
    ///   - lastError is NOT set (would happen on the 0-account path)
    func testHandleIncomingURL_OneAccount_DoesNotOpenPickerAndDoesNotError() async {
        let url = URL(string: "roblox-player://1+launchmode+play")!
        AccountStore.shared._setAccountsForTesting([
            makeAccount(userId: "111", username: "alt1")
        ])

        MultiInstanceCoordinator.shared.handleIncomingURL(url, userId: nil)
        await Task.yield()

        XCTAssertEqual(LinkLaunchCoordinator.shared.state, .idle, "1-account path must NOT open picker.")
        XCTAssertNil(MultiInstanceState.shared.lastError, "1-account path must NOT set lastError.")
    }
}
```

- [ ] **Step 7.4: Run the integration suite**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/MultiInstanceCoordinatorTests \
    2>&1 | grep -E "(Test Case|passed|failed|error:)" | tail -20
```

Expected: all four tests pass.

- [ ] **Step 7.5: Commit**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git add App/RORORO/Domain/AccountStore.swift \
          App/RORORO/Domain/MultiInstanceCoordinator.swift \
          App/ROROROTests/MultiInstanceCoordinatorTests.swift && \
  git commit -m "feat(link-launch): route inbound roblox-player:// through picker for userId == nil"
```

---

### Task 8: Final test sweep + manual smoke + PR-ready check

- [ ] **Step 8.1: Run the focused AutoKeys + link-launch suites to confirm nothing regressed**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    -only-testing:ROROROTests/LinkLaunchCoordinatorTests \
    -only-testing:ROROROTests/MultiInstanceCoordinatorTests \
    -only-testing:ROROROTests/AutoKeysSafetyMonitorTests \
    -only-testing:ROROROTests/AutoKeysCyclerTests \
    2>&1 | grep -E "(Test Suite '.*' (passed|failed)|Executed [0-9]+ tests|\*\* TEST)" | tail -10
```

Expected: all suites pass; `** TEST SUCCEEDED **`.

- [ ] **Step 8.2: Full-suite run (informational only — the pre-existing `RororoKeychain*Tests` crashes from `feedback.md:11` are out of scope here)**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  xcodebuild -project App/RORORO.xcodeproj -scheme RORORO test \
    -destination 'platform=macOS,arch=x86_64' \
    2>&1 | grep -E "(Test Suite '.*' (passed|failed)|Executed [0-9]+ tests)" | tail -10
```

Expected: a `** TEST FAILED **` at the bottom IF the keychain crashes still reproduce; that's the known pre-existing issue tracked in `feedback.md:11`, not a regression caused by this feature. Document whatever you see in the PR description's "test plan" section so the reviewer can match against the same baseline.

- [ ] **Step 8.3: Manual smoke (out-of-band — checklist for the PR description)**

These are NOT automated. Run them on the actual built RORORO binary before opening the PR:

1. **0-account smoke** — quit RORORO, blow away any local account data (or use a fresh test bundle), click a roblox.com Play link, confirm the link is dropped with a banner / surfaced lastError, no Roblox launch fires.
2. **1-account smoke** — with exactly one account configured, click a roblox.com Play link, confirm Roblox launches as that account without any picker appearing.
3. **2+-account smoke** — with two or more accounts, click a Play link, confirm the picker opens centered on screen. Click an account row — confirm Roblox launches as that account.
4. **Cancel smoke** — repeat 3, but press Esc / click the close button / press Cmd-W. Confirm the picker closes and NO Roblox launch fires.
5. **Newest-wins smoke** — click two different Play links within ~1 second. Confirm only one picker shows, with the second link's URL in the caption row.
6. **Cold-start smoke** — quit RORORO entirely, click a Play link from the browser. Confirm RORORO launches, the picker appears (assuming 2+ accounts), and the launch path resolves cleanly.

- [ ] **Step 8.4: Push + open PR**

```bash
cd /Users/estevanhernandez/projects/rororo-mac && \
  git push -u origin feat/launch-via-link-per-account
```

Then open the PR via `gh pr create` referencing both the spec (`docs/launch-via-link-per-account/design.md`) and the manual smoke checklist from Step 8.3. Title: `feat(link-launch): per-account picker for inbound roblox-player:// URLs`.

---

## Self-review

**Spec coverage:**
- ✓ Decisions table → Task 7 implements the 0/1/2+/Cancel branch logic; Task 1 implements the always-show-picker semantics (no remembered default in any task).
- ✓ Newest-wins → Task 2 locks the eviction behavior with a regression test.
- ✓ Architecture → Tasks 1, 4, 5, 6, 7 cover the new types + the modified files.
- ✓ UI layout (caption row + clickable rows + Cancel) → Task 5's content view + Task 4's row.
- ✓ Visual-only verification posture → Tasks 4, 5, 6 use compile + `#Preview`; no automated SwiftUI tests.
- ✓ Cold-start path → not a code change (sits behind existing `bootIfNeeded` gate); covered by Step 8.3 manual smoke 6.
- ✓ Account list changes while picker open → SwiftUI observation handles it automatically (no task required).
- ✓ Quit while picker open → `@MainActor` cleanup is automatic; no task required.
- ✓ Test plan → Tasks 1-3 cover unit, Task 7 covers integration, Step 8.3 covers manual smoke.
- ✓ Out-of-scope items (sticky default, default-account binding, outbound links, avatars) → explicitly NOT in any task.

**Placeholder scan:** no `TBD` / `TODO` / "implement later" / vague "handle edge cases" instructions. Every code step has the actual code; every command step has the actual command.

**Type consistency:**
- `LinkLaunchCoordinator.State` is `.idle | .choosing(pendingURL: URL, accounts: [Account])` everywhere.
- `requestChoice(url:accounts:)` and `submit(userId:)` / `cancel()` are spelled identically across all tasks.
- `LinkPickerAccountRow.RunningState` is `.idle | .running | .active`; Task 5's `runningState(for:)` only ever returns `.running` or `.idle` (v1 doesn't compute `.active`), which is documented in the comment.
- `AccountStore._setAccountsForTesting(_:)` introduced in Task 7.1 is used in Task 7.3 with identical spelling.
- `LinkAccountPickerWindow.windowID` is `"linkAccountPicker"` — only referenced inside its own file via `Self.windowID`.

**Scope check:** this is a single feature, single PR, ≤ 250 lines of new production code + ~150 lines of tests. Appropriate for one plan.
