import Foundation

public enum MoveDirection: Sendable {
    case up, down, left, right
}

/// Arrow-key movement over a grid made of consecutive sections (e.g. the "Часті" row, then the
/// main grid). Each section starts on a new row and is laid out `columns` per row.
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
        var starts: [Int] = []
        var acc = 0
        for c in counts { starts.append(acc); acc += c }
        guard let section = counts.indices.last(where: { counts[$0] > 0 && starts[$0] <= index }) else { return index }
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
}
