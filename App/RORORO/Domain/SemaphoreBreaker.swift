// SemaphoreBreaker.swift
// Domain — POSIX named semaphore unlinker for the macOS Roblox client.
//
// macOS Roblox enforces single-instance via a POSIX named semaphore at
// `/RobloxPlayerUniq`. The client creates the semaphore on launch and
// refuses to start if one already exists. Calling `sem_unlink` on the
// name destroys the kernel-level reference; the next RobloxPlayer
// process creates a fresh semaphore and starts cleanly. Already-running
// instances keep working — they hold their own sem_t handle internally.
//
// This is the macOS equivalent of RORORO Windows's `MutexHolder` (which
// holds `Local\ROBLOX_singletonEvent`). The mechanisms differ but the
// outcome is identical: defeat the singleton check at launch time.
//
// Technique provenance: Insadem's `multi-roblox-macos` (Go, public-source).
// We reimplement here in Swift; no code is copied.
//
// Posture note: this is not anti-detection. We don't inject into Roblox,
// modify the binary, or hide the semaphore from observation. We delete a
// kernel name that any process can delete — Roblox's own client could
// call `sem_unlink` on shutdown if it chose to. The client's "may be
// considered malicious behavior" stance applies; we don't ship anti-
// detection logic and never will.

import Foundation
import Darwin

/// Unlinks the macOS Roblox client's singleton-enforcement semaphore so
/// the next launched RobloxPlayer process can start without colliding
/// with an existing instance. Idempotent — calling on an already-unlinked
/// name returns `.alreadyUnlinked`. Safe-from-any-thread.
public enum SemaphoreBreaker {

    /// The semaphore name macOS Roblox creates. Stable across versions
    /// since at least 2023 per Insadem's published technique. If a
    /// future Roblox client renames this, the breaker silently no-ops
    /// (`.alreadyUnlinked` returned for an unknown name) and multi-
    /// instance launches will start failing — surface via diagnostics.
    public static let robloxSingletonSemaphoreName = "/RobloxPlayerUniq"

    public enum Outcome: Equatable, Sendable {
        /// Semaphore existed and was unlinked. Next launch will start clean.
        case unlinked
        /// Semaphore did not exist. Either no Roblox has run since boot,
        /// or a prior break() call already cleared it. Equivalent end state.
        case alreadyUnlinked
        /// Unexpected errno from sem_unlink. Not a normal-operation case
        /// — surface to the user with the underlying errno code.
        case failed(errno: Int32, description: String)
    }

    /// Unlink the canonical Roblox singleton semaphore. Returns the
    /// outcome; never throws. Run before each RobloxPlayer spawn.
    @discardableResult
    public static func breakRobloxSingleton() -> Outcome {
        return unlink(name: robloxSingletonSemaphoreName)
    }

    /// Unlink an arbitrary POSIX semaphore name. Public for tests and
    /// future-proofing if Roblox ships a new semaphore name we need to
    /// add to the break list.
    public static func unlink(name: String) -> Outcome {
        let result = sem_unlink(name)
        if result == 0 {
            return .unlinked
        }
        // sem_unlink returns -1 and sets errno on failure. ENOENT is the
        // expected "already gone" case; anything else is genuine failure.
        let err = errno
        switch err {
        case ENOENT:
            return .alreadyUnlinked
        default:
            let desc = String(cString: strerror(err))
            return .failed(errno: err, description: desc)
        }
    }
}
