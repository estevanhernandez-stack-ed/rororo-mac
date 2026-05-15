// RiskyFFlagPatterns.swift
// Domain — pattern-matches an FFlag name to a risk category so the FFlags
// sheet can show a non-blocking caution badge. The editor still SAVES a
// risky flag (per the design's "inform, don't block" posture, ADR 0011);
// this is purely the signal feeding the badge.
//
// The categories mirror ADR 0006's exclusion rationale: physics / network
// / simulation flags can break gameplay or trip anti-cheat in some
// titles. Match is substring-based and deliberately conservative — false
// negatives (a risky flag not flagged) are better than false positives
// (a safe flag nagged), since the badge is advisory, not a gate.

import Foundation

public enum FFlagRiskCategory: String, Sendable {
    case physics
    case network
    case simulation
}

public enum RiskyFFlagPatterns {

    /// Substring → category, checked case-insensitively against the flag
    /// name. Listed highest-severity first so it surfaces on a multi-match.
    private static let patterns: [(needle: String, category: FFlagRiskCategory)] = [
        ("physics",    .physics),
        ("raknet",     .network),
        ("network",    .network),
        ("simulation", .simulation),
        ("simradius",  .simulation),
    ]

    /// Returns the risk category for `key`, or nil when it matches no
    /// known-risky pattern. nil is NOT a safety guarantee — it means
    /// "nothing recognized," which is why the badge copy says "may be
    /// risky" rather than asserting safety.
    public static func risk(for key: String) -> FFlagRiskCategory? {
        let haystack = key.lowercased()
        for (needle, category) in patterns where haystack.contains(needle) {
            return category
        }
        return nil
    }
}
