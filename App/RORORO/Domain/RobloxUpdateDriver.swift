// RobloxUpdateDriver.swift
// Domain — the graceful half of the stale-Roblox story.
//
// RobloxVersionGate (ADR 0012) refuses the per-instance copy while
// /Applications/Roblox.app is behind live. This driver is what runs
// when the user says "Update Roblox" to that refusal (or, on the
// roblox-player:// link path, automatically):
//
//   1. Open the canonical /Applications/Roblox.app with no URL. The
//      player runs its own protocol-launch update check, spawns its
//      embedded RobloxPlayerInstaller, which downloads the new build,
//      moves it over /Applications/Roblox.app, and relaunches the
//      canonical player with `-isInstallerLaunch true`.
//   2. Poll the bundle's CFBundleShortVersionString until it equals
//      the live MacPlayer version (or time out).
//   3. Terminate the relaunched canonical player — it's an empty
//      window holding the singleton semaphore, and the user asked for a
//      per-account launch, not this one. Only `com.roblox.RobloxPlayer`
//      is touched; per-instance copies carry com.626labs.RORORO.instance.*
//      bundle IDs and are never terminated here.
//   4. Report `.updated` so the caller can re-run the original launch.
//
// Concurrency: one run at a time. A second caller while a run is in
// flight (a group launch where every account tripped the gate) joins
// the existing run instead of opening Roblox again.
//
// Every side effect is injected via `Dependencies` so the state machine
// is unit-testable without Roblox on the machine.

import AppKit
import Foundation

public actor RobloxUpdateDriver {

    public static let shared = RobloxUpdateDriver(dependencies: .production)

    public enum Outcome: Equatable, Sendable {
        /// Local already matched live; nothing was opened.
        case alreadyCurrent
        /// Roblox updated itself and the relaunched player was dismissed.
        case updated(to: String)
        /// Parity never arrived inside `timeout`.
        case timedOut(local: String?, live: String?)
        /// The live version couldn't be fetched — can't judge parity.
        case liveUnknown
        /// `/usr/bin/open` (or the injected opener) failed.
        case openFailed(reason: String)

        /// nil when the caller should retry the launch; otherwise the
        /// text to show instead.
        public var failureMessage: String? {
            switch self {
            case .alreadyCurrent, .updated:
                return nil
            case .timedOut(let local, let live):
                let installed = local ?? "unknown"
                let current = live ?? "unknown"
                return "Roblox didn't finish updating in time (installed \(installed), current \(current)). "
                    + "Open Roblox from /Applications, let it finish, then try Launch As again."
            case .liveUnknown:
                return "Couldn't reach Roblox's version service to check for an update. "
                    + "Open Roblox from /Applications once, then try Launch As again."
            case .openFailed(let reason):
                return "Couldn't open Roblox to update it: \(reason)"
            }
        }
    }

    public struct Dependencies: Sendable {
        public var localVersion: @Sendable () -> String?
        public var liveVersion: @Sendable () async -> String?
        public var openRoblox: @Sendable () async throws -> Void
        /// Terminate canonical `com.roblox.RobloxPlayer` processes.
        /// Returns how many were asked to terminate.
        public var terminateCanonicalPlayer: @Sendable () -> Int
        public var sleeper: Sleeper

        public init(
            localVersion: @escaping @Sendable () -> String?,
            liveVersion: @escaping @Sendable () async -> String?,
            openRoblox: @escaping @Sendable () async throws -> Void,
            terminateCanonicalPlayer: @escaping @Sendable () -> Int,
            sleeper: Sleeper
        ) {
            self.localVersion = localVersion
            self.liveVersion = liveVersion
            self.openRoblox = openRoblox
            self.terminateCanonicalPlayer = terminateCanonicalPlayer
            self.sleeper = sleeper
        }

        public static let production = Dependencies(
            localVersion: { RobloxVersionGate.localVersion(appPath: RobloxAppCopier.robloxAppPath) },
            liveVersion: { await RobloxVersionGate.shared.liveVersion() },
            openRoblox: { try Self.openCanonicalRoblox() },
            terminateCanonicalPlayer: { Self.terminateCanonicalPlayers() },
            sleeper: TaskSleeper()
        )

        /// `/usr/bin/open -a /Applications/Roblox.app` with no URL. Same
        /// launcher RobloxAppCopier's path uses, minus `-n` — we WANT the
        /// single canonical instance here.
        static func openCanonicalRoblox() throws {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", RobloxAppCopier.robloxAppPath]
            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = Pipe()
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "RobloxUpdateDriver",
                    code: Int(task.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: err.trimmingCharacters(in: .whitespacesAndNewlines)]
                )
            }
        }

        /// Canonical bundle ID only. Per-instance copies are
        /// `com.626labs.RORORO.instance.*` and must survive this.
        static func terminateCanonicalPlayers() -> Int {
            let players = NSWorkspace.shared.runningApplications.filter {
                $0.bundleIdentifier == "com.roblox.RobloxPlayer"
            }
            for app in players { app.terminate() }
            return players.count
        }
    }

    private let deps: Dependencies
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval
    /// After parity, how long to give the installer to relaunch the
    /// canonical player before we look for it to dismiss.
    private let playerSettleGrace: TimeInterval
    private var inFlight: Task<Outcome, Never>?

    public init(
        dependencies: Dependencies,
        timeout: TimeInterval = 180,
        pollInterval: TimeInterval = 2,
        playerSettleGrace: TimeInterval = 4
    ) {
        self.deps = dependencies
        self.timeout = timeout
        self.pollInterval = pollInterval
        self.playerSettleGrace = playerSettleGrace
    }

    /// Drive the update. Joins an in-flight run if one exists.
    public func run() async -> Outcome {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.perform() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func perform() async -> Outcome {
        guard let live = await deps.liveVersion() else { return .liveUnknown }
        if deps.localVersion() == live { return .alreadyCurrent }

        do {
            try await deps.openRoblox()
        } catch {
            return .openFailed(reason: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        var polls = 0
        let maxPolls = Int((timeout / max(pollInterval, 0.001)).rounded(.up))
        while true {
            try? await deps.sleeper.sleep(seconds: pollInterval)
            polls += 1
            if deps.localVersion() == live { break }
            // Two bounds: wall clock for production, poll count for
            // tests whose fake sleeper returns instantly.
            if Date() >= deadline || polls >= maxPolls {
                return .timedOut(local: deps.localVersion(), live: live)
            }
        }

        // Parity reached. Give the installer a beat to relaunch the
        // canonical player, then dismiss it. Retry a few times in case
        // it hasn't registered with the workspace yet.
        try? await deps.sleeper.sleep(seconds: playerSettleGrace)
        for _ in 0..<5 {
            if deps.terminateCanonicalPlayer() > 0 { break }
            try? await deps.sleeper.sleep(seconds: 1)
        }
        return .updated(to: live)
    }
}
