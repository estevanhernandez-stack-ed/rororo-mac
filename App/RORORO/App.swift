// App.swift
// RORORO — entry point.
//
// v1 shell: a single WindowGroup. The bootstrap pattern follows macRo's
// deferred-init lesson — never install NSEvent monitors / event-coupled
// services from App.init(), since SwiftUI's event-routing setup runs in
// the same window. All such installations defer to .onAppear on the root
// view (the trap: silent loss of mouse-event delivery, dim traffic lights,
// no hover state). Sparkle wiring + tray + multi-instance coordinator
// land in later phases via the same .onAppear pattern.

import SwiftUI

@main
struct ROROROApp: App {
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
                    // (never .init()) per the macRo NSEvent-monitor trap —
                    // AppKit-side surfaces install after the first window
                    // is on-screen.
                    TrayController.shared.install()
                }
                .onOpenURL { url in
                    // Routed when the user clicks Play on roblox.com or
                    // any other app hands us a `roblox-player:` URL.
                    MultiInstanceCoordinator.shared.handleIncomingURL(url)
                }
        }
        .windowResizability(.contentSize)
    }
}
