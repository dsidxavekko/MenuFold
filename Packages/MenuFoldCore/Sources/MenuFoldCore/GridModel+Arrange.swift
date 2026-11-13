import Foundation

// CONTRACT (owner: Core-Arrange agent). Signatures are fixed.

extension GridModel {
    // MARK: Pinned ("Закріплені" row)

    /// Visible, installed pinned apps in the user's order. Empty when `showsPinned` is off, the
    /// query is not empty, or the tab is not `.all`.
    /// `layout.pinned` keeps the ids of uninstalled apps (like folders do), so a reinstalled app
    /// comes back to its place in the row; they are simply not shown meanwhile.
    public var pinnedApps: [AppEntry] {
        guard showsPinned, tab == .all,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return visiblePinnedApps
    }

    /// Pinned apps that can be shown right now, regardless of tab, query and `showsPinned`.
    /// Pinned apps that are installed and not hidden, in the user's order, regardless of tab, query
    /// and `showsPinned` (Dock menu, menu bar menu, Settings).
    public var visiblePinnedApps: [AppEntry] {
        let byID = Dictionary(visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return layout.pinned.compactMap { byID[$0] }
    }

    public func isPinned(_ appID: String) -> Bool { layout.pinned.contains(appID) }

    /// Appends the app to the end of the row. Pinning an already pinned app is a no-op.
    public func pin(_ appID: String) {
        guard !appID.isEmpty, !layout.pinned.contains(appID) else { return }
        var l = layout
        l.pinned.append(appID)
        commit(l)
    }

    public func unpin(_ appID: String) {
        guard layout.pinned.contains(appID) else { return }
        var l = layout
        l.pinned.removeAll { $0 == appID }
        commit(l)
        clearSelectionIfGone()
    }

    /// Moves a pinned app one step left (-1) / right (+1).
    /// The step is counted among the apps the row *shows*: the stored list may hold uninstalled or
    /// hidden apps in between, and stepping over an invisible one would look like nothing happened.
    /// Those invisible entries keep their slots.
    public func movePinned(_ appID: String, by offset: Int) {
        let visible = Set(visibleApps.map(\.id))
        let slots = layout.pinned.indices.filter { visible.contains(layout.pinned[$0]) }
        guard let from = slots.firstIndex(where: { layout.pinned[$0] == appID }) else { return }
        let to = from + offset
        guard offset != 0, slots.indices.contains(to) else { return }
        var shown = slots.map { layout.pinned[$0] }
        let moved = shown.remove(at: from)
        shown.insert(moved, at: to)
        var l = layout
        for (slot, id) in zip(slots, shown) { l.pinned[slot] = id }
        commit(l)
    }

    // MARK: Manual order of "Все"

    /// True when "Все" uses the user's order (`layout.manualOrder != nil`).
    public var hasManualOrder: Bool { layout.manualOrder != nil }

    /// Applies `layout.manualOrder` to the alphabetical "Все" items (called by `items(tab:query:)`).
    /// Listed items come first, in the listed order; the rest (new apps, folders that are not
    /// listed) follow in the incoming alphabetical order. Stale ids are ignored. A folder made from
    /// two apps is listed: `createFolder` inserts it at the target app's place.
    func applyManualOrder(_ items: [GridItem]) -> [GridItem] {
        guard let order = layout.manualOrder, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let listed = items.filter { rank[$0.id] != nil }.sorted { rank[$0.id]! < rank[$1.id]! }
        let rest = items.filter { rank[$0.id] == nil }
        return listed + rest
    }

    /// Moves the "Все" item `itemID` before (`after == false`) or after `targetID` (both `GridItem.id`s).
    /// Switches "Все" to manual order (starting from the current order) if it was alphabetical.
    ///
    /// The stored order keeps "app:…" ids that are not shown now (uninstalled or hidden apps), so a
    /// reinstalled app returns to its place: each stays right after the shown item it followed.
    /// "folder:…" ids of folders that no longer exist are dropped when writing, since a folder id is
    /// never reused.
    public func moveItem(_ itemID: String, relativeTo targetID: String, after: Bool) {
        guard itemID != targetID else { return }
        let shown = items(tab: .all, query: "").map(\.id)
        guard shown.contains(itemID), shown.contains(targetID) else { return }

        // The new order of the shown items.
        var reordered = shown.filter { $0 != itemID }
        guard let targetIndex = reordered.firstIndex(of: targetID) else { return }
        reordered.insert(itemID, at: after ? targetIndex + 1 : targetIndex)

        // The full stored list: the cleaned old order, then the shown items it did not list yet.
        // An entry that is not shown (uninstalled or hidden app) stays attached to the shown item
        // it followed, so it comes back next to it; entries before every shown item stay first.
        let existingFolders = Set(allFolders.map { "folder:\($0.id.uuidString)" })
        var seen = Set<String>()
        let old = (layout.manualOrder ?? []).filter { id in
            !id.isEmpty && (!id.hasPrefix("folder:") || existingFolders.contains(id)) && seen.insert(id).inserted
        }
        let shownSet = Set(shown)
        var leading: [String] = []
        var trailing: [String: [String]] = [:]
        var anchor: String?
        for id in old {
            if shownSet.contains(id) { anchor = id }
            else if let anchor { trailing[anchor, default: []].append(id) }
            else { leading.append(id) }
        }
        let full = leading + reordered.flatMap { [$0] + (trailing[$0] ?? []) }

        var l = layout
        l.manualOrder = full
        commit(l)
    }

    /// Back to alphabetical order.
    public func resetManualOrder() {
        guard layout.manualOrder != nil else { return }
        var l = layout
        l.manualOrder = nil
        commit(l)
    }

    // MARK: "Недавні"

    /// Visible apps launched recently (`history.lastLaunched`), newest first, at most `recentLimit`.
    /// Equal dates fall back to the name, so the order is stable.
    public var recentApps: [AppEntry] {
        let dated = visibleApps.compactMap { app in history.lastLaunched[app.id].map { (app, $0) } }
        let sorted = dated.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            let r = lhs.0.name.localizedStandardCompare(rhs.0.name)
            return r == .orderedSame ? lhs.0.id < rhs.0.id : r == .orderedAscending
        }
        return sorted.prefix(Self.recentLimit).map(\.0)
    }
    public static var recentLimit: Int { 28 }

    // MARK: Undo

    /// How many layouts `undoStack` keeps.
    static var undoLimit: Int { 50 }

    /// Called by `commitPersisting` with the layout before a change (not while undoing).
    /// A new change makes the undone changes unreachable, so the redo stack is cleared.
    func recordUndo(from previous: Layout) {
        undoStack.append(previous)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() { restore(from: \.undoStack, pushingCurrentTo: \.redoStack) }
    public func redo() { restore(from: \.redoStack, pushingCurrentTo: \.undoStack) }

    /// Pops layouts off `source` until one differs from the current layout, commits it and pushes
    /// the current layout onto `other`.
    ///
    /// Custom icons come back with the entry (`restoredIcons`): icon files are no longer deleted
    /// during a session (only by the next launch's cleanup), so the files an entry names are
    /// normally still there. An entry equal to the current layout is skipped.
    private func restore(from source: ReferenceWritableKeyPath<GridModel, [Layout]>,
                         pushingCurrentTo other: ReferenceWritableKeyPath<GridModel, [Layout]>) {
        var current = layout
        current.version = Layout.currentVersion
        while var target = self[keyPath: source].popLast() {
            target.customIcons = restoredIcons(target.customIcons, current: layout.customIcons)
            target.version = Layout.currentVersion
            guard target != current else { continue }
            self[keyPath: other].append(layout)
            if self[keyPath: other].count > Self.undoLimit {
                self[keyPath: other].removeFirst(self[keyPath: other].count - Self.undoLimit)
            }
            isRestoringUndo = true
            commit(target)
            isRestoringUndo = false
            renamingFolderID = nil
            renamingCategoryID = nil
            closeOpenFolderIfGone()
            clearSelectionIfGone()
            return
        }
    }

    /// The icon mapping an undo/redo entry gets: the entry's own mapping when every file it names
    /// exists in `iconsDirectory`. Otherwise, per app, the entry's mapping where its file exists;
    /// where it is missing (deleted outside MenuFold, or by an older version), the current mapping
    /// for that app, so undo never points an app at a file that is gone.
    func restoredIcons(_ entry: [String: String], current: [String: String]) -> [String: String] {
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: iconsDirectory.appendingPathComponent(name).path)
        }
        var result: [String: String] = [:]
        for (id, name) in entry {
            if exists(name) { result[id] = name } else if let cur = current[id] { result[id] = cur }
        }
        return result
    }

    // MARK: Tabs from the keyboard

    /// ⌘1…⌘9: selects `availableTabs[index]` (0-based) if it exists.
    /// Like `cycleTab`, it clears the query and closes an open folder (see `switchTab`).
    public func selectTab(at index: Int) {
        let tabs = availableTabs
        guard tabs.indices.contains(index) else { return }
        switchTab(to: tabs[index])
    }

    /// ⌃Tab / ⌃⇧Tab: next/previous tab, wrapping around.
    public func cycleTab(by offset: Int) {
        let tabs = availableTabs
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex(of: tab) ?? 0
        let n = tabs.count
        switchTab(to: tabs[((current + offset) % n + n) % n])
    }

    /// A tab chosen from the keyboard must be what the user then sees: a non-empty query ignores
    /// the tab and an open folder covers the grid, so both are cleared.
    private func switchTab(to newTab: GridTab) {
        query = ""
        openFolderID = nil
        renamingFolderID = nil
        tab = newTab
    }

    // MARK: Dock menu

    /// Up to `limit` visible apps with the highest usage score, regardless of tab/query/`showsFrequent`.
    public func mostUsedApps(limit: Int) -> [AppEntry] {
        guard limit > 0 else { return [] }
        let byID = Dictionary(visibleApps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return usage.top(limit, among: Set(byID.keys), at: now()).compactMap { byID[$0] }
    }

    /// Folders (manual + Finder) that have visible apps, alphabetical.
    public var visibleFolders: [Folder] {
        allFolders.filter { !apps(in: $0).isEmpty }.sorted { lhs, rhs in
            let r = lhs.name.localizedStandardCompare(rhs.name)
            return r == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : r == .orderedAscending
        }
    }

    /// Folder whose name equals `name` (case- and diacritic-insensitive), for URL scheme / Shortcuts.
    /// Surrounding whitespace is ignored. A folder with visible apps wins over an empty one of the
    /// same name.
    public func folder(named name: String) -> Folder? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        func matches(_ f: Folder) -> Bool {
            f.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(wanted, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
        return visibleFolders.first(where: matches) ?? allFolders.first(where: matches)
    }
}
