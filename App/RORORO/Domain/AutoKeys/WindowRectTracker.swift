// WindowRectTracker.swift
// Domain — shared substrate for Slope D (smarter cycler). Caches the
// on-screen rect of each cycled Roblox window so two consumers can
// answer their respective questions:
//
//   - `AutoKeysSafetyMonitor` (D-2): is the cursor inside one of our
//     tracked Roblox windows? If so, mouseMoved doesn't pause the cycler.
//   - `AutoKeysCycler` / future `ActionStreamPlayer` (D-3 per ADR 0007):
//     translate window-relative replay coords to absolute screen coords.
//
// Refreshed on every focus the cycler performs. Cleared on stop.
// Production reads via `AXUIElementRectProvider` (AX
// `kAXFocusedWindowAttribute` + `kAXPositionAttribute` + `kAXSizeAttribute`,
// plus a `kAXMinimizedAttribute` filter — a minimized window returns nil
// so the gating defaults to "no tracked rect here" and the safety monitor
// behaves as if the window doesn't exist).
//
// Coord system: AX returns top-left-origin screen coords. The tracker
// stores them as-is. Callers comparing against `NSEvent.mouseLocation`
// (which is bottom-left) must flip y before calling `contains(point:)`.

import ApplicationServices
import CoreGraphics
import Foundation

/// DI seam over AX reads. Production uses `AXUIElementRectProvider`;
/// tests use a static fake.
public protocol AXRectProvider: Sendable {
    /// Return the rect (top-left origin, screen coords) of the focused
    /// window of the app with the given pid. nil if AX can't read it
    /// (app gone, window minimized, AX permission missing, or any other
    /// read failure).
    func focusedWindowRect(pid: pid_t) -> CGRect?
}

public actor WindowRectTracker {

    public static let shared = WindowRectTracker(provider: AXUIElementRectProvider())

    private let provider: AXRectProvider
    private var rects: [pid_t: CGRect] = [:]

    public init(provider: AXRectProvider) {
        self.provider = provider
    }

    /// Re-read the focused window's rect for `pid` and update the cache.
    /// If the provider returns nil (window minimized / app gone / AX
    /// failed), the pid is dropped from the cache — the safety monitor
    /// will default to "no tracked rect" for it on the next mouseMoved.
    public func refresh(pid: pid_t) {
        if let rect = provider.focusedWindowRect(pid: pid) {
            rects[pid] = rect
        } else {
            rects.removeValue(forKey: pid)
        }
    }

    /// Cached lookup. Returns nil if pid is unknown or last refresh
    /// returned nil.
    public func rect(for pid: pid_t) -> CGRect? {
        rects[pid]
    }

    /// Returns the pid whose cached rect contains `point`, or nil if
    /// the point is outside every tracked rect. Multi-rect overlap is
    /// not expected (each Roblox window has its own pid + non-overlapping
    /// rect under normal use); first match wins if it ever happens.
    public func contains(point: CGPoint) -> pid_t? {
        for (pid, rect) in rects where rect.contains(point) {
            return pid
        }
        return nil
    }

    /// Currently-tracked pids. Used by the focus-theft observer to
    /// distinguish "moved to a Roblox window we're cycling" from
    /// "Safari took focus."
    public func currentPids() -> [pid_t] {
        Array(rects.keys)
    }

    /// Drop a single pid from the cache. Called when the cycler hits
    /// `WindowFocuserError.notRunning` for that target.
    public func forget(pid: pid_t) {
        rects.removeValue(forKey: pid)
    }

    /// Clear everything. Called on cycler stop.
    public func reset() {
        rects.removeAll()
    }
}

/// Production conformance — reads the focused window via AX. The pid is
/// expected to be valid (cycler has just successfully focused it); a
/// dead pid returns nil cleanly via AX's own error path.
public struct AXUIElementRectProvider: AXRectProvider {

    public init() {}

    public func focusedWindowRect(pid: pid_t) -> CGRect? {
        let appElement = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        let getRes = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowRef
        )
        guard getRes == .success, let window = windowRef else { return nil }
        // Force-cast safe — AXUIElementCopyAttributeValue returns an
        // AXUIElement for window-typed attributes per Apple docs.
        let windowEl = window as! AXUIElement

        // Filter minimized — a minimized window's rect is technically
        // valid but the cursor will never legitimately be "inside" it
        // from the user's perspective. Drop it.
        var minimizedRef: AnyObject?
        let minRes = AXUIElementCopyAttributeValue(
            windowEl,
            kAXMinimizedAttribute as CFString,
            &minimizedRef
        )
        if minRes == .success, let minimized = minimizedRef as? Bool, minimized {
            return nil
        }

        var positionRef: AnyObject?
        var sizeRef: AnyObject?
        let posRes = AXUIElementCopyAttributeValue(
            windowEl,
            kAXPositionAttribute as CFString,
            &positionRef
        )
        let sizeRes = AXUIElementCopyAttributeValue(
            windowEl,
            kAXSizeAttribute as CFString,
            &sizeRef
        )
        guard posRes == .success, sizeRes == .success,
              let posValue = positionRef, let sizeValue = sizeRef else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        let posOK = AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        let sizeOK = AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        guard posOK, sizeOK else { return nil }

        return CGRect(origin: position, size: size)
    }
}
