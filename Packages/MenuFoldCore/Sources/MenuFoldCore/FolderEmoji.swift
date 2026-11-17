import Foundation

/// A folder's symbol may be an emoji, stored as `"emoji:<text>"` (the app draws it as text).
public enum FolderEmoji {
    public static let prefix = "emoji:"

    /// The text when `text` (after trimming) is exactly one emoji grapheme (flags, ZWJ sequences,
    /// skin tones and keycaps included); nil for anything else, e.g. letters, digits, two emoji.
    public static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let first = trimmed.first else { return nil }
        let scalars = first.unicodeScalars
        let isEmoji = scalars.contains { s in
            s.properties.isEmojiPresentation
                || (s.properties.isEmoji && s.value >= 0x203C)
                || s.value == 0xFE0F
                || s.value == 0x20E3
        }
        return isEmoji ? String(first) : nil
    }

    /// Stored form, or nil when `text` is not a single emoji.
    public static func symbol(for text: String) -> String? {
        normalized(text).map { prefix + $0 }
    }
}

extension GridModel {
    /// Sets an arbitrary emoji as a manual or Finder folder's symbol, keeping its colour.
    /// Returns false (and changes nothing) when `text` is not exactly one emoji.
    @discardableResult
    public func setFolderEmoji(folder folderID: UUID, to text: String) -> Bool {
        guard let symbol = FolderEmoji.symbol(for: text), let current = folder(id: folderID) else { return false }
        setStyle(folder: folderID, color: current.color, symbol: symbol)
        return true
    }
}
