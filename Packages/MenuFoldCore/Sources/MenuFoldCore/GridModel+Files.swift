import AppKit
import Foundation

// MARK: - Files and documents in the panel

/// The files part of the search: when a query asks for files at all, the debounce before a
/// `FileSearching` is asked, which answer may land, and what Enter/⌘R do with a picked row.
///
/// `FileSearch` (FileSearch.swift) owns the meaning of a file query and the ranking; the app
/// supplies the provider (`SpotlightFileSearchProvider`) that only reads the local Spotlight index.
/// This extension owns the timing, so the views have nothing to decide and the tests can drive it
/// with a fake provider.
extension GridModel {
    /// Plain (unprefixed) queries shorter than this never ask for files: one or two letters match
    /// thousands of names, so every keystroke would start a Spotlight query. The `~`/`file:` prefix
    /// is an explicit request and needs no minimum.
    static var fileQueryMinimumLength: Int { 3 }

    /// Prefix of a file row's selection id, so files share `selectedItemID` with apps and folders.
    static let fileSelectionPrefix = "file:"

    /// Selection id of a file row: "file:<path>", the id of its tile and of `selectedItemID`.
    public static func fileSelectionID(_ path: String) -> String { fileSelectionPrefix + path }

    /// Text the current query hands to the provider, nil when the panel must not offer files at all:
    /// the switch is off (no Spotlight queries, from any prefix), a folder is open, the clipboard tab
    /// is showing (there the field filters the copied texts), the query uses an app prefix, or a
    /// plain query is shorter than `fileQueryMinimumLength`.
    var fileQueryText: String? {
        guard searchesFiles, openFolderID == nil, tab != .clipboard else { return nil }
        let (scope, text) = Self.parseSearch(query)
        switch scope {
        case .files:
            // A bare "~" is a valid scope but asks for nothing: `FileSearch.rank` gives no rows for
            // an empty query, and showing "the latest files" would be a guess this panel never makes.
            return text.isEmpty ? nil : text
        case .everything:
            return text.count >= Self.fileQueryMinimumLength ? text : nil
        default:
            return nil
        }
    }

    /// The file row under the keyboard selection. `selectedItemID` is shared with apps and folders,
    /// so the "file:" prefix is what tells the sections apart.
    public var selectedFile: FileItem? {
        guard let id = selectedItemID, id.hasPrefix(Self.fileSelectionPrefix) else { return nil }
        let path = String(id.dropFirst(Self.fileSelectionPrefix.count))
        return fileResults.first { $0.id == path }
    }

    /// Opens a file with its default app and calls `onLaunched` (the panel closes), unless the user
    /// keeps the panel open after launching (`keepsPanelOpenAfterLaunch`). No usage is recorded: the
    /// "Часті" row and the statistics are about apps MenuFold launches.
    public func openFile(_ file: FileItem) {
        NSWorkspace.shared.open(file.url)
        if !keepsPanelOpenAfterLaunch { onLaunched?() }
    }

    /// Shows the file in a Finder window (⌘R on a selected document).
    public func revealFile(_ file: FileItem) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    // MARK: Search timing

    /// Re-plans the file search for the current query. Called from every state that decides what the
    /// query means (`query`, `tab`, `openFolderID`, `searchesFiles`, the provider itself), so a query
    /// that stops asking for files also drops the rows it left on screen.
    ///
    /// The previous search is cancelled and its generation retired, so a slow answer that lands after
    /// the field moved on cannot put its files back. Rows of the same text survive a re-plan (the
    /// switch was flipped back, the provider was attached late): a search never blinks when it
    /// repeats itself.
    func fileQueryDidChange() {
        let text = fileQueryText
        if text != fileSearchText {
            fileResults = []
            fileSearchText = text
        }
        // A narrower kind drops the rows that no longer fit at once; the answer then refills them.
        if let kind = FileSearchQuery.parseDetailed(query).kind { fileResults = fileResults.filter { kind.matches($0.url) } }
        fileSearchTask?.cancel()
        fileSearchTask = nil
        // Every plan retires the answers still in flight, even one for the same text.
        fileSearchGeneration += 1
        guard let text, let provider = fileSearchProvider else {
            isSearchingFiles = false
            return
        }
        let generation = fileSearchGeneration
        // A kind filter is applied after the fact, so the provider is asked for the most it may give.
        let askLimit = FileSearchQuery.parseDetailed(query).kind == nil ? FileSearch.defaultLimit : FileSearch.maxLimit
        let delay = fileSearchDelay
        isSearchingFiles = true
        fileSearchTask = Task { @MainActor [weak self] in
            // Typing "report" must cost one query, not six: the debounce is the point of this task.
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            let items = await provider.searchFiles(matching: text, limit: askLimit)
            guard !Task.isCancelled else { return }
            self?.applyFileResults(items, for: text, generation: generation)
        }
    }

    /// Takes one answer from the provider. Only the newest query may replace the rows: the
    /// generation and the text both have to match, so an answer that a newer search overtook while
    /// it was still gathering stops here. Ranking is the model's (`FileSearch.rank`), so a provider
    /// that ignores its limit or hands back unsorted or non-candidate hits still cannot fill the
    /// panel with the wrong files.
    func applyFileResults(_ items: [FileItem], for text: String, generation: Int) {
        guard generation == fileSearchGeneration, text == fileSearchText, text == fileQueryText else { return }
        isSearchingFiles = false
        fileResults = FileSearch.rank(items.filter(FileSearch.isCandidate), query: text,
                                      limit: FileSearch.defaultLimit,
                                      kind: FileSearchQuery.parseDetailed(query).kind)
        clearSelectionIfGone()
    }
}
