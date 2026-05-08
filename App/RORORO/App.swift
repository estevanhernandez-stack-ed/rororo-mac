// App.swift
// RORORO — entry point.
//
// v1 shell: a single WindowGroup. The bootstrap pattern follows macRo's
// deferred-init lesson — never install NSEvent monitors / event-coupled
// services from App.init(), since SwiftUI's event-routing setup runs in
// the same window. All such installations defer to .onAppear on the root
// view (the trap: silent loss of mouse-event delivery, dim traffic lights,
// no hover state).
//
// Sparkle (Phase 6): SPUStandardUpdaterController is framework-internal
// scheduling — it does NOT install NSEvent monitors — so init-time
// instantiation is genuinely safe. We still defer to .onAppear via
// `UpdaterHost.shared.bootIfNeeded()` for symmetry with the existing
// pattern; one trap-by-class-of-bug rule keeps App.init() intentionally
// inert.

import AppKit
import Sparkle
import SwiftUI

@main
struct ROROROApp: App {

    @State private var checkForUpdatesViewModel: CheckForUpdatesViewModel? = nil

    var body: some Scene {
        WindowGroup("RORORO") {
            ContentView()
                .frame(minWidth: 720, minHeight: 480)
                .onAppear {
                    // Boot the multi-instance coordinator: claims the
                    // `roblox-player://` URL scheme, registers the
                    // willTerminate restore hook, kicks off stale-instance
                    // cleanup. Idempotent.
                    MultiInstanceCoordinator.shared.bootIfNeeded()
                    // Install the menu-bar tray icon. Deferred to .onAppear
                    // (never .init()) per the macRo NSEvent-monitor trap.
                    TrayController.shared.install()
                    // Boot Sparkle's updater. Idempotent — second call no-ops.
                    // Reads SUFeedURL + SUPublicEDKey + scheduling defaults
                    // from Info.plist. updaterDelegate / userDriverDelegate
                    // stay nil for v1 — the standard controller's defaults
                    // are correct.
                    UpdaterHost.shared.bootIfNeeded()
                    if checkForUpdatesViewModel == nil,
                       let updater = UpdaterHost.shared.updater {
                        checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
                    }
                    // Best-effort refresh across all saved accounts on
                    // boot — cookie-health probe (Slope B3') plus
                    // display-name + avatar refresh (Slope B2'). Async
                    // and fail-soft per account; the row UI updates as
                    // each account's response lands.
                    Task { @MainActor in
                        await AccountStore.shared.refreshAllAccounts()
                    }
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onOpenURL { url in
                    // Routed when the user clicks Play on roblox.com or
                    // any other app hands us a `roblox-player:` URL.
                    MultiInstanceCoordinator.shared.handleIncomingURL(url)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // Sparkle's "Check for Updates…" menu item, slotted under the
            // app menu after "About RORORO". The button is disabled
            // pre-boot (updater nil) and while Sparkle is mid-check.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(viewModel: checkForUpdatesViewModel)
            }
        }
    }
}

// MARK: - Check for Updates menu item

/// Menu-item wrapper. Reads the boot-time view-model; falls back to a
/// disabled button until the .onAppear cycle has completed (in practice
/// the user can't reach the menu before that anyway).
struct CheckForUpdatesMenuItem: View {
    let viewModel: CheckForUpdatesViewModel?

    var body: some View {
        if let viewModel {
            CheckForUpdatesButton(viewModel: viewModel)
        } else {
            Button("Check for Updates…") { /* no-op pre-boot */ }
                .disabled(true)
        }
    }
}

/// Inner button wired to a live `CheckForUpdatesViewModel`. Reactive to
/// Sparkle's `canCheckForUpdates` so the disabled state stays in sync.
struct CheckForUpdatesButton: View {
    @ObservedObject var viewModel: CheckForUpdatesViewModel

    var body: some View {
        Button("Check for Updates…", action: viewModel.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

/// View-model that mirrors Sparkle's `canCheckForUpdates` into a
/// SwiftUI-observable `@Published`. Sparkle exposes this property as
/// KVO-compliant; the Combine publisher assigns into the `@Published`
/// for free.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
