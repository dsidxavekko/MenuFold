import CryptoKit
import Foundation

/// A copied picture: the PNG to put back on the pasteboard, a small thumbnail for the row and the
/// pixel size. Memory only, like the texts. Two copies of the same picture share a `digest`.
public struct ClipboardImage: Hashable, Sendable {
    public let data: Data
    public let thumbnail: Data
    public let width: Int
    public let height: Int
    public let digest: String

    public init(data: Data, thumbnail: Data, width: Int, height: Int) {
        self.data = data
        self.thumbnail = thumbnail
        self.width = width
        self.height = height
        self.digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes held in memory for this picture.
    var byteCount: Int { data.count + thumbnail.count }
}

/// One copied text or picture in the clipboard history.
public struct ClipboardEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var text: String
    public var image: ClipboardImage?
    public var date: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), text: String, date: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.image = nil
        self.date = date
        self.isPinned = isPinned
    }

    public init(id: UUID = UUID(), image: ClipboardImage, date: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = ""
        self.image = image
        self.date = date
        self.isPinned = isPinned
    }

    /// First non-empty line, trimmed and cut, for a one-line row ("Зображення 800×600" for a picture).
    public var preview: String {
        if let image { return "\(L("Зображення")) \(image.width)×\(image.height)" }
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
    /// A picture bigger than this (PNG bytes) is not recorded.
    public static let maxImageBytes = 10_000_000
    /// All unpinned pictures together stay under this; the oldest go first.
    public static let maxTotalImageBytes = 48_000_000

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
        return record(ClipboardEntry(text: text, date: date)) { $0.image == nil && $0.text == text }
    }

    /// Records a copied picture (the same rules as for text, by `digest`); one over `maxImageBytes`
    /// is ignored.
    @discardableResult
    public mutating func add(image: ClipboardImage, date: Date = Date()) -> Bool {
        guard !image.data.isEmpty, image.data.count <= Self.maxImageBytes else { return false }
        return record(ClipboardEntry(image: image, date: date)) { $0.image?.digest == image.digest }
    }

    private mutating func record(_ entry: ClipboardEntry, matching same: (ClipboardEntry) -> Bool) -> Bool {
        if let index = entries.firstIndex(where: same) {
            // Pinned entries keep their place; an unpinned one already on top is not a change.
            if entries[index].isPinned { entries[index].date = entry.date; return true }
            if index == firstUnpinnedIndex { entries[index].date = entry.date; return false }
            var moved = entries.remove(at: index)
            moved.date = entry.date
            entries.insert(moved, at: firstUnpinnedIndex)
            return true
        }
        entries.insert(entry, at: firstUnpinnedIndex)
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
    /// A picture matches by its label ("Зображення 800×600") or the words "image" / "picture".
    public func filtered(_ query: String) -> [ClipboardEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return entries.filter { entry in
            if entry.image != nil {
                return entry.preview.range(of: q, options: options) != nil
                    || "image picture png".range(of: q, options: options) != nil
            }
            return entry.text.range(of: q, options: options) != nil
        }
    }

    private var firstUnpinnedIndex: Int { entries.firstIndex { !$0.isPinned } ?? entries.count }

    private static func ordered(_ list: [ClipboardEntry]) -> [ClipboardEntry] {
        list.filter(\.isPinned) + list.filter { !$0.isPinned }
    }

    private mutating func trim() {
        let unpinned = entries.indices.filter { !entries[$0].isPinned }
        if unpinned.count > limit { entries.removeSubrange(unpinned[limit]...) }
        trimImages()
    }

    /// Drops the oldest unpinned pictures while they take more than `maxTotalImageBytes`.
    private mutating func trimImages() {
        var total = entries.reduce(0) { $0 + (!$1.isPinned ? ($1.image?.byteCount ?? 0) : 0) }
        var index = entries.count - 1
        while total > Self.maxTotalImageBytes, index >= 0 {
            if !entries[index].isPinned, let image = entries[index].image {
                total -= image.byteCount
                entries.remove(at: index)
            }
            index -= 1
        }
    }
}
