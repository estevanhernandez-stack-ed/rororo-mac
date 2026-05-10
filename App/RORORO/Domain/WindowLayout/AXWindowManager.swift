// AXWindowManager.swift
// Domain — DI seam for AX window-attribute reads/writes (Slope D wave 1,
// ADR 0005). Wraps `AXUIElementSetAttributeValue` against `kAXPosition`
// + `kAXSize` so the layout view-model never touches ApplicationServices
// directly. Mirrors the `WindowFocuser` protocol shape from Slope C.
//
// Reuses the existing Accessibility TCC bucket — no new permission ask.
// If TCC is missing the AX calls return `.cannotComplete`; callers route
// through `AutoKeysPermissions.openAccessibilitySettings()` (same as the
// cycler's preflight).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public protocol AXWindowManager: Sendable {
    /// Read the current frame of the app's main window.
    func mainWindowFrame(pid: pid_t) async throws -> CGRect

    /// Move + resize the app's main window. The two attribute writes are
    /// distinct AX calls; either may fail independently. We attempt both
    /// and only throw if BOTH fail (one-of-two success is still useful).
    func resize(pid: pid_t, to frame: CGRect) async throws
}

public enum AXWindowManagerError: Error, Equatable {
    case notRunning(pid: pid_t)
    case noMainWindow(pid: pid_t)
    case axCallFailed(code: Int32)
}

public struct DefaultAXWindowManager: AXWindowManager {

    public init() {}

    public func mainWindowFrame(pid: pid_t) async throws -> CGRect {
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AXWindowManagerError.notRunning(pid: pid)
        }
        let app = AXUIElementCreateApplication(pid)
        let window = try copyMainWindow(of: app, pid: pid)

        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let pos = posValue, let size = sizeValue else {
            throw AXWindowManagerError.axCallFailed(code: max(posErr.rawValue, sizeErr.rawValue))
        }
        var origin = CGPoint.zero
        var dim = CGSize.zero
        // AXValueGetValue copies the underlying point/size out of the AXValue wrapper.
        AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &dim)
        return CGRect(origin: origin, size: dim)
    }

    public func resize(pid: pid_t, to frame: CGRect) async throws {
        guard NSRunningApplication(processIdentifier: pid) != nil else {
            throw AXWindowManagerError.notRunning(pid: pid)
        }
        let app = AXUIElementCreateApplication(pid)
        let window = try copyMainWindow(of: app, pid: pid)

        var origin = frame.origin
        var size = frame.size
        // AXValueCreate wraps point/size into the AXValue type the AX
        // attribute setter expects. Force-unwrap is safe — both
        // .cgPoint / .cgSize are documented-supported variants.
        let posValue = AXValueCreate(.cgPoint, &origin)!
        let sizeValue = AXValueCreate(.cgSize, &size)!

        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        // One-of-two success is acceptable (some Roblox windows resist
        // size-set during early load but accept position-set, and vice
        // versa). Throw only if BOTH failed.
        if posErr != .success && sizeErr != .success {
            NSLog("[RORORO] layout: pid=\(pid) resize failed pos=\(posErr.rawValue) size=\(sizeErr.rawValue)")
            throw AXWindowManagerError.axCallFailed(code: max(posErr.rawValue, sizeErr.rawValue))
        }
    }

    // MARK: - private

    private func copyMainWindow(of app: AXUIElement, pid: pid_t) throws -> AXUIElement {
        var window: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            app, kAXMainWindowAttribute as CFString, &window
        )
        guard err == .success, let w = window else {
            if err == .cannotComplete || err == .apiDisabled {
                throw AXWindowManagerError.axCallFailed(code: err.rawValue)
            }
            throw AXWindowManagerError.noMainWindow(pid: pid)
        }
        // Force-cast is safe — kAXMainWindowAttribute returns AXUIElement
        // per Apple docs (matches WindowFocuser.swift pattern).
        return w as! AXUIElement
    }
}
