// MonotonicClock.swift
// Domain — DI seam over `CACurrentMediaTime()` for inter-action `dt`
// measurement in `ActionStreamRecorder` (ADR 0007 Decision 8). The
// recorder must not use wallclock — NTP jumps, sleep, DST shifts can
// inject a negative or huge dt into the middle of a recording.
//
// Production: `CACurrentMediaClock` reads `CACurrentMediaTime()` —
// monotonic, immune to wallclock skew, already used elsewhere in the
// cycler's loop-timing path.
//
// Tests: `FakeMonotonicClock` returns controllable values so dt
// arithmetic is verifiable in isolation.

import Foundation
import QuartzCore

public protocol MonotonicClock: Sendable {
    func now() -> TimeInterval
}

public struct CACurrentMediaClock: MonotonicClock {
    public init() {}
    public func now() -> TimeInterval { CACurrentMediaTime() }
}
