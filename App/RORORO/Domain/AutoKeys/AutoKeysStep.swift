// AutoKeysStep.swift
// Domain — single keystroke + delay-after for the auto-keys cycler (Slope C).
//
// Stores a macOS virtual keyCode (49 = spacebar, 18-29 = number row, etc.)
// rather than a character, so the captured intent survives a keyboard
// layout change. `delayAfter` is how long the cycler sleeps before
// advancing to the next step in the sequence; the on-disk shape is
// always seconds in `TimeInterval`. The sec/min unit toggle is a
// recorder-UI concern that converts to seconds before saving.
//
// Codable shape lives inside `Account.autoKeys`.

import CoreGraphics
import Foundation

public struct AutoKeysStep: Codable, Equatable, Sendable {
    public let keyCode: CGKeyCode
    public let delayAfter: TimeInterval

    public init(keyCode: CGKeyCode, delayAfter: TimeInterval) {
        self.keyCode = keyCode
        self.delayAfter = delayAfter
    }

    /// The "keep me alive" default — spacebar with the given delay-after.
    /// Spacebar is virtual keyCode 49 on every macOS layout.
    public static func spacebar(after delay: TimeInterval = 0) -> AutoKeysStep {
        AutoKeysStep(keyCode: 49, delayAfter: delay)
    }
}
