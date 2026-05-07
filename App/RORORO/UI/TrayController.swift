// TrayController.swift
// NSStatusItem in the menu bar. Status ring colors:
//   cyan      — multi-instance ON
//   slate     — multi-instance OFF
//   magenta   — last launch errored (lastError != nil)
//
// Install in `.onAppear`, NEVER `.init()` — same trap macRo learned at
// item 5 (NSEvent monitor + AppKit booting interaction). NSStatusItem
// itself is safer than NSEvent but the install-deferred discipline holds:
// AppKit-side surfaces should land after the first window is on-screen.

import AppKit
import Foundation
import SwiftUI
import Observation

@MainActor
final class TrayController: NSObject {

    static let shared = TrayController()
    private override init() { super.init() }

    private var statusItem: NSStatusItem?
    private var observationTask: Task<Void, Never>?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = trayImage(color: Theme.Color.trayOff)
        item.button?.image?.isTemplate = false  // Custom-tinted, not template.

        let menu = NSMenu()

        let showMain = NSMenuItem(title: "Show RORORO", action: #selector(showMainWindow), keyEquivalent: "")
        showMain.target = self
        menu.addItem(showMain)

        let toggle = NSMenuItem(title: "Multi-instance: ON", action: #selector(toggleMultiInstance), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit RORORO", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        startObservingState(toggleMenuItem: toggle)
    }

    private func startObservingState(toggleMenuItem: NSMenuItem) {
        // Observation loop refreshes the icon + toggle label whenever
        // MultiInstanceState changes. The Observation framework's
        // withObservationTracking re-fires on each access; wrap in a Task
        // so we keep watching for the app's lifetime.
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let snapshot: (enabled: Bool, hasError: Bool) = withObservationTracking {
                    let state = MultiInstanceState.shared
                    return (state.enabled, state.lastError != nil)
                } onChange: {
                    // Fires on next mutation; the loop pulls a fresh snapshot.
                }
                self?.refresh(snapshot: snapshot, toggleItem: toggleMenuItem)
                // Wait for next change. We use a tiny sleep + re-read; with
                // Observation's onChange callback we'd need an async stream
                // bridge. Sleep cadence is gentle — 0.5s feels instant.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func refresh(snapshot: (enabled: Bool, hasError: Bool), toggleItem: NSMenuItem) {
        let color: SwiftUI.Color = snapshot.hasError
            ? Theme.Color.trayError
            : (snapshot.enabled ? Theme.Color.trayOn : Theme.Color.trayOff)
        statusItem?.button?.image = trayImage(color: color)
        toggleItem.title = "Multi-instance: \(snapshot.enabled ? "ON" : "OFF")"
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func toggleMultiInstance() {
        MultiInstanceState.shared.enabled.toggle()
    }

    /// Render a 16x16 colored ring as the tray icon. Custom — not a
    /// template — because the ring color is the load-bearing state signal.
    private func trayImage(color: SwiftUI.Color) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let nsColor = NSColor(color)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        let inset: CGFloat = 2
        let rect = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = 2.5
        nsColor.setStroke()
        path.stroke()
        return image
    }
}
