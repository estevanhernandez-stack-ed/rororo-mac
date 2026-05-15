// Domain — UI-visibility rule for per-account framerate overrides
// (ADR 0002). Pure: no SwiftUI dependency, no actor isolation. The UI
// (AccountsListView) calls `diverges(override:global:)` to choose between
// a warn-pill and the today's-subtle styling for the override badge.

import Foundation

public enum FramerateOverrideDivergence {

    /// True when a per-account framerate override should be flagged as a
    /// user-visible divergence from the global cap. Only true when the
    /// global is concretely set AND the override differs from it.
    ///
    /// - When `override` is nil, there is no override to flag → false.
    /// - When `global` is nil, the override is "your only opinion" — there
    ///   is nothing to diverge from → false.
    /// - When both are set and equal, the override is harmless (it would
    ///   apply the same value the global does) → false.
    /// - When both are set and differ, the override silently overrides
    ///   the global on launch — the trap to surface → true.
    public static func diverges(override: Int?, global: Int?) -> Bool {
        guard let override, let global else { return false }
        return override != global
    }
}
