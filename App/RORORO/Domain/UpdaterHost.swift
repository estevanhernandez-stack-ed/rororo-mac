// UpdaterHost.swift
// Domain — app-lifetime owner for Sparkle's SPUStandardUpdaterController.
//
// Mirrors the singleton pattern used by Engine.shared / LibraryStore.shared
// in macRo. ROROROApp.onAppear calls `UpdaterHost.shared.bootIfNeeded()`
// exactly once; downstream surfaces (UpdateSettingsView, the menu-bar
// Check-for-Updates command, anything future) read
// `UpdaterHost.shared.updater` to reach Sparkle's `SPUUpdater` without
// threading a binding through the view tree.
//
// Why deferred boot: SPUStandardUpdaterController is framework-internal
// scheduling (it does NOT install NSEvent monitors), so init-time
// instantiation is genuinely safe — but we boot from .onAppear for
// symmetry with the multi-instance + tray pattern. One trap-by-class-of-bug
// rule keeps App.init() inert.
//
// Threading: bootIfNeeded() is @MainActor — Sparkle's controller must be
// constructed on main. Reads of `controller` / `updater` are also
// main-thread by contract; SwiftUI surfaces are already on main.

import Foundation
import Sparkle

@MainActor
final class UpdaterHost {

    static let shared = UpdaterHost()

    /// Boot-once flag. Idempotent — a second call is a no-op.
    private(set) var controller: SPUStandardUpdaterController?

    /// Convenience: the underlying SPUUpdater, or nil pre-boot.
    var updater: SPUUpdater? { controller?.updater }

    private init() {}

    /// Construct the updater controller exactly once.
    ///
    /// `startingUpdater: true` once bootstrap step 1 has landed (Sparkle
    /// EdDSA public key in Info.plist + this flip in the same commit). Until
    /// the rest of the bootstrap chain is complete (Apple Developer ID cert,
    /// notary creds, GitHub Pages — see `tools/release/README.md`), Sparkle
    /// will check the appcast URL and either find no items (if no v* tag has
    /// shipped a release yet) or surface them. Both are safe — the crash
    /// trap was specifically the placeholder-public-key + 404-appcast combo.
    func bootIfNeeded() {
        guard controller == nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
}
