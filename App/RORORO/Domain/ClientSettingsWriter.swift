// ClientSettingsWriter.swift
// Domain — atomic JSON writes to Roblox's `ClientAppSettings.json`.
//
// The FFlag injection sink: `<RobloxBundle>/Contents/MacOS/ClientSettings/
// ClientAppSettings.json`. Roblox reads this at engine startup and applies
// any FFlags (`FFlag*`, `DFFlag*`, `FInt*`, `DFInt*`, `FString*`,
// `DFString*`) that match its in-process whitelist. Post-Hyperion the
// allowlist is narrow — graphics-API switches and quality knobs survive,
// framerate caps don't (use GlobalSettingsWriter for those).
//
// Posture (per the AppleBlox spike, 2026-05-08):
//   - Atomic write (tmp + rename) via Data.write(.atomic). AppleBlox's
//     direct overwrite is the single most-likely race condition in their
//     codebase; we don't inherit it.
//   - Hash-detect user hand-edits before stomping. AppleBlox unconditionally
//     `rm -rf`s the entire ClientSettings/ dir on every launch — any user
//     hand-edited FFlags get nuked silently. We store a hash of what we
//     last wrote; if the on-disk hash differs, the user touched it and
//     we surface a flag for the caller to decide (preserve / merge / stomp).
//   - Cleanup is Roblox-PID-exit triggered by the launcher, NOT setTimeout.
//     AppleBlox's `setTimeout(rm, 5000)` is a Heisenbug — on slow Macs the
//     rm fires before Roblox parses the file. We expose `cleanup()` for
//     the launcher to call after observing process termination.
//
// Bundle-write override note: this writes INSIDE Roblox.app. CLAUDE.md
// previously prohibited bundle writes, but the AppleBlox spike confirmed
// Roblox's macOS installer drops the bundle user-writable and the
// signature does not strict-validate user-data subdirectories. The
// /ClientSettings/ subdir is a user-data path, not a code-signed
// resource, so writing there does not break code signing in practice.

import Foundation
import CryptoKit

public enum ClientSettingsWriter {

    public enum WriterError: Error, Equatable {
        case bundleNotFound
        case writeFailed(underlying: String)
        case readFailed(underlying: String)
    }

    /// Outcome of a write — useful for callers deciding whether to surface
    /// "your hand edits were preserved / merged / stomped" UI in the future.
    public enum WriteOutcome: Equatable {
        /// File didn't exist before; we wrote fresh.
        case createdFresh
        /// File existed but matched our last-known hash; safe to overwrite.
        case overwroteOurOwn
        /// File existed and DID NOT match our last-known hash — user
        /// hand-edited. We stomped per the `policy` argument; caller
        /// can adjust policy to preserve in the future.
        case stompedUserEdit
    }

    /// Policy for handling files the user hand-edited outside RORORO.
    public enum HandEditPolicy {
        /// Always overwrite. Matches AppleBlox's behavior.
        case stomp
        /// If the on-disk hash doesn't match our last-known, refuse to write
        /// and throw. Caller surfaces UI: "Roblox FFlags were changed outside
        /// RORORO; reset?".
        case preserveAndThrow
    }

    /// Write `flags` as JSON to the resolved bundle's ClientAppSettings.json
    /// path. Atomic. Creates intermediate ClientSettings/ directory if absent.
    /// Returns the outcome so callers can react to user-hand-edit detection.
    @discardableResult
    public static func write(
        flags: [String: Any],
        policy: HandEditPolicy = .stomp,
        bundleResolver: () -> URL? = RobloxBundleResolver.clientSettingsFileURL
    ) throws -> WriteOutcome {
        guard let url = bundleResolver() else {
            throw WriterError.bundleNotFound
        }

        let outcome = try detectOutcome(at: url, policy: policy)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: flags,
                options: [.prettyPrinted, .sortedKeys]
            )
        } catch {
            throw WriterError.writeFailed(underlying: "json encode: \(error)")
        }

        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw WriterError.writeFailed(underlying: String(describing: error))
        }

        rememberHash(of: data, for: url)
        return outcome
    }

    /// Remove the file we wrote. Called by the launcher after observing
    /// the Roblox process exit (NOT on a setTimeout — that's the
    /// Heisenbug we're avoiding).
    public static func cleanup(
        bundleResolver: () -> URL? = RobloxBundleResolver.clientSettingsFileURL
    ) throws {
        guard let url = bundleResolver() else {
            throw WriterError.bundleNotFound
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            forgetHash(for: url)
        } catch {
            throw WriterError.writeFailed(underlying: "cleanup: \(error)")
        }
    }

    // MARK: - Hand-edit detection

    /// Last-known hash per file, in-memory only. Survives launches via
    /// UserDefaults if the host wires that up; for now in-process is
    /// enough — every fresh app launch starts with no remembered hashes
    /// and the first write is treated as `createdFresh` or
    /// `stompedUserEdit` depending on whether Roblox already had a file.
    private static var hashStore: [String: String] = [:]

    private static func detectOutcome(at url: URL, policy: HandEditPolicy) throws -> WriteOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .createdFresh
        }
        let existingData: Data
        do {
            existingData = try Data(contentsOf: url)
        } catch {
            throw WriterError.readFailed(underlying: String(describing: error))
        }
        let existingHash = sha256(of: existingData)
        if let lastKnown = hashStore[url.path], lastKnown == existingHash {
            return .overwroteOurOwn
        }
        switch policy {
        case .stomp:
            return .stompedUserEdit
        case .preserveAndThrow:
            throw WriterError.writeFailed(
                underlying: "user hand-edited ClientAppSettings.json; policy=preserveAndThrow"
            )
        }
    }

    private static func rememberHash(of data: Data, for url: URL) {
        hashStore[url.path] = sha256(of: data)
    }

    private static func forgetHash(for url: URL) {
        hashStore.removeValue(forKey: url.path)
    }

    private static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
