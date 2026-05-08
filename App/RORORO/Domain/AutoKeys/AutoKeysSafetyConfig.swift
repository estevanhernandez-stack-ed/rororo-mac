// AutoKeysSafetyConfig.swift
// Domain — value types describing the cycler's safety surface (Slope C,
// ADR 0004 Decision 9). Two pieces of user choice land here:
//
//   - which key is the kill key (a single CGKeyCode the user records during
//     setup; default suggestion is F19 = keyCode 80, which most Mac
//     keyboards lack physically and so is a near-zero-collision pick),
//   - which gesture stops the cycler (hold-for-1s OR double-tap-within-600ms).
//
// The hold-vs-double-tap choice is per-user: hold is mechanically safer
// (zero false-positive risk), double-tap is faster on the user's
// muscle memory. The recorder shows both and the user picks.

import CoreGraphics
import Foundation

public enum KillGesture: Codable, Equatable, Sendable {
    /// Press and hold the kill key for `seconds` to stop the cycler.
    /// Default 1.0s. Releasing before the deadline cancels the gesture.
    case holdFor(seconds: TimeInterval)
    /// Press the kill key twice within `withinSeconds` to stop the cycler.
    /// Default 0.6s. Slower second tap resets the recognizer.
    case doubleTap(withinSeconds: TimeInterval)

    public static let defaultHold: KillGesture = .holdFor(seconds: 1.0)
    public static let defaultDoubleTap: KillGesture = .doubleTap(withinSeconds: 0.6)
}

public struct AutoKeysSafetyConfig: Codable, Equatable, Sendable {
    /// Virtual keyCode of the kill key. Default 80 (F19) — most Mac
    /// keyboards skip F19 physically, making it a near-zero-collision
    /// pick. The recorder lets the user choose any other key + warns
    /// against ones bound in Roblox.
    public let killKeyCode: CGKeyCode
    /// Gesture the user picked to trigger the kill. Either hold or
    /// double-tap; see `KillGesture`.
    public let gesture: KillGesture
    /// Grace period (seconds) after a `.userEngaged` pause before the
    /// cycler auto-resumes. Continued user input keeps extending the
    /// pause. Default 5s. ADR 0004 Decision 9.
    public let resumeGrace: TimeInterval

    public static let defaultKillKeyCode: CGKeyCode = 80 // F19

    public init(
        killKeyCode: CGKeyCode = AutoKeysSafetyConfig.defaultKillKeyCode,
        gesture: KillGesture = .defaultHold,
        resumeGrace: TimeInterval = 5.0
    ) {
        self.killKeyCode = killKeyCode
        self.gesture = gesture
        self.resumeGrace = resumeGrace
    }

    public static let `default` = AutoKeysSafetyConfig()
}

/// Events the safety monitor emits to the cycler.
public enum EngagementEvent: Equatable, Sendable {
    /// Any human input that wasn't a self-tagged cycler keystroke.
    /// The cycler responds by pausing and starting the resume-grace
    /// timer; continued input keeps extending the pause.
    case userEngaged
    /// The configured kill gesture completed (hold deadline reached, or
    /// second tap landed within the double-tap window). The cycler
    /// responds by stopping with `.stopped(.userKilled)`.
    case killRequested
}
