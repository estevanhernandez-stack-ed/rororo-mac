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
            VStack(spacing: 12) {
                Text("RORORO")
                    .font(.largeTitle)
                Text("Mac-native multi-Roblox launcher")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 720, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
