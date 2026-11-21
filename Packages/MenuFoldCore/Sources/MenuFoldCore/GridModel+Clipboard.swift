import Foundation

/// Keyboard access to the clipboard tab. While it is the current tab the search field filters the
/// history (`clipboard.filtered(query)`) instead of searching apps, and the arrow keys move
/// `clipboardSelectedID` through the visible rows.
extension GridModel {
    /// The rows of the clipboard tab for the current query.
    public var clipboardEntries: [ClipboardEntry] { clipboard.filtered(query) }

    /// The picked row, only while it is still shown.
    public var selectedClipboardEntry: ClipboardEntry? {
        guard let id = clipboardSelectedID else { return nil }
        return clipboardEntries.first { $0.id == id }
    }

    /// ↓ / ↑: from nothing, ↓ picks the first row and ↑ the last; the ends do not wrap.
    public func moveClipboardSelection(by step: Int) {
        let entries = clipboardEntries
        guard !entries.isEmpty else { clipboardSelectedID = nil; return }
        guard let current = clipboardSelectedID.flatMap({ id in entries.firstIndex { $0.id == id } }) else {
            clipboardSelectedID = (step >= 0 ? entries.first : entries.last)?.id
            return
        }
        clipboardSelectedID = entries[min(max(current + step, 0), entries.count - 1)].id
    }

    /// What Return puts back: the picked row, else (typing in the search field) the first match.
    public var clipboardEntryToUse: ClipboardEntry? {
        selectedClipboardEntry ?? (query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : clipboardEntries.first)
    }

    /// ⌘D on the picked row. The row keeps being picked (pinning moves it to the front).
    @discardableResult
    public func togglePinOnClipboardSelection() -> Bool {
        guard let entry = selectedClipboardEntry else { return false }
        clipboard.togglePin(id: entry.id)
        return true
    }

    /// ⌘⌫ on the picked row; the pick moves to the neighbour so deleting several in a row works.
    @discardableResult
    public func removeClipboardSelection() -> Bool {
        let entries = clipboardEntries
        guard let entry = selectedClipboardEntry, let index = entries.firstIndex(where: { $0.id == entry.id }) else {
            return false
        }
        clipboard.remove(id: entry.id)
        let rest = clipboardEntries
        clipboardSelectedID = rest.isEmpty ? nil : rest[min(index, rest.count - 1)].id
        return true
    }
}
