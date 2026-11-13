import AppKit
import Foundation

extension GridModel {
    /// Search results for a non-empty, trimmed query (called by `items(tab:query:)`). Ranked, not
    /// alphabetical: see `SearchMatcher`. Folders (manual + Finder) whose name matches come as
    /// `.folder` items; apps inside folders are found too. Hidden apps never appear.
    ///
    /// Order: match score, then usage (`usage.score`), then name. Return in the search field
    /// launches the first app, so the best match must come first.
    func searchItems(query: String) -> [GridItem] {
        let q = SearchMatcher.Query(query)
        guard !q.isEmpty else { return [] }
        let date = now()
        var ranked: [(item: GridItem, score: Double, usage: Double)] = []
        for app in visibleApps {
            guard let s = app.searchScore(q) else { continue }
            ranked.append((.app(app), s, usage.score(of: app.id, at: date)))
        }
        for folder in allFolders {
            guard let s = SearchMatcher.score(folder.name, q) else { continue }
            let folderApps = apps(in: folder)
            guard !folderApps.isEmpty else { continue }
            // A folder is as "used" as its most used app.
            let used = folderApps.map { usage.score(of: $0.id, at: date) }.max() ?? 0
            ranked.append((.folder(folder, apps: folderApps), s, used))
        }
        ranked.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.usage != rhs.usage { return lhs.usage > rhs.usage }
            let r = lhs.item.title.localizedStandardCompare(rhs.item.title)
            return r == .orderedSame ? lhs.item.id < rhs.item.id : r == .orderedAscending
        }
        return ranked.map(\.item)
    }

    /// Tabs (system/custom categories, "Запущені", "Недавні") whose title matches the current query,
    /// shown as chips above the results; empty for an empty query. Best match first, ties in tab order.
    public var matchingTabs: [GridTab] {
        let q = SearchMatcher.Query(query)
        guard !q.isEmpty else { return [] }
        let scored = availableTabs.enumerated().compactMap { offset, tab -> (GridTab, Double, Int)? in
            let title: String
            switch tab {
            case .all: return nil
            case .running: title = L("Запущені")
            case .recent: title = L("Недавні")
            case .category(let c): title = c.displayName
            }
            return SearchMatcher.score(title, q).map { (tab, $0, offset) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    /// System Settings panes matching the current query (empty for an empty query), shown in a
    /// section under the app results. Needs at least two characters (one letter matches half the
    /// catalog), at most `settingsPaneLimit`, best first.
    public var settingsPaneResults: [SystemSettingsPane] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        let q = SearchMatcher.Query(trimmed)
        let scored = SystemSettingsPane.catalog.enumerated().compactMap { offset, entry -> (SystemSettingsPane, Double, Int)? in
            SearchMatcher.bestScore(entry.searchTexts, q).map { (entry.pane, $0, offset) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(Self.settingsPaneLimit).map(\.0)
    }

    /// Most System Settings results shown at once.
    static var settingsPaneLimit: Int { 8 }

    /// Opens the pane in System Settings and calls `onLaunched` (the panel closes), unless the user
    /// keeps the panel open after launching (`keepsPanelOpenAfterLaunch`).
    public func openSettingsPane(_ pane: SystemSettingsPane) {
        NSWorkspace.shared.open(pane.url)
        if !keepsPanelOpenAfterLaunch { onLaunched?() }
    }
}
