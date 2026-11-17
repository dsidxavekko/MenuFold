import CoreGraphics

/// Which display the panel opens on.
public enum PanelScreenPolicy: String, CaseIterable, Sendable {
    /// The display under the mouse pointer (the Dock click).
    case cursor
    /// The primary display (the one with the menu bar).
    case primary
    /// The display holding the frontmost app's main window.
    case activeWindow
}

/// Pure display-placement rules, free of AppKit so they can be unit-tested. Rects use one shared
/// coordinate space (the caller converts window bounds to Cocoa screen coordinates first).
public enum DisplayPlacement {
    /// Index into `screenFrames` of the display to use, or nil when there are no screens.
    /// `activeWindowFrame` is the frontmost app's window; with no window (or no overlap) the pointer decides.
    public static func screenIndex(
        policy: PanelScreenPolicy, screenFrames: [CGRect], primaryIndex: Int = 0,
        cursor: CGPoint, activeWindowFrame: CGRect? = nil
    ) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        let primary = screenFrames.indices.contains(primaryIndex) ? primaryIndex : 0
        switch policy {
        case .primary:
            return primary
        case .cursor:
            return indexContaining(cursor, in: screenFrames) ?? primary
        case .activeWindow:
            if let window = activeWindowFrame, let i = largestOverlap(window, in: screenFrames) { return i }
            return indexContaining(cursor, in: screenFrames) ?? primary
        }
    }

    /// First screen containing `point`, inclusive on every edge with 1 pt of slack.
    static func indexContaining(_ point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex {
            point.x >= $0.minX - 1 && point.x <= $0.maxX + 1 && point.y >= $0.minY - 1 && point.y <= $0.maxY + 1
        }
    }

    /// Screen sharing the largest area with `rect`; nil if it overlaps none.
    static func largestOverlap(_ rect: CGRect, in frames: [CGRect]) -> Int? {
        var best: (index: Int, area: CGFloat)?
        for (i, frame) in frames.enumerated() {
            let r = frame.intersection(rect)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let area = r.width * r.height
            if best == nil || area > best!.area { best = (i, area) }
        }
        return best?.index
    }

    /// Largest grid (≤ the wanted columns × rows) whose panel fits `available` (the screen's visible
    /// size minus margins). The panel is `baseWidth + (columns - baseColumns) * tileWidth` wide and
    /// `baseHeight + (rows - baseRows) * rowHeight` high. Never below `minColumns` × `minRows`.
    public static func fittedGrid(
        columns: Int, rows: Int, available: CGSize,
        baseWidth: CGFloat = 844, baseHeight: CGFloat = 577, baseColumns: Int = 7, baseRows: Int = 4,
        tileWidth: CGFloat = 108, rowHeight: CGFloat = 116, minColumns: Int = 3, minRows: Int = 2
    ) -> (columns: Int, rows: Int) {
        var c = columns
        while c > minColumns, baseWidth + CGFloat(c - baseColumns) * tileWidth > available.width { c -= 1 }
        var r = rows
        while r > minRows, baseHeight + CGFloat(r - baseRows) * rowHeight > available.height { r -= 1 }
        return (c, r)
    }
}
