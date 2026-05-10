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

        case .shrink(let percent):
            return shrinkFrames(pids: sorted, percent: percent, currentFrames: currentFrames)
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

    private static func shrinkFrames(
        pids: [pid_t],
        percent: Double,
        currentFrames: [pid_t: CGRect]
    ) -> [pid_t: CGRect] {
        var out: [pid_t: CGRect] = [:]
        for pid in pids {
            guard let current = currentFrames[pid] else { continue }
            let newW = current.width  * CGFloat(percent)
            let newH = current.height * CGFloat(percent)
            let centerX = current.midX
            let centerY = current.midY
            out[pid] = CGRect(
                x: centerX - newW / 2,
                y: centerY - newH / 2,
                width: newW,
                height: newH
            )
        }
        return out
    }
}
