// LayoutMode.swift
// Domain — what the WindowLayoutPlanner is being asked to compute.
// Three shapes: explicit grid (cols × rows specified), auto-grid
// (ceil(sqrt(N)) packing), and shrink (per-window center-anchored
// proportional resize). See ADR 0005 Decisions 4 + 5.

import Foundation

public enum LayoutMode: Equatable, Sendable {
    /// Explicit grid. cols × rows cells; row-major fill from top-left.
    case grid(cols: Int, rows: Int)

    /// Automatic ceil(sqrt(N)) packing. Planner computes cols/rows
    /// from the window count.
    case autoGrid

    /// Per-window center-anchored shrink. `percent` is 0.0–1.0
    /// (0.5 = half size). Each window stays centered on its current
    /// center; only width × height change.
    case shrink(percent: Double)
}
