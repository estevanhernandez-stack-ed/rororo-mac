// WindowLayoutPlanner.swift
// Domain — pure value type. Computes target CGRect frames for a set of
// pids given a LayoutMode, a visible-rect (NSScreen.visibleFrame),
// and the windows' current frames. No I/O, no AppKit dependency —
// fully unit-testable. See ADR 0005 Decisions 4 + 5 for math.

import CoreGraphics
import Foundation

public struct WindowLayoutPlanner {

    public static func plan(
        mode: LayoutMode,
        pids: [pid_t],
        visibleRect: CGRect,
        currentFrames: [pid_t: CGRect]
    ) -> [pid_t: CGRect] {
        guard !pids.isEmpty else { return [:] }
        let sorted = pids.sorted()  // stable ordering by pid

        switch mode {
        case .autoGrid:
            let n = sorted.count
            let cols = Int(ceil(Double(n).squareRoot()))
            let rows = Int(ceil(Double(n) / Double(cols)))
            return gridFrames(pids: sorted, cols: cols, rows: rows, in: visibleRect)

        case .grid(let cols, let rows):
            return gridFrames(pids: sorted, cols: cols, rows: rows, in: visibleRect)

        case .cascade(let offsetX, let offsetY):
            return cascadeFrames(pids: sorted, offsetX: offsetX, offsetY: offsetY, in: visibleRect, currentFrames: currentFrames)
        }
    }

    // MARK: - private

    private static func gridFrames(
        pids: [pid_t],
        cols: Int,
        rows: Int,
        in rect: CGRect
    ) -> [pid_t: CGRect] {
        guard cols > 0, rows > 0 else { return [:] }
        let cellW = rect.width  / CGFloat(cols)
        let cellH = rect.height / CGFloat(rows)
        var out: [pid_t: CGRect] = [:]
        for (i, pid) in pids.enumerated() {
            let row = i / cols
            let col = i % cols
            guard row < rows else { break }  // overflow → drop
            out[pid] = CGRect(
                x: rect.origin.x + CGFloat(col) * cellW,
                y: rect.origin.y + CGFloat(row) * cellH,
                width: cellW,
                height: cellH
            )
        }
        return out
    }

    /// Cascade — staircase arrangement. Each window keeps its current
    /// size (no AX size-set involved, so the Roblox 800x600 floor is
    /// irrelevant). Positions are offset by (offsetX, offsetY) per pid.
    /// First pid (lowest sort) lands at visibleRect.origin; each
    /// subsequent pid steps right + down. Wraps to a new "stack" when
    /// the next position would push the title bar off-screen.
    private static func cascadeFrames(
        pids: [pid_t],
        offsetX: CGFloat,
        offsetY: CGFloat,
        in rect: CGRect,
        currentFrames: [pid_t: CGRect]
    ) -> [pid_t: CGRect] {
        var out: [pid_t: CGRect] = [:]
        // Reasonable default size when we don't know the window's
        // current dimensions (e.g., external-Roblox window we can't
        // probe). 1024x768 fits most displays comfortably.
        let defaultSize = CGSize(width: 1024, height: 768)
        var cursor = rect.origin
        var stackBase = rect.origin
        for pid in pids {
            let size = currentFrames[pid]?.size ?? defaultSize
            // Wrap if cursor would push the title bar below visibleRect's
            // bottom — start a new "column" offset by 200px right of the
            // current stack base. Keeps cascades visible on tall stacks.
            if cursor.y + 60 > rect.maxY {  // 60 = approx title bar height
                stackBase.x += 200
                cursor = stackBase
            }
            out[pid] = CGRect(origin: cursor, size: size)
            cursor.x += offsetX
            cursor.y += offsetY
        }
        return out
    }
}
