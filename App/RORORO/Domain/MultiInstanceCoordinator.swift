// MultiInstanceCoordinator.swift
// Domain — the load-bearing orchestrator. Owns the multi-instance recipe:
//
//   1. Claim `roblox-player://` (boot, async).
//   2. On incoming `roblox-player:` URL:
//      a. Copy /Applications/Roblox.app → instances/<uuid>.app + flip plist.
//      b. sem_unlink("/RobloxPlayerUniq").
//      c. NSWorkspace.shared.open(url, withApplicationAt: copy).
//      d. sem_unlink again (race buffer — covers the case where another
//         process recreates the semaphore between steps b and c).
//   3. On quit, restore the previous URL scheme handler.
//
// Why this shape:
//   - Singleton mirrors macRo's `Engine.shared` pattern. One coordinator
//     per app lifetime; no accidental second instances.
//   - bootIfNeeded() runs on @MainActor (called from .onAppear) and is
//     idempotent. Subsequent calls no-op.
//   - handleIncomingURL() is @MainActor-entered (from .onOpenURL) but
//     dispatches the heavy I/O via `Task.detached(priority: .userInitiated)`
//     so the file copy + Info.plist edit don't block UI.
//   - State updates after the launch hop back to MainActor.run.
//
// Important: handleIncomingURL is best-effort per launch. A failed copy /
// failed plist write / failed `open` does NOT throw to the caller — the
// SwiftUI .onOpenURL closure has nowhere to surface errors. We update
// MultiInstanceState.shared.lastError and let the UI render it.

import AppKit
import Foundation
import Observation

@MainActor
public final class MultiInstanceCoordinator {

    public static let shared = MultiInstanceCoordinator()
    private init() {}

    private var didBoot = false

    /// Internal launch-queue plumbing. EVERY incoming URL goes through
    /// the AsyncStream worker so that the 600MB Roblox.app copy step
    /// (RobloxAppCopier.copyAppForInstance) doesn't run concurrently
    /// across multiple launches. Two simultaneous copies thrash disk
    /// I/O; the user's manual workaround was waiting one-at-a-time.
    /// The queue makes that workaround automatic — and it's also the
    /// foundation for "Launch group" (Slope B1), which enqueues N
    /// requests and lets the worker process them serially.
    ///
    /// Buffer between launches: after each `performLaunch` returns,
    /// the worker waits for a NEW Roblox process to appear in
    /// `NSWorkspace.runningApplications` (or 3s grace, whichever
    /// first), then a small post-detection grace so the new engine
    /// has a moment to read GlobalBasicSettings_<N>.xml before the
    /// next launch can overwrite it (relevant for per-account
    /// framerate divergence per ADR 0002).
    private struct LaunchRequest: Sendable {
        let url: URL
        let enabled: Bool
        let semaphoreName: String
        /// Account display label threaded through to RobloxAppCopier so
        /// each per-launch bundle copy is named after the launching
        /// account. Dock then shows e.g. "Estevan" instead of "Roblox"
        /// (or worse, the UUID basename) when multiple instances are
        /// running. nil for non-RORORO-driven launches (e.g. URL
        /// handler dispatched from outside the app).
        let displayLabel: String?
    }
    private var launchContinuation: AsyncStream<LaunchRequest>.Continuation?
    private var launchWorkerTask: Task<Void, Never>?

    /// One-time bootstrap. Run from `.onAppear` on the root view. Safe to
    /// call multiple times — second call is a no-op. Performs:
    ///   - Stale-instance cleanup (off-main).
    ///   - URL scheme claim (async).
    ///   - willTerminate observer registration (for restore-on-quit).
    ///   - Serial launch worker boot (drains the launch queue).
    public func bootIfNeeded() {
        guard !didBoot else { return }
        didBoot = true

        // Off-main background cleanup. Worst case it fails silently and the
        // user has stale .app copies until next boot — non-fatal.
        Task.detached(priority: .background) {
            try? RobloxAppCopier.cleanupStaleInstances()
        }

        // Boot the serial launch worker. Single consumer over an
        // AsyncStream — every handleIncomingURL yields a request; the
        // worker processes one at a time and waits for the spawned
        // Roblox to actually finish launching (window drawn, app
        // settled) before draining the next request. Just "process
        // appeared in runningApplications" isn't enough — caught at
        // smoke 2026-05-08 where the first rapid-fire launch's window
        // appeared then closed because the next launch's work hit
        // mid-startup.
        let (stream, continuation) = AsyncStream<LaunchRequest>.makeStream(bufferingPolicy: .unbounded)
        self.launchContinuation = continuation
        self.launchWorkerTask = Task.detached(priority: .userInitiated) {
            for await request in stream {
                let baseline = Self.runningRobloxPIDs()
                await Self.performLaunch(
                    request.url,
                    enabled: request.enabled,
                    semaphoreName: request.semaphoreName,
                    displayLabel: request.displayLabel
                )
                await Self.waitForLaunchToSettle(baseline: baseline)
            }
        }

        // Refresh the remote compat config (semaphore name, known-good
        // Roblox version, etc). Best-effort — a network failure leaves
        // us on the cached value or hardcoded fallback.
        Task { @MainActor in
            await RobloxCompatStore.shared.refresh()
        }

        // Async claim. Surface failures to the UI; don't crash the app.
        Task { @MainActor in
            do {
                try await URLSchemeHandler.shared.claim()
            } catch {
                MultiInstanceState.shared.lastError =
                    "Failed to claim roblox-player URL scheme: \(error.localizedDescription)"
            }
        }

        // willTerminate hook. Fires synchronously from AppKit's quit path;
        // we kick off an async restore that may not complete before the
        // process exits — UserDefaults still holds the previous handler so
        // next boot can re-restore (see URLSchemeHandler.restore).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Roblox-process-termination observer. When the last Roblox
        // instance exits, clean up the FFlag file we wrote into the
        // bundle (ClientAppSettings.json). NOT the AppleBlox setTimeout
        // pattern — that's a Heisenbug on cold starts (see ADR 0001).
        // Observing on NSWorkspace's notification center because that's
        // where app-lifecycle notifications fire; the global default
        // center doesn't carry these.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleAppDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    /// Route an incoming `roblox-player:` URL through the multi-instance
    /// recipe. Called from `.onOpenURL` (which has no account context)
    /// or from `RobloxLauncher.launch` (which passes the account's
    /// display name via `displayLabel` so the per-launch bundle copy
    /// can be named after the player). Non-throwing — errors land on
    /// `MultiInstanceState.shared.lastError`. Yields the request to
    /// the serial launch worker so simultaneous calls don't race the
    /// 600MB app-copy step.
    public func handleIncomingURL(_ url: URL, displayLabel: String? = nil) {
        let enabled = MultiInstanceState.shared.enabled
        let semaphoreName = RobloxCompatStore.shared.currentSemaphoreName()
        let request = LaunchRequest(
            url: url,
            enabled: enabled,
            semaphoreName: semaphoreName,
            displayLabel: displayLabel
        )
        if let launchContinuation {
            launchContinuation.yield(request)
        } else {
            // bootIfNeeded hasn't run yet — fall back to the pre-queue
            // direct dispatch so we never silently drop a launch. Should
            // never happen in production (.onAppear runs bootIfNeeded
            // before any URL routing) but keeps the interface honest.
            Task.detached(priority: .userInitiated) {
                await Self.performLaunch(url, enabled: enabled, semaphoreName: semaphoreName, displayLabel: displayLabel)
            }
        }
    }

    /// Manually re-trigger URL-scheme restore (used by Settings "Reset
    /// system handler" button — Phase 5).
    public func shutDown() async {
        await URLSchemeHandler.shared.restore()
    }

    @objc nonisolated private func handleWillTerminate(_ note: Notification) {
        // Synchronous fallback for the FFlag-cleanup path: if RORORO
        // quits while no Roblox is running, scrub the bundle write
        // before the process exits. The async restore below races the
        // quit deadline; cleanup is fast (single file remove) and runs
        // synchronously to make sure it completes.
        if !Self.anyRobloxRunning() {
            try? ClientSettingsWriter.cleanup()
        }
        Task { @MainActor in
            await URLSchemeHandler.shared.restore()
        }
    }

    @objc nonisolated private func handleAppDidTerminate(_ note: Notification) {
        // Cheap filter: any termination event triggers a "is Roblox
        // still running" poll. Notification volume is low (one per
        // app quit, app-side); the poll is in-process and fast.
        guard !Self.anyRobloxRunning() else { return }
        // No Roblox left — scrub the bundle write off the main thread
        // so we don't tax NSWorkspace's notification thread.
        Task.detached(priority: .background) {
            try? ClientSettingsWriter.cleanup()
        }
    }

    nonisolated private static func anyRobloxRunning() -> Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier?.hasPrefix("com.roblox") == true }
    }

    /// PIDs of currently-running Roblox instances. Used as the baseline
    /// before a launch so the queue's settle-wait can identify the NEW
    /// process (rather than just counting). Each spawned Roblox process
    /// registers as its own NSRunningApplication entry (PID-scoped),
    /// so PIDs are unique per instance.
    nonisolated private static func runningRobloxPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications
            .lazy
            .filter { $0.bundleIdentifier?.hasPrefix("com.roblox") == true }
            .map { $0.processIdentifier })
    }

    /// After a launch fires, wait for the spawned Roblox to fully
    /// settle before letting the next queued launch start its 600 MB
    /// copy + spawn. "Settled" means the NSRunningApplication for the
    /// new PID has `isFinishedLaunching == true` (NSApplicationDidFinish-
    /// LaunchingNotification has fired), which is roughly when the
    /// first window is responsive. Just "process registered" isn't
    /// enough — at smoke 2026-05-08 the first rapid-fire launch's
    /// window appeared then closed because the second launch's work
    /// (sem_unlink + Info.plist mod + 600 MB copy disk thrash) hit
    /// while the engine was still in its vulnerable boot window.
    ///
    /// Three timeouts to bound the wait:
    ///   - `timeoutToAppear`: how long to wait for the new PID to register
    ///   - `timeoutToFinishLaunching`: how long to wait for the new
    ///      app's `isFinishedLaunching` flag (some apps never set it;
    ///      Roblox does, but be defensive)
    ///   - `postGrace`: a final settle window so the next launch's
    ///      disk-heavy work doesn't immediately hit the just-launched
    ///      engine
    /// On any timeout, return — either the launch actually failed
    /// (stalling forever helps no one) or the user's machine is just
    /// slower than expected.
    nonisolated private static func waitForLaunchToSettle(
        baseline: Set<pid_t>,
        timeoutToAppear: TimeInterval = 8.0,
        timeoutToFinishLaunching: TimeInterval = 20.0,
        postGrace: TimeInterval = 2.0
    ) async {
        // Phase 1: wait for the new PID to appear in runningApplications.
        let appearDeadline = Date().addingTimeInterval(timeoutToAppear)
        var spawned: NSRunningApplication? = nil
        while Date() < appearDeadline {
            let newApp = NSWorkspace.shared.runningApplications
                .lazy
                .filter { $0.bundleIdentifier?.hasPrefix("com.roblox") == true }
                .first { !baseline.contains($0.processIdentifier) }
            if let newApp {
                spawned = newApp
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        guard let spawned else { return }

        // Phase 2: wait for isFinishedLaunching (engine has drawn its
        // first window + posted the Cocoa launch-finished notification).
        let finishDeadline = Date().addingTimeInterval(timeoutToFinishLaunching)
        while Date() < finishDeadline,
              !spawned.isFinishedLaunching,
              !spawned.isTerminated {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        // Phase 3: post-grace. Lets the engine run its first second
        // of "I'm alive" work (network handshake, asset preloading,
        // semaphore-recreation defenses) before the next queued
        // launch's sem_unlink + spawn lands.
        try? await Task.sleep(nanoseconds: UInt64(postGrace * 1_000_000_000))
    }

    // MARK: - Off-main worker (no actor isolation; runs on Task.detached)

    nonisolated private static func performLaunch(_ url: URL, enabled: Bool, semaphoreName: String, displayLabel: String? = nil) async {
        if !enabled {
            // Multi-instance OFF — open the original Roblox.app with the URL.
            // Without our break, only one Roblox can run; the second click
            // simply activates the existing window.
            let robloxURL = URL(fileURLWithPath: RobloxAppCopier.robloxAppPath, isDirectory: true)
            do {
                try await openRoblox(at: robloxURL, with: url)
            } catch {
                await MainActor.run {
                    MultiInstanceState.shared.lastError =
                        "Failed to launch Roblox: \(error.localizedDescription)"
                }
            }
            return
        }

        do {
            // Ordering matches Insadem's working Go reference. Modifying
            // Info.plist BEFORE the open call invalidates the bundle's
            // cdhash; macOS amfid then refuses the spawn (Hardened Runtime
            // fails closed) → "Launchd job spawn failed" (caught at v0.1.3).
            // Steps:
            //   1. Copy app (signature intact, plist not yet modified).
            //   2. sem_unlink → kernel-level singleton check cleared.
            //   3. open -n -a → spawn the copy with intact signature; the
            //      running process snapshots Info.plist into memory.
            //   4. NOW modify Info.plist (defensive housekeeping for any
            //      subsequent relaunch of this same copy; doesn't affect
            //      the already-running process).
            //   5. sem_unlink again — race buffer if Roblox-on-launch
            //      recreated the semaphore between our first sem_unlink
            //      and the process spawn.
            //
            // `semaphoreName` comes from RobloxCompatStore so a Roblox
            // rename can be patched without an app release.
            let copy = try RobloxAppCopier.copyAppForInstance(bundleLabel: displayLabel)
            _ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)
            try await openRoblox(at: copy, with: url)
            try? RobloxAppCopier.setMultipleInstancesProhibitionPostLaunch(at: copy)
            _ = SemaphoreBreaker.breakRobloxSingleton(name: semaphoreName)
            await MainActor.run {
                MultiInstanceState.shared.instanceCount += 1
                MultiInstanceState.shared.lastError = nil
            }
        } catch {
            await MainActor.run {
                MultiInstanceState.shared.lastError =
                    "Multi-instance launch failed: \(error.localizedDescription)"
            }
        }
    }

    nonisolated private static func openRoblox(at appURL: URL, with url: URL) async throws {
        // Use /usr/bin/open -n -a <copy> <url>. NSWorkspace.shared.open
        // (Cocoa idiom) was tried first but its URL-handler resolution
        // prefers a registered .app for the bundle ID (Roblox's) and
        // ignored our explicit copy URL — the user saw "The application
        // '<uuid>.app' can't be opened" against fresh copies even with
        // createsNewApplicationInstance=true.
        //
        // `-n` forces a new instance even if the bundle ID is already
        // running. `-a <path>` pins to the copy at the exact path. The
        // trailing URL is handed off to the .app's URL handler.

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -W would block until exit (useful for debugging) — we don't
        // want that in production. -g would launch hidden — also not
        // what we want. -n -a is the de-facto standard.
        task.arguments = ["-n", "-a", appURL.path, url.absoluteString]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        NSLog("[RORORO] open -n -a \(appURL.path) \(url.absoluteString)")

        try task.run()
        task.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: outData, encoding: .utf8) ?? ""
        let stderrText = String(data: errData, encoding: .utf8) ?? ""

        NSLog("[RORORO] open exit=\(task.terminationStatus) stdout=\(stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) stderr=\(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))")

        if task.terminationStatus != 0 {
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            throw NSError(
                domain: "MultiInstanceCoordinator",
                code: Int(task.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open exited \(task.terminationStatus): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
                ]
            )
        }
    }
}
