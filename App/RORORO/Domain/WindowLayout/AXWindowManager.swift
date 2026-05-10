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
    /// Position-set succeeded but size-set was rejected. Common for
    /// windows in macOS fullscreen — caller surfaces a "switch Roblox
    /// out of fullscreen" hint to the user.
    case sizeSetRejected(pid: pid_t, fullScreen: Bool)
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

        // Some Roblox windows are in fullscreen / borderless-windowed
        // mode and AX rejects size-set with .cannotComplete (-25204) or
        // .notImplemented (-25212). Check kAXFullScreenAttribute first
        // so we can warn instead of silently moving without shrinking.
        var isFullScreenObj: AnyObject?
        let fsErr = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &isFullScreenObj)
        let isFullScreen = (fsErr == .success) && ((isFullScreenObj as? Bool) == true)
        if isFullScreen {
            NSLog("[RORORO] layout: pid=\(pid) is in macOS fullscreen — resize will be rejected")
        }

        let posErr = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
        let sizeErr = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)

        // Per-call logging so a partial-success (pos lands but size
        // rejected) is visible in Console.app, not silently swallowed.
        if posErr != .success {
            NSLog("[RORORO] layout: pid=\(pid) pos-set err=\(posErr.rawValue)")
        }
        if sizeErr != .success {
            NSLog("[RORORO] layout: pid=\(pid) size-set err=\(sizeErr.rawValue) fullscreen=\(isFullScreen)")
        }

        // Throw if BOTH failed; partial success (pos OR size) is acceptable
        // but the caller should know if size specifically failed so it can
        // route a useful warning to the user.
        if posErr != .success && sizeErr != .success {
            throw AXWindowManagerError.axCallFailed(code: max(posErr.rawValue, sizeErr.rawValue))
        }
        if sizeErr != .success {
            throw AXWindowManagerError.sizeSetRejected(pid: pid, fullScreen: isFullScreen)
        }

        // Silent-revert detection. Some apps (Roblox in particular)
        // return `.success` from size-set but the actual window size
        // doesn't change — either an internal min-size clamp or a
        // render-pipeline-bound dimension that doesn't honor AX. Read
        // the size back and compare; if it diverges from what we asked
        // for by more than a few px (anti-rounding), surface it.
        var actualSizeObj: AnyObject?
        let readErr = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &actualSizeObj)
        if readErr == .success, let raw = actualSizeObj {
            var actual = CGSize.zero
            AXValueGetValue(raw as! AXValue, .cgSize, &actual)
            let widthDelta = abs(actual.width - frame.size.width)
            let heightDelta = abs(actual.height - frame.size.height)
            if widthDelta > 5 || heightDelta > 5 {
                // Also probe the AX min-size so we know whether Roblox
                // is clamping to a documented minimum (then we can adapt
                // and clamp on our side) vs render-engine-bound (which
                // needs a different workaround).
                var minSizeStr = "unknown"
                var minObj: AnyObject?
                if AXUIElementCopyAttributeValue(window, "AXMinValue" as CFString, &minObj) == .success,
                   let raw = minObj {
                    var minS = CGSize.zero
                    AXValueGetValue(raw as! AXValue, .cgSize, &minS)
                    minSizeStr = "\(minS)"
                }
                NSLog("[RORORO] layout: pid=\(pid) size silently reverted — asked \(frame.size), got \(actual) min=\(minSizeStr) fullscreen=\(isFullScreen)")
                throw AXWindowManagerError.sizeSetRejected(pid: pid, fullScreen: isFullScreen)
            }
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
