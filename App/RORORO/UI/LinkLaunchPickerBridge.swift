// LinkLaunchPickerBridge.swift
// UI — invisible bridge view that opens the LinkAccountPickerWindow
// scene when LinkLaunchCoordinator transitions to .choosing.
//
// Why a bridge? SwiftUI `Window` scenes (vs `WindowGroup`) are not
// auto-shown — they require an explicit `openWindow(id:)` invocation
// from a `@Environment(\.openWindow)` context. The coordinator lives
// in the Domain layer and has no @Environment access, so a SwiftUI
// surface needs to bridge the gap. This view sits as a zero-size
// `.background` of `ContentView`, observes the coordinator, and fires
// `openWindow(id:)` whenever state transitions into `.choosing`.
//
// Belt-and-suspenders: `.onAppear` also checks the current state in
// case the coordinator transitioned BEFORE this view's subscription
// landed (cold-start race when the inbound URL hops in faster than
// SwiftUI's render).

import SwiftUI

struct LinkLaunchPickerBridge: View {

    @ObservedObject private var coordinator: LinkLaunchCoordinator
    @Environment(\.openWindow) private var openWindow

    init(coordinator: LinkLaunchCoordinator = .shared) {
        self.coordinator = coordinator
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                openIfChoosing()
            }
            .onChange(of: coordinator.state) { _, _ in
                openIfChoosing()
            }
    }

    private func openIfChoosing() {
        if case .choosing = coordinator.state {
            openWindow(id: LinkAccountPickerWindow.windowID)
        }
    }
}
