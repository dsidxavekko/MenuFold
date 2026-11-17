import AppKit
import Foundation

/// What a search query asks for, after its optional prefix: `>` apps only, `/` folders only,
/// `@name rest` apps of the category matching "name" (narrowed by "rest"), `?` System Settings only.
enum SearchScope: Equatable {
    case everything, apps, folders, settings
    case category(String)
}

extension GridModel {
    /// Splits a raw query into its scope and the text to match.
    static func parseSearch(_ raw: String) -> (scope: SearchScope, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func rest(_ s: Substring) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch trimmed.first {
        case ">": return (.apps, rest(trimmed.dropFirst()))
        case "/": return (.folders, rest(trimmed.dropFirst()))
        case "?": return (.settings, rest(trimmed.dropFirst()))
        case "@":
            let body = trimmed.dropFirst()
            guard let space = body.firstIndex(where: \.isWhitespace) else { return (.category(String(body)), "") }
            return (.category(String(body[..<space])), rest(body[space...]))
        default: return (.everything, trimmed)
        }
    }

    /// Folded search data of every app, built once per catalog change.
    private var searchTargets: [String: SearchMatcher.Target] {
        if let cached = searchTargetsCache { return cached }
        let map = Dictionary(apps.map { ($0.id, $0.searchTarget) }, uniquingKeysWith: { first, _ in first })
        searchTargetsCache = map
        return map
    }

    /// Whether the apps matching `query` are all among the apps that matched the previous query:
    /// the new query extends the old one (same layout reading). Needs four characters in the old
    /// one, because shorter queries match by looser rules (one letter: word starts only; bundle ID
    /// and keywords: four/three letters), so a longer query can match what they did not.
    private func canNarrow(from last: SearchMatcher.Query, to q: SearchMatcher.Query) -> Bool {
        guard last.direct.count >= 4, q.direct.hasPrefix(last.direct) else { return false }
        switch (last.converted, q.converted) {
        case (nil, nil): return true
        case let (l?, c?): return c.hasPrefix(l)
        default: return false
        }
    }

    /// Search results for a non-empty, trimmed query (called by `items(tab:query:)`). Ranked, not
    /// alphabetical: see `SearchMatcher`. Folders (manual + Finder) whose name matches come as
    /// `.folder` items; apps inside folders are found too. Hidden apps never appear.
    /// A prefix narrows the scope: see `SearchScope`.
    ///
    /// Order: match score (plus a small bonus for use and for apps chosen before after this query,
    /// never enough to leave the match tier), then usage (`usage.score`), then name. Return in the
    /// search field launches the first app, so the best match must come first.
    func searchItems(query: String) -> [GridItem] {
        let (scope, text) = Self.parseSearch(query)
        if scope == .settings { return [] }
        var categoryIDs: Set<String>?
        if case .category(let name) = scope {
            guard !name.isEmpty else { return [] }
            categoryIDs = matchingCategoryIDs(name)
        }
        if scope == .everything, Self.isUpdatesQuery(text), !availableUpdates.isEmpty {
            let withUpdates = appsWithUpdates.map { GridItem.app($0) }
            if !withUpdates.isEmpty { return withUpdates }
        }
        let q = SearchMatcher.Query(text)
        if q.isEmpty && scope == .everything { return [] }
        let date = now()
        let includesApps = scope != .folders
        let includesFolders = scope == .everything || scope == .folders

        func ranked(_ raw: Double, appIDs: [String], usageScore: Double) -> Double {
            guard !q.isEmpty else { return 0 }
            let tier = (raw / 100).rounded(.down)
            let choice = appIDs.map { searchChoices.bonus(forFoldedQuery: q.direct, appID: $0) }.max() ?? 0
            let frequency = min(log1p(usageScore) * 3, 6)
            return min(raw + choice + frequency, tier * 100 + 99)
        }

        var results: [(item: GridItem, score: Double, usage: Double)] = []
        if includesApps {
            var pool = visibleApps
            if !q.isEmpty, let last = lastSearchMatch, canNarrow(from: last.query, to: q) {
                pool = pool.filter { last.ids.contains($0.id) }
            }
            let targets = searchTargets
            var matchedIDs = Set<String>()
            for app in pool {
                var s: Double? = 0
                if !q.isEmpty { s = SearchMatcher.score(targets[app.id] ?? app.searchTarget, q) }
                guard let raw = s else { continue }
                matchedIDs.insert(app.id)
                if let categoryIDs, !categoryIDs.contains(category(of: app).id) { continue }
                let used = usage.score(of: app.id, at: date)
                results.append((.app(app), ranked(raw, appIDs: [app.id], usageScore: used), used))
            }
            if !q.isEmpty { lastSearchMatch = (q, matchedIDs) }
        }
        if includesFolders {
            for folder in allFolders {
                var s: Double? = 0
                if !q.isEmpty { s = SearchMatcher.score(folder.name, q) }
                guard let raw = s else { continue }
                let folderApps = apps(in: folder)
                guard !folderApps.isEmpty else { continue }
                // A folder is as "used" as its most used app.
                let used = folderApps.map { usage.score(of: $0.id, at: date) }.max() ?? 0
                results.append((.folder(folder, apps: folderApps), ranked(raw, appIDs: [], usageScore: used), used))
            }
        }
        results.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.usage != rhs.usage { return lhs.usage > rhs.usage }
            let r = lhs.item.title.localizedStandardCompare(rhs.item.title)
            return r == .orderedSame ? lhs.item.id < rhs.item.id : r == .orderedAscending
        }
        return results.map(\.item)
    }

    /// Ids of the categories (system or custom) of visible apps whose name or synonyms match `name`.
    private func matchingCategoryIDs(_ name: String) -> Set<String> {
        let q = SearchMatcher.Query(name)
        guard !q.isEmpty else { return [] }
        var seen: [String: AppCategory] = [:]
        for app in visibleApps { let c = category(of: app); seen[c.id] = c }
        var ids = Set<String>()
        for (id, c) in seen {
            let texts = [c.displayName] + (AppCategory.categorySynonyms[id] ?? [])
            if SearchMatcher.bestScore(texts, q) != nil { ids.insert(id) }
        }
        return ids
    }

    /// Remembers that the user launched `appID` while a search query was typed, so the same query
    /// ranks it higher next time (adaptive ranking; saved in `search-choices.json`). Only when the
    /// app really is a result of the query.
    func rememberSearchChoice(appID: String) {
        let (scope, text) = Self.parseSearch(query)
        guard scope != .settings, !text.isEmpty,
              let app = appsByID[appID],
              app.searchScore(SearchMatcher.Query(text)) != nil else { return }
        searchChoices.record(query: text, appID: appID, at: now())
        guard let store = searchChoiceStore else { return }
        do { try store.save(searchChoices) } catch {
            NSLog("%@", "MenuFold: failed to save search choices: \(error.localizedDescription)")
        }
    }

    /// Tabs (system/custom categories, "Запущені", "Недавні") whose title matches the current query,
    /// shown as chips above the results; empty for an empty query. Best match first, ties in tab order.
    public var matchingTabs: [GridTab] {
        let (scope, text) = Self.parseSearch(query)
        guard scope == .everything else { return [] }
        let q = SearchMatcher.Query(text)
        guard !q.isEmpty else { return [] }
        let scored = availableTabs.enumerated().compactMap { offset, tab -> (GridTab, Double, Int)? in
            let title: String
            switch tab {
            case .all, .clipboard: return nil
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
        let (scope, trimmed) = Self.parseSearch(query)
        guard scope == .everything || scope == .settings, trimmed.count >= 2 else { return [] }
        let q = SearchMatcher.Query(trimmed)
        let scored = SystemSettingsPane.catalog.enumerated().compactMap { offset, entry -> (SystemSettingsPane, Double, Int)? in
            SearchMatcher.bestScore(entry.searchTexts, q).map { (entry.pane, $0, offset) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
            .prefix(Self.settingsPaneLimit).map(\.0)
    }

    /// Selection id of the calculator row.
    public static var calculatorSelectionID: String { "calc" }

    /// The calculation or unit conversion the current query asks for ("2+2", "5 km in mi"); nil for
    /// anything else, and under a prefix scope (`>`, `/`, `@`, `?`). See `Calculator`.
    public var calculatorResult: CalculatorResult? {
        let (scope, text) = Self.parseSearch(query)
        guard scope == .everything, !text.isEmpty else { return nil }
        return Calculator.evaluate(text)
    }

    /// Copies the calculator value to the pasteboard and flashes `calculatorCopied`.
    /// The panel stays open.
    public func copyCalculatorResult() {
        guard let result = calculatorResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.value, forType: .string)
        calculatorCopied = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.calculatorCopied = false
        }
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
