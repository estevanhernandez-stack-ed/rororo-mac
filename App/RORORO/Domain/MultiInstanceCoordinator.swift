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
    }

    /// Route an incoming `roblox-player:` URL through the multi-instance
    /// recipe. Called from `.onOpenURL`. Non-throwing — errors land on
    /// `MultiInstanceState.shared.lastError`.
    public func handleIncomingURL(_ url: URL) {
        let enabled = MultiInstanceState.shared.enabled
        Task.detached(priority: .userInitiated) {
            await Self.performLaunch(url, enabled: enabled)
        }
    }

    /// Manually re-trigger URL-scheme restore (used by Settings "Reset
    /// system handler" button — Phase 5).
    public func shutDown() async {
        await URLSchemeHandler.shared.restore()
    }

    @objc nonisolated private func handleWillTerminate(_ note: Notification) {
        Task { @MainActor in
            await URLSchemeHandler.shared.restore()
        }
    }

    // MARK: - Off-main worker (no actor isolation; runs on Task.detached)

    nonisolated private static func performLaunch(_ url: URL, enabled: Bool) async {
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
            let copy = try RobloxAppCopier.copyAppForInstance()
            _ = SemaphoreBreaker.breakRobloxSingleton()
            try await openRoblox(at: copy, with: url)
            // Race-buffer break: covers the case where Roblox-on-launch
            // recreates the semaphore between our first sem_unlink and the
            // process spawn (real on slow disks).
            _ = SemaphoreBreaker.breakRobloxSingleton()
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
        // Two ways to launch a copy with a URL on macOS:
        //   (a) NSWorkspace.shared.open([url], withApplicationAt: copy, configuration:
        //       { createsNewApplicationInstance = true })
        //   (b) /usr/bin/open -n -a <copy> <url>
        //
        // (a) is the Cocoa idiom, but in v0.1.1 it surfaced "The application
        // '<uuid>.app' can't be opened." against fresh per-instance copies
        // even with createsNewApplicationInstance=true. LaunchServices' URL-
        // handler resolution prefers a registered .app for the bundle ID
        // (Roblox's bundle ID) and ignores the explicit copy URL in some
        // configs.
        //
        // (b) is what the Insadem Go reference uses and is the de-facto
        // standard for the multi-instance technique on macOS — `-n` forces
        // a new instance, `-a <path>` pins to the copy at the exact path,
        // and the trailing URL is handed off to that .app's URL handler.

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", "-a", appURL.path, url.absoluteString]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "exit \(task.terminationStatus)"
            throw NSError(
                domain: "MultiInstanceCoordinator",
                code: Int(task.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "open -n -a failed: \(msg)"]
            )
        }
    }
}
