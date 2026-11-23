import Foundation

public enum MoveDirection: Sendable, Equatable {
    case up, down, left, right
}

/// Arrow/Home/End/Page movement over a grid made of consecutive sections (e.g. the "Часті" row,
/// then the main grid). Each section starts on a new row and is laid out `columns` per row.
public enum GridNavigation {
    /// `index` is a flat index across all sections (section 0 first), nil when nothing is selected.
    /// - nil + any direction → the first item (nil if there are no items).
    /// - left/right move to the previous/next item, crossing rows and sections; stop at the ends.
    /// - up/down move one row, keeping the column (clamped to the last item of a shorter row),
    ///   crossing into the previous/next non-empty section; stop at the top/bottom row.
    public static func move(from index: Int?, sections: [Int], columns: Int, direction: MoveDirection) -> Int? {
        let counts = sections.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let index, index >= 0, index < total else { return 0 }
        let cols = max(1, columns)

        // Flat index → (section, index within it).
        let starts = sectionStarts(counts)
        guard let section = sectionIndex(of: index, counts: counts, starts: starts) else { return index }
        let local = index - starts[section]
        let row = local / cols, col = local % cols

        switch direction {
        case .left:
            return index > 0 ? index - 1 : index
        case .right:
            return index < total - 1 ? index + 1 : index
        case .down:
            let nextRowStart = (row + 1) * cols
            if nextRowStart < counts[section] {
                return starts[section] + min(nextRowStart + col, counts[section] - 1)
            }
            guard let next = counts.indices.first(where: { $0 > section && counts[$0] > 0 }) else { return index }
            return starts[next] + min(col, counts[next] - 1)
        case .up:
            if row > 0 { return starts[section] + (row - 1) * cols + col }
            guard let prev = counts.indices.last(where: { $0 < section && counts[$0] > 0 }) else { return index }
            let lastRowStart = (counts[prev] - 1) / cols * cols
            return starts[prev] + min(lastRowStart + col, counts[prev] - 1)
        }
    }

    /// Home: the first item of the section `index` belongs to (so the start of the "Часті" row when
    /// a tile of it is selected, not the start of the whole grid).
    /// - no selection (or an index outside the grid) → the first item of the grid, which is the first
    ///   item of the first non-empty section; nil only when every section is empty.
    public static func home(from index: Int?, sections: [Int]) -> Int? {
        let counts = sections.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let index, index >= 0, index < total else { return 0 }
        let starts = sectionStarts(counts)
        guard let section = sectionIndex(of: index, counts: counts, starts: starts) else { return 0 }
        return starts[section]
    }

    /// End: the last item of the section `index` belongs to (the end of the "Часті" row, not the end
    /// of the whole grid).
    /// - no selection (or an index outside the grid) → the last item of the grid; nil only when every
    ///   section is empty.
    public static func end(from index: Int?, sections: [Int]) -> Int? {
        let counts = sections.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let index, index >= 0, index < total else { return total - 1 }
        let starts = sectionStarts(counts)
        guard let section = sectionIndex(of: index, counts: counts, starts: starts) else { return total - 1 }
        return starts[section] + counts[section] - 1
    }

    /// PageDown (`pages` > 0) / PageUp (`pages` < 0): a flat shift of `pages × rows × columns` items
    /// over the sections in order, clamped to the first/last item. A page is a flat move on purpose:
    /// no column is tracked across a section boundary, so the shift lands where a reader of the
    /// section list expects it and never jumps out of the grid.
    /// - no selection (or an index outside the grid) → the first item, as the arrow keys do.
    public static func page(from index: Int?, sections: [Int], columns: Int, rows: Int, pages: Int) -> Int? {
        let counts = sections.map { max(0, $0) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        guard let index, index >= 0, index < total else { return 0 }
        let step = max(1, columns) * max(1, rows) * pages
        return min(max(index + step, 0), total - 1)
    }

    // MARK: Helpers

    /// Flat index of the first item of every section (an empty section still has a start).
    private static func sectionStarts(_ counts: [Int]) -> [Int] {
        var starts: [Int] = []
        var acc = 0
        for count in counts { starts.append(acc); acc += count }
        return starts
    }

    /// The non-empty section holding `index`; an index that falls on an empty section resolves to the
    /// previous non-empty one (the same rule `move` has always used).
    private static func sectionIndex(of index: Int, counts: [Int], starts: [Int]) -> Int? {
        counts.indices.last(where: { counts[$0] > 0 && starts[$0] <= index })
    }
}
