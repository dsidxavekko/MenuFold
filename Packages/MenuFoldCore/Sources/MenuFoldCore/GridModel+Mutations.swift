import Foundation
import Observation
import AppKit

extension GridModel {
    // MARK: Intents

    /// Drop app onto app → new folder "Нова папка" with both; sets `renamingFolderID`. nil if invalid (same app, etc.),
    /// and every nil path also clears `renamingFolderID`, so a rejected drop can't leave a stale rename request behind.
    /// If the target already sits in a manual folder, the dropped app joins that folder (its id is returned, no rename).
    /// A target that is only in a Finder folder gets a new manual folder (manual wins over Finder).
    ///
    /// Dropping the app may dissolve the folder it left (≤1 app).
    @discardableResult
    public func createFolder(dropping appID: String, onto targetAppID: String) -> UUID? {
        guard appID != targetAppID,
              apps.contains(where: { $0.id == appID }),
              apps.contains(where: { $0.id == targetAppID }) else { return rejectFolderDrop() }
        if let existing = manualFolderContaining(appID: targetAppID) {
            if existing.appIDs.contains(appID) { return rejectFolderDrop() }
            add(appID, to: existing.id)
            renamingFolderID = nil
            return existing.id
        }
        var l = layout
        let newID = UUID()
        Self.detach(appID, from: &l)
        // Exactly the two apps the user sees paired. The target sits in no manual folder here
        // (that case joined above); the sweep below dissolves the folder the dragged app left
        // if it now has ≤1 app.
        l.folders.append(Folder(id: newID, name: L("Нова папка"), appIDs: [targetAppID, appID]))
        Self.dissolveSingleAppFolders(&l)
        // In a manual "Все" order the new folder takes the target app's place, where the user dropped.
        if var order = l.manualOrder, let idx = order.firstIndex(of: "app:" + targetAppID) {
            order.insert("folder:" + newID.uuidString, at: idx)
            l.manualOrder = order
        }
        commit(l)
        renamingFolderID = newID
        return newID
    }

    /// Moves app into a folder (removing it from any manual one). For a Finder folder the app is
    /// shown there in MenuFold only (`finderAdditions`); the file is not moved.
    /// Only folders the app actually left can be dissolved; a move into a folder never dissolves it.
    public func add(_ appID: String, to folderID: UUID) {
        if let path = finderFolders.first(where: { $0.id == folderID })?.finderPath {
            var l = layout
            Self.detach(appID, from: &l)
            l.finderAdditions[appID] = path
            l.finderExclusions.remove(appID)
            Self.dissolveSingleAppFolders(&l)
            commit(l)
            return
        }
        guard let target = layout.folders.first(where: { $0.id == folderID }), !target.appIDs.contains(appID) else { return }
        var l = layout
        Self.detach(appID, from: &l)
        // Target can't have been dissolved by detach (app wasn't in it).
        guard let idx = l.folders.firstIndex(where: { $0.id == folderID }) else { return }
        l.folders[idx].appIDs.append(appID)
        Self.dissolveSingleAppFolders(&l)
        commit(l)
    }

    /// Removes app from its folder; a manual folder left with ≤1 app is dissolved.
    /// From a Finder folder the app is excluded (shown at the top level); files are not touched.
    public func removeFromFolder(_ appID: String) {
        guard let current = folderContaining(appID: appID) else { return }
        var l = layout
        if current.isFinder {
            l.finderAdditions.removeValue(forKey: appID)
            // Without the exclusion it would fall back into the folder it lives in on disk.
            if nativeFinderKey(appID) != nil { l.finderExclusions.insert(appID) }
        } else {
            Self.detach(appID, from: &l)
            Self.dissolveSingleAppFolders(&l)
        }
        commit(l)
        closeOpenFolderIfGone()
    }

    /// No-op for Finder folders (the name comes from Finder).
    public func rename(folder folderID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = layout.folders.firstIndex(where: { $0.id == folderID }) else { return }
        var l = layout
        l.folders[idx].name = trimmed
        commit(l)
    }

    public func setStyle(folder folderID: UUID, color: FolderColor, symbol: String?) {
        let symbol = (symbol?.isEmpty ?? true) ? nil : symbol
        var l = layout
        if let idx = layout.folders.firstIndex(where: { $0.id == folderID }) {
            l.folders[idx].color = color
            l.folders[idx].symbol = symbol
        } else if let path = finderFolders.first(where: { $0.id == folderID })?.finderPath {
            l.finderStyles[path] = FinderFolderStyle(color: color, symbol: symbol)
        } else {
            return
        }
        commit(l)
    }

    /// Manual folder → deleted. Finder folder → ignored (restorable via `restoreFinderFolder`).
    public func dissolve(folder folderID: UUID) {
        guard let target = folder(id: folderID) else { return }
        var l = layout
        if let path = target.finderPath {
            l.ignoredFinderFolders.insert(path)
        } else {
            l.folders.removeAll { $0.id == folderID }
        }
        commit(l)
        closeOpenFolderIfGone()
    }

    /// nil → remove override. A no-op when there is nothing to remove (or the same value is set again),
    /// so the UI can't persist overrides for apps that have none, or junk keys for unknown IDs.
    public func setCategory(_ category: AppCategory?, for appID: String) {
        var l = layout
        if let category {
            guard l.categoryOverrides[appID] != category.id else { return }
            // A custom category must still exist (a stale menu could offer a deleted one).
            if category.isCustom, !l.customCategories.contains(where: { $0.id == category.id }) { return }
            l.categoryOverrides[appID] = category.id
        } else {
            guard l.categoryOverrides.removeValue(forKey: appID) != nil else { return }
        }
        commit(l)
    }

    /// `setCategory` for several apps as one change (one save, one ⌘Z step). nil → remove overrides.
    public func setCategory(_ category: AppCategory?, for appIDs: [String]) {
        var l = layout
        if let category {
            if category.isCustom, !l.customCategories.contains(where: { $0.id == category.id }) { return }
            for id in appIDs where !id.isEmpty { l.categoryOverrides[id] = category.id }
        } else {
            for id in appIDs { l.categoryOverrides.removeValue(forKey: id) }
        }
        commit(l)
    }

    /// Creates a custom category. A blank name becomes "Нова категорія"; a name already used by
    /// another custom category gets a number ("Нова категорія 2"), so tabs stay tellable apart.
    /// With `appID`, that app is moved into it. Returns the new category.
    @discardableResult
    public func createCategory(named name: String = "", assigning appID: String? = nil) -> AppCategory {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = CustomCategory(name: uniqueCategoryName(trimmed.isEmpty ? L("Нова категорія") : trimmed))
        var l = layout
        l.customCategories.append(custom)
        if let appID { l.categoryOverrides[appID] = custom.id }
        commit(l)
        return custom.category
    }

    /// Renames a custom category; a blank name or a system category is a no-op.
    public func renameCategory(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = layout.customCategories.firstIndex(where: { $0.id == id }) else { return }
        var l = layout
        l.customCategories[idx].name = trimmed
        // The tab value carries the display name: keep the selection on the renamed category.
        // Read both before commit: commit's validateTab() sees the OLD name gone, resets `tab` to
        // `.all` and its didSet clears the selection; restore both after the new tab is set.
        let renamedOld = layout.customCategories[idx].category
        let oldTab = tab
        let selection = selectedItemID
        commit(l)
        if oldTab == .category(renamedOld) {
            tab = .category(l.customCategories[idx].category)
            selectedItemID = selection
        }
    }

    /// Sets the tab order from category ids (as the tabs show them, without `.all`). Unknown ids and
    /// repeats are ignored. Ids already in the saved order but not passed (a category with no visible
    /// apps right now) are kept, after the passed ones.
    public func setCategoryOrder(_ ids: [String]) {
        let known = Set(defaultCategoryOrder.map(\.id))
        var seen = Set<String>()
        var order = ids.filter { known.contains($0) && seen.insert($0).inserted }
        order += layout.categoryOrder.filter { seen.insert($0).inserted }
        var l = layout
        l.categoryOrder = order
        commit(l)
    }

    /// Moves a category tab one step left (`offset` -1) or right (+1). `.all` stays first.
    public func moveCategory(id: String, by offset: Int) {
        var ids = availableTabs.compactMap { tab -> String? in
            if case .category(let c) = tab { return c.id } else { return nil }
        }
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + offset
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        setCategoryOrder(ids)
    }

    /// Back to the default tab order.
    public func resetCategoryOrder() {
        var l = layout
        l.categoryOrder = []
        commit(l)
    }

    /// Deletes a custom category; its apps go back to their automatic category.
    public func deleteCategory(id: String) {
        guard layout.customCategories.contains(where: { $0.id == id }) else { return }
        var l = layout
        l.customCategories.removeAll { $0.id == id }
        l.categoryOverrides = l.categoryOverrides.filter { $0.value != id }
        l.categoryOrder.removeAll { $0 == id }
        if renamingCategoryID == id { renamingCategoryID = nil }
        commit(l)
    }

    /// Visible apps the user put into a custom category (for Settings).
    public func apps(inCategory id: String) -> [AppEntry] {
        Self.sorted(visibleApps.filter { layout.categoryOverrides[$0.id] == id })
    }

    func uniqueCategoryName(_ base: String) -> String {
        let taken = Set(layout.customCategories.map { $0.name.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    public func hide(_ appID: String) {
        var l = layout
        guard l.hidden.insert(appID).inserted else { return }
        commit(l)
        closeOpenFolderIfGone()
        if selectedItemID == "app:" + appID || selectedItemID == Self.frequentSelectionID(appID) {
            selectedItemID = nil
        }
    }

    public func unhide(_ appID: String) {
        var l = layout
        guard l.hidden.remove(appID) != nil else { return }
        commit(l)
    }

    /// Finder folders the user turned off with `dissolve`, sorted by name.
    public var ignoredFinderFolders: [FinderFolderRef] {
        layout.ignoredFinderFolders
            .map { FinderFolderRef(id: $0, name: finderName($0)) }
            .sorted { lhs, rhs in
                let r = lhs.name.localizedStandardCompare(rhs.name)
                return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
            }
    }

    /// Shows a previously dissolved Finder folder again.
    public func restoreFinderFolder(path: String) {
        var l = layout
        guard l.ignoredFinderFolders.remove(path) != nil else { return }
        commit(l)
    }

    /// Back to an empty layout (undoable). Icon files are not deleted here: undo can bring their
    /// mappings back, and undo lives in memory only, so the next launch's cleanup removes the ones
    /// nothing uses any more.
    public func resetLayout() {
        openFolderID = nil
        renamingFolderID = nil
        renamingCategoryID = nil
        commit(Layout())
    }
}
