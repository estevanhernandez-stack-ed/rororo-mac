// CycleBudget.swift
// Domain — pure validator + threshold constants for the auto-keys
// cycle (Slope C). The cycler refuses to start (and bails mid-flight)
// when an estimated cycle exceeds `hardCap`. The V2 recorder reads
// `totalDuration` per sequence to surface live cap warnings on
// over-budget recordings.
//
// Per ADR 0004 Decision 4, Roblox's AFK timer is ~20 min per window;
// the cycle must revisit each window before its individual timer
// expires. `warnThreshold` is the comfortable target, `hardCap` the
// absolute ceiling.

import Foundation

public enum CycleBudget {

    public static let warnThreshold: TimeInterval = 18 * 60   // 18:00
    public static let hardCap: TimeInterval = 19 * 60         // 19:00

    /// Per-account focus cost — `NSRunningApplication.activate` + the
    /// 150ms settle, bundled. Measured estimate; bump if Roblox is
    /// slow to receive focus on busy systems.
    public static let defaultFocusOverhead: TimeInterval = 0.2

    public enum State: Equatable {
        case ok
        case warn
        case overCap
    }

    /// One full cycle: Σ(per-step delays across all sequences) +
    /// loop delay + (focus overhead × N accounts).
    public static func estimate(
        snapshot: [AutoKeysSequence],
        loopDelay: TimeInterval,
        focusOverhead: TimeInterval = defaultFocusOverhead
    ) -> TimeInterval {
        let delays = snapshot.reduce(0) { $0 + $1.totalDuration }
        let focus = focusOverhead * Double(snapshot.count)
        return delays + focus + loopDelay
    }

    public static func state(for estimated: TimeInterval) -> State {
        if estimated >= hardCap { return .overCap }
        if estimated >= warnThreshold { return .warn }
        return .ok
    }
}
