// URLSchemeHandler.swift
// Domain — claim/restore the system's default handler for `roblox-player://`.
//
// When multi-instance is ON, RORORO must be the default handler for the
// `roblox-player:` scheme so that clicking Play on roblox.com routes the
// URL through us first. We then run the multi-instance recipe (copy app +
// flip plist + sem_unlink + spawn) before handing the URL off to the copy.
//
// On quit, we restore the previous handler — usually `/Applications/Roblox.app`
// itself. The previous handler's bundle ID is saved to UserDefaults so a
// crash before .restore() can be recovered on next boot (see
// MultiInstanceCoordinator.bootIfNeeded).
//
// API choice: macOS 14+ exposes
//   NSWorkspace.shared.setDefaultApplication(at:toOpenURLsWithScheme:completionHandler:)
// as the modern (non-deprecated) replacement for LSSetDefaultHandlerForURLScheme.
// We use it on the boot path. The willTerminate restore path also calls it
// async — the app may exit before completion fires, but UserDefaults still
// holds the previous handler so a future boot can re-restore.

import AppKit
import Foundation

public final class URLSchemeHandler {

    public static let shared = URLSchemeHandler()
    private init() {}

    public static let robloxPlayerScheme = "roblox-player"

    /// UserDefaults key for the previous default handler's bundle ID. We
    /// save this before claiming the scheme so we can put it back on quit
    /// (or on next boot if the app crashed mid-session).
    public static let savedHandlerKey = "RORORO.URLSchemeHandler.savedRobloxPlayerHandler"

    public enum URLSchemeError: Error, Equatable {
        case ourBundleIDUnknown
        case setDefaultFailed(message: String)
    }

    /// Whether the system currently routes `roblox-player://` to us.
    public var isClaimed: Bool {
        guard let ourBundleID = Bundle.main.bundleIdentifier else { return false }
        guard let currentHandler = currentDefaultHandlerBundleID() else { return false }
        return currentHandler.caseInsensitiveCompare(ourBundleID) == .orderedSame
    }

    /// Bundle ID of whichever app currently owns the `roblox-player://`
    /// scheme, or nil if nothing is registered.
    public func currentDefaultHandlerBundleID() -> String? {
        let probeURL = URL(string: "\(Self.robloxPlayerScheme)://probe")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probeURL) else {
            return nil
        }
        return Bundle(url: appURL)?.bundleIdentifier
    }

    /// Claim the `roblox-player://` scheme for RORORO. Saves the previous
    /// handler to UserDefaults so we can restore on quit. Idempotent —
    /// no-ops when we already own the scheme.
    public func claim() async throws {
        guard let ourBundleID = Bundle.main.bundleIdentifier else {
            throw URLSchemeError.ourBundleIDUnknown
        }

        if let current = currentDefaultHandlerBundleID(),
           current.caseInsensitiveCompare(ourBundleID) == .orderedSame {
            // Already claimed — nothing to do.
            return
        }

        // Save the previous handler ONLY if we don't already have one stashed.
        // Re-saving on every claim risks overwriting the original (e.g. if a
        // previous session crashed mid-launch and stashed our own bundle id
        // before the claim landed).
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.savedHandlerKey) == nil,
           let previous = currentDefaultHandlerBundleID(),
           previous.caseInsensitiveCompare(ourBundleID) != .orderedSame {
            defaults.set(previous, forKey: Self.savedHandlerKey)
        }

        let appURL = Bundle.main.bundleURL
        try await setDefaultApplicationAsync(at: appURL, scheme: Self.robloxPlayerScheme)
    }

    /// Restore the previously-saved default handler. Falls back to
    /// `/Applications/Roblox.app` if no previous handler was saved (typical
    /// fresh-install case where Roblox was always the handler). Best-effort
    /// — a partial restore is OK; the user can fix it manually via Finder
    /// "Get Info → Open with" if needed.
    public func restore() async {
        let defaults = UserDefaults.standard
        let previousID = defaults.string(forKey: Self.savedHandlerKey)

        let appURL: URL?
        if let previousID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previousID) {
            appURL = url
        } else {
            // Fall back to /Applications/Roblox.app if it exists.
            let robloxURL = URL(fileURLWithPath: RobloxAppCopier.robloxAppPath, isDirectory: true)
            if FileManager.default.fileExists(atPath: robloxURL.path) {
                appURL = robloxURL
            } else {
                appURL = nil
            }
        }

        guard let appURL else { return }

        try? await setDefaultApplicationAsync(at: appURL, scheme: Self.robloxPlayerScheme)
        defaults.removeObject(forKey: Self.savedHandlerKey)
    }

    /// Synchronous restore for the quit path. `restore()` is async and
    /// the process routinely exits before `NSWorkspace.setDefaultApplication`'s
    /// completion fires — observed 2026-09-13 on the dev machine: RORORO not
    /// running, LaunchServices still resolving `roblox-player://` to
    /// /Applications/RORORO.app. Combined with a user deleting RORORO.app
    /// (the LS handler entry and the saved-previous pref both survive that),
    /// every Play click then launches RORORO instead of Roblox — support
    /// case 2026-09-13. `LSSetDefaultHandlerForURLScheme` is deprecated but
    /// still shipped and returns synchronously, which is what a
    /// willTerminate hook needs.
    ///
    /// Restores to the saved-previous handler if that app still exists,
    /// else to `/Applications/Roblox.app` if present, else no-op.
    public func restoreSync() {
        let defaults = UserDefaults.standard
        let previousID = defaults.string(forKey: Self.savedHandlerKey)
        let ourID = Bundle.main.bundleIdentifier

        var targetID: String?
        if let previousID,
           previousID.caseInsensitiveCompare(ourID ?? "") != .orderedSame,
           NSWorkspace.shared.urlForApplication(withBundleIdentifier: previousID) != nil {
            targetID = previousID
        } else {
            let robloxURL = URL(fileURLWithPath: RobloxAppCopier.robloxAppPath, isDirectory: true)
            if let bundleID = Bundle(url: robloxURL)?.bundleIdentifier {
                targetID = bundleID
            }
        }
        guard let targetID else { return }

        let status = LSSetDefaultHandlerForURLScheme(
            Self.robloxPlayerScheme as CFString,
            targetID as CFString
        )
        if status == noErr {
            defaults.removeObject(forKey: Self.savedHandlerKey)
        } else {
            NSLog("[RORORO] URLSchemeHandler.restoreSync: LSSetDefaultHandlerForURLScheme → %d", status)
        }
    }

    private func setDefaultApplicationAsync(at appURL: URL, scheme: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error {
                    cont.resume(throwing: URLSchemeError.setDefaultFailed(message: error.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }
}
