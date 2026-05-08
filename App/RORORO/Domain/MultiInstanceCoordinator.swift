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

    /// One-time bootstrap. Run from `.onAppear` on the root view. Safe to
    /// call multiple times — second call is a no-op. Performs:
    ///   - Stale-instance cleanup (off-main).
    ///   - URL scheme claim (async).
    ///   - willTerminate observer registration (for restore-on-quit).
    public func bootIfNeeded() {
        guard !didBoot else { return }
        didBoot = true

        // Off-main background cleanup. Worst case it fails silently and the
        // user has stale .app copies until next boot — non-fatal.
        Task.detached(priority: .background) {
            try? RobloxAppCopier.cleanupStaleInstances()
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
    /// recipe. Called from `.onOpenURL`. Non-throwing — errors land on
    /// `MultiInstanceState.shared.lastError`.
    public func handleIncomingURL(_ url: URL) {
        let enabled = MultiInstanceState.shared.enabled
        let semaphoreName = RobloxCompatStore.shared.currentSemaphoreName()
        Task.detached(priority: .userInitiated) {
            await Self.performLaunch(url, enabled: enabled, semaphoreName: semaphoreName)
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

    // MARK: - Off-main worker (no actor isolation; runs on Task.detached)

    nonisolated private static func performLaunch(_ url: URL, enabled: Bool, semaphoreName: String) async {
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
            let copy = try RobloxAppCopier.copyAppForInstance()
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
