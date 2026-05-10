// TrayController.swift
// NSStatusItem in the menu bar. Composite tray icon:
//   center → most-recently-launched account's avatar (clipped circle),
//             or the RORORO app icon when no account has launched yet
//   ring   → state color around the circle
//             cyan    = multi-instance ON
//             slate   = multi-instance OFF
//             magenta = last launch errored
//
// Avatar fetch is async; images cache by (userId, url) so the 0.5s
// observation poll doesn't re-hit the network.
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

    /// Cached avatar so the 0.5s state-poll re-render doesn't re-fetch
    /// every tick. Keyed by (userId, url) — re-fetches when either changes
    /// (e.g., user updates their Roblox avatar, or a different account
    /// becomes most-recent).
    private var cachedAvatar: (userId: String, url: URL, image: NSImage)?
    private var avatarFetchInFlight: String?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Initial image: app icon ringed in slate (multi-instance OFF).
        // The state observer kicks in within 0.5s and will swap to the
        // correct color + active-account avatar.
        item.button?.image = trayImage(color: Theme.Color.trayOff, avatar: appIconForTray())
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

        // Most-recently-launched account drives the tray avatar.
        // Read from AccountStore.shared (also @MainActor @Observable);
        // poll cadence picks up changes within 0.5s.
        let activeAccount = AccountStore.shared.accounts
            .max(by: {
                ($0.lastLaunchedAt ?? .distantPast) < ($1.lastLaunchedAt ?? .distantPast)
            })

        let avatarImage = activeAccountAvatarImage(active: activeAccount)
        statusItem?.button?.image = trayImage(color: color, avatar: avatarImage)
        toggleItem.title = "Multi-instance: \(snapshot.enabled ? "ON" : "OFF")"

        // Auto-keys live status next to the icon (Slope C wave 3c).
        // Empty when stopped — title hides automatically. Short forms
        // so the menu bar doesn't overflow.
        statusItem?.button?.title = autoKeysTrayTitle()
    }

    /// Compose a tight one-line auto-keys status for the menu bar
    /// title slot. Fits next to the existing avatar+ring image without
    /// crowding other apps' menu items.
    private func autoKeysTrayTitle() -> String {
        let vm = AutoKeysCyclerViewModel.shared
        switch vm.state {
        case .stopped:
            return ""
        case .running:
            if let key = vm.currentStepKeyName, let now = vm.currentTargetLabel {
                return " \(key)→\(now)"
            }
            if let now = vm.currentTargetLabel {
                return " ▶\(now)"
            }
            if let next = vm.nextIterationAt {
                let secs = max(0, Int(next.timeIntervalSinceNow))
                return " ⧗\(secs)s"
            }
            return " ▶"
        case .paused(.userEngaged, _):
            return " ⏸"
        case .paused(.userRequested, _):
            return " ⏸"
        case .paused(.focusStolen, _):
            return " ⏸"
        }
    }

    /// Returns a cached avatar image if available; kicks off an async
    /// fetch if the active account's avatar URL changed since last cache.
    /// Falls back to the app's own icon when:
    ///   - no accounts have ever launched (lastLaunchedAt is nil for all)
    ///   - the active account has no avatar URL yet
    ///   - the fetch is in flight (returns app icon until image lands)
    private func activeAccountAvatarImage(active: Account?) -> NSImage {
        guard let active,
              active.lastLaunchedAt != nil,
              let avatarURL = active.avatarThumbnailURL else {
            return appIconForTray()
        }

        // Cache hit: same userId + url → reuse.
        if let cached = cachedAvatar,
           cached.userId == active.userId,
           cached.url == avatarURL {
            return cached.image
        }

        // Cache miss: kick off async fetch (deduped). Return app icon
        // until the fetch completes; the next 0.5s poll will pick up the
        // updated cache.
        if avatarFetchInFlight != active.userId {
            avatarFetchInFlight = active.userId
            let userId = active.userId
            Task.detached { [weak self] in
                guard let data = try? await URLSession.shared.data(from: avatarURL).0,
                      let image = NSImage(data: data) else {
                    await MainActor.run { self?.avatarFetchInFlight = nil }
                    return
                }
                await MainActor.run {
                    self?.cachedAvatar = (userId: userId, url: avatarURL, image: image)
                    self?.avatarFetchInFlight = nil
                }
            }
        }

        return appIconForTray()
    }

    /// Bundle's own icon as an NSImage. Used as the tray base image when
    /// no avatar is available. NSImage.applicationIconName ("NSApplicationIcon")
    /// returns whatever the app's CFBundleIconName / Asset Catalog AppIcon
    /// resolves to at runtime.
    private func appIconForTray() -> NSImage {
        if let app = NSImage(named: NSImage.applicationIconName) {
            return app
        }
        // Final fallback: a transparent placeholder. Keeps the ring drawable.
        return NSImage(size: NSSize(width: 18, height: 18))
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

    /// Composite tray icon: avatar (or app icon) clipped to a circle with
    /// a colored ring outline. Custom — not a template — because the
    /// ring color is the load-bearing state signal AND we want full-color
    /// avatars rather than monochrome silhouettes.
    private func trayImage(color: SwiftUI.Color, avatar: NSImage) -> NSImage {
        let size = NSSize(width: 22, height: 22)
        let nsColor = NSColor(color)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let inset: CGFloat = 1
        let rect = NSRect(x: inset, y: inset, width: size.width - 2 * inset, height: size.height - 2 * inset)

        // Draw avatar / app icon clipped to a circle. Save/restore graphics
        // state so the clip doesn't bleed into the ring stroke below.
        NSGraphicsContext.current?.saveGraphicsState()
        let clipPath = NSBezierPath(ovalIn: rect)
        clipPath.addClip()
        avatar.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()

        // Ring on top.
        let ringPath = NSBezierPath(ovalIn: rect)
        ringPath.lineWidth = 2.0
        nsColor.setStroke()
        ringPath.stroke()

        return image
    }
}
