import Foundation

/// One copied text in the clipboard history.
public struct ClipboardEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var date: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), text: String, date: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.isPinned = isPinned
    }

    /// First non-empty line, trimmed and cut, for a one-line row.
    public var preview: String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

/// Recent copied texts, newest first, pinned ones in front. Memory only: it is never written to
/// disk, because the clipboard often holds secrets.
public struct ClipboardHistory: Equatable, Sendable {
    public static let defaultLimit = 50
    /// Longer texts are not recorded (a copied file's contents or a log dump).
    public static let maxLength = 100_000

    public private(set) var entries: [ClipboardEntry] = []
    public var limit: Int { didSet { trim() } }

    public init(limit: Int = ClipboardHistory.defaultLimit) {
        self.limit = max(1, limit)
    }

    /// Records a copy. Blank or oversized text is ignored; a text already in the list moves to the
    /// top (keeping its pin). Returns true when the list changed.
    @discardableResult
    public mutating func add(_ text: String, date: Date = Date()) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maxLength else { return false }
        if let index = entries.firstIndex(where: { $0.text == text }) {
            // Pinned entries keep their place; an unpinned one already on top is not a change.
            if entries[index].isPinned { entries[index].date = date; return true }
            if index == firstUnpinnedIndex { entries[index].date = date; return false }
            var entry = entries.remove(at: index)
            entry.date = date
            entries.insert(entry, at: firstUnpinnedIndex)
            return true
        }
        entries.insert(ClipboardEntry(text: text, date: date), at: firstUnpinnedIndex)
        trim()
        return true
    }

    public mutating func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Pins keep an entry at the top and out of the limit.
    public mutating func togglePin(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        var entry = entries.remove(at: index)
        entry.isPinned.toggle()
        entries.insert(entry, at: entry.isPinned ? 0 : firstUnpinnedIndex)
        entries = Self.ordered(entries)
    }

    /// Removes everything except pinned entries.
    public mutating func clear() {
        entries.removeAll { !$0.isPinned }
    }

    /// Entries whose text contains `query` (case and diacritics insensitive); all for a blank query.
    public func filtered(_ query: String) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var firstUnpinnedIndex: Int { entries.firstIndex { !$0.isPinned } ?? entries.count }

    private static func ordered(_ list: [ClipboardEntry]) -> [ClipboardEntry] {
        list.filter(\.isPinned) + list.filter { !$0.isPinned }
    }

    private mutating func trim() {
        let unpinned = entries.indices.filter { !entries[$0].isPinned }
        guard unpinned.count > limit else { return }
        entries.removeSubrange(unpinned[limit]...)
    }
}
