// LayoutMode.swift
// Domain — what the WindowLayoutPlanner is being asked to compute.
// Three shapes: explicit grid (cols × rows specified), auto-grid
// (ceil(sqrt(N)) packing), and cascade (staircase, position-only).
// Shrink was retracted in P2-revised — Roblox enforces a hardcoded
// 800x600 player window floor that AX size-set silently rejects, so
// shrink couldn't deliver value. Users can drag-resize manually if
// they want; what they can't do manually is auto-arrange N grinding
// windows for at-a-glance monitoring — that's what cascade is for.
// See ADR 0005 Decisions 4 + 7 (retraction).

import Foundation

public enum LayoutMode: Equatable, Sendable {
    /// Explicit grid. cols × rows cells; row-major fill from top-left.
    case grid(cols: Int, rows: Int)

    /// Automatic ceil(sqrt(N)) packing. Planner computes cols/rows
    /// from the window count.
    case autoGrid

    /// Staircase arrangement — each window offset (offsetX, offsetY)
    /// from the previous, sizes preserved. Position-only operation;
    /// no size-set involved (sidesteps the Roblox 800x600 floor).
    /// Default offset 40x40 — title-bar visible, easy to click.
    case cascade(offsetX: CGFloat = 40, offsetY: CGFloat = 40)
}
