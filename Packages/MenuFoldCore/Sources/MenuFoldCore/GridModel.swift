import Foundation
import Observation
import AppKit

/// A Finder folder the user chose not to show as a folder (listed in Settings).
public struct FinderFolderRef: Identifiable, Hashable, Sendable {
    /// Absolute folder path.
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public enum GridTab: Hashable, Sendable {
    case all
    /// Apps running right now (`GridModel.runningAppIDs`). Fixed right after "Все", not reorderable.
    case running
    case category(AppCategory)
}

/// One tile in the grid.
public enum GridItem: Identifiable, Hashable, Sendable {
    case app(AppEntry)
    case folder(Folder, apps: [AppEntry])

    public var id: String {
        switch self {
        case .app(let a): return "app:\(a.id)"
        case .folder(let f, _): return "folder:\(f.id.uuidString)"
        }
    }

    public var title: String {
        switch self {
        case .app(let a): return a.name
        case .folder(let f, _): return f.name
        }
    }
}

/// Main state for the panel: catalog + persisted layout → grid items.
/// Every mutating intent saves the layout through `store` (if any).
@MainActor
@Observable
public final class GridModel {
    public private(set) var apps: [AppEntry] = []
    public private(set) var layout: Layout = Layout()
    /// False until the catalog delivers its first result (even an empty one).
    public private(set) var isLoaded: Bool = false
    /// What `LayoutStore.loadWithOutcome()` found at launch, so Settings can tell the user (see
    /// `LayoutHealth.from(outcome:fileURL:quarantineFailedInPlace:)`). `.missing` without a store.
    public private(set) var layoutOutcome: LoadOutcome = .missing

    /// True when an unusable layout could not be moved aside: saving is blocked to protect it.
    public var quarantineFailedInPlace: Bool { store?.lastQuarantineFailed ?? false }

    public var tab: GridTab = .all { didSet { if tab != oldValue { selectedItemID = nil } } }
    public var query: String = "" { didSet { if query != oldValue { selectedItemID = nil } } }
    /// Folder currently expanded over the grid.
    public var openFolderID: UUID? { didSet { if openFolderID != oldValue { selectedItemID = nil } } }
    /// Keyboard selection: a `GridItem.id` ("app:…" / "folder:…"), or `frequentSelectionID(_:)` for
    /// a tile of the "Часті" row. Inside an open folder it is the "app:…" id of one of its apps.
    /// Reset when `tab`, `query` or `openFolderID` change, and on `panelDidOpen`.
    public var selectedItemID: String?
    /// App waiting for the in-panel "move to Trash" confirmation; nil when none is shown.
    public var pendingTrashAppID: String?

    /// Launch statistics behind `frequentApps`.
    public internal(set) var usage = UsageStats()
    /// Shows the "Часті" row (a Settings switch; the app persists it).
    public var showsFrequent = true { didSet { if showsFrequent != oldValue { clearSelectionIfGone() } } }
    /// True while `moveToTrash` is waiting for the system: the confirmation card must stay up
    /// (Esc and clicks outside don't close it) so the result reaches the user.
    public internal(set) var isTrashing = false
    /// How many apps the "Часті" row holds (one grid row).
    public var frequentLimit = 7
    /// Bundle IDs of the apps running right now. The model can't watch processes itself, so the app
    /// keeps this current (NSWorkspace KVO).
    public var runningAppIDs: Set<String> = [] {
        didSet { if runningAppIDs != oldValue, tab == .running { clearSelectionIfGone() } }
    }
    /// Shows the "Запущені" tab (a Settings switch the app persists; off by default here so tests
    /// and previews keep the plain tab list).
    public var showsRunningTab = false {
        didSet { if showsRunningTab != oldValue { validateTab() } }
    }
    /// Set right after `createFolder` so UI can start inline rename; UI clears it.
    public var renamingFolderID: UUID?
    /// Custom category whose tab is being renamed inline. Unlike `renamingFolderID` this stays set
    /// while the field is being edited; the UI clears it when editing ends.
    public var renamingCategoryID: String?

    /// Called after an app was launched (Shell closes the panel).
    @ObservationIgnored public var onLaunched: (() -> Void)?
    /// Called on the main actor when a launch from `launch(_:)` fails (app removed since the last
    /// scan, damaged bundle, …), with the system's error text. The panel is already closed by then.
    @ObservationIgnored public var onLaunchFailed: ((AppEntry, String) -> Void)?

    @ObservationIgnored private let catalog: AppCatalogProviding
    @ObservationIgnored private let store: LayoutStore?
    @ObservationIgnored let usageStore: UsageStore?
    /// Current time (injectable for tests).
    @ObservationIgnored var now: () -> Date = Date.init
    /// Home directory used to find ~/Applications (injectable for tests).
    @ObservationIgnored private let homeDirectory: String
    /// Finder folder path → display name (injectable for tests; results are cached).
    @ObservationIgnored private let finderNameResolver: (String) -> String
    @ObservationIgnored private var finderNameCache: [String: String] = [:]
    /// Folder that holds custom icon files. Without a store (previews, tests) a private temp folder.
    @ObservationIgnored public let iconsDirectory: URL

    public convenience init(catalog: AppCatalogProviding, store: LayoutStore?, usageStore: UsageStore? = nil) {
        self.init(catalog: catalog, store: store, usageStore: usageStore,
                  homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                  finderNameResolver: FinderFolders.displayName(atPath:))
    }

    init(catalog: AppCatalogProviding, store: LayoutStore?, usageStore: UsageStore? = nil,
         homeDirectory: String, finderNameResolver: @escaping (String) -> String) {
        self.catalog = catalog
        self.store = store
        self.usageStore = usageStore
        self.usage = usageStore?.load() ?? UsageStats()
        self.homeDirectory = homeDirectory
        self.finderNameResolver = finderNameResolver
        self.iconsDirectory = store?.iconsDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MenuFold-Icons-\(UUID().uuidString)", isDirectory: true)
        let loaded = store?.loadWithOutcome()
        self.layout = loaded?.layout ?? Layout()
        self.layoutOutcome = loaded?.outcome ?? .missing
        // A quarantined file was moved aside and the in-memory layout is empty; write a fresh, valid
        // layout immediately, so the next launch — or a quit right after this one — still has a file
        // (the old copy is kept as layout.corrupt-…json). If the move failed, `save` refuses to run
        // and the user's unreadable file stays untouched (surfaced through `quarantineFailedInPlace`).
        // `.incompatible` works the same way: the newer file was moved aside, so a fresh one is needed.
        if case .quarantined = layoutOutcome, let store {
            do { try store.save(layout) } catch {
                NSLog("%@", "MenuFold: could not write a fresh layout after quarantine: \(error.localizedDescription)")
            }
        } else if case .incompatible = layoutOutcome, let store {
            do { try store.save(layout) } catch {
                NSLog("%@", "MenuFold: could not write a fresh layout after an incompatible file: \(error.localizedDescription)")
            }
        }
        // Only a layout that was really read says which icon files are in use; after a quarantine
        // the old file still refers to them, so they are kept.
        if case .loaded = layoutOutcome { removeUnusedIconFiles() }
        self.apps = catalog.apps
        self.isLoaded = catalog.isLoaded
        catalog.onChange = { [weak self] apps in
            self?.catalogDidChange(apps)
        }
        catalog.start()
    }

    private func catalogDidChange(_ newApps: [AppEntry]) {
        apps = newApps
        isLoaded = true
        // Layout is kept intact (apps come back on reinstall); only close a folder that became empty.
        closeOpenFolderIfGone()
        validateTab()
        clearSelectionIfGone()
    }

    // MARK: Queries

    /// `.all` first, then the categories in the user's order (`layout.categoryOrder`). Categories the
    /// user never placed keep the default order after them: custom categories, then system ones,
    /// each sorted by name, `.other` last.
    /// A system category appears only when it has a visible app. A custom category always appears
    /// (the user made it on purpose, and an empty tab is where apps can be added from).
    public var availableTabs: [GridTab] {
        let rank = Dictionary(layout.categoryOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let ordered = defaultCategoryOrder.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.id] ?? Int.max, r = rank[rhs.element.id] ?? Int.max
            return l != r ? l < r : lhs.offset < rhs.offset
        }
        return [.all] + (showsRunningTab ? [.running] : []) + ordered.map { .category($0.element) }
    }

    /// Categories shown as tabs, in the default order (see `availableTabs`).
    private var defaultCategoryOrder: [AppCategory] {
        var seen = Set<String>()
        var cats: [AppCategory] = []
        var hasOther = false
        for app in visibleApps {
            let c = category(of: app)
            if c.id == AppCategory.otherID { hasOther = true; continue }
            if c.isCustom { continue }
            if seen.insert(c.id).inserted { cats.append(c) }
        }
        cats.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if hasOther { cats.append(.other) }
        return customCategories + cats
    }

    /// True when the user has set their own tab order.
    public var hasCustomCategoryOrder: Bool { !layout.categoryOrder.isEmpty }

    /// User-made categories, sorted by name.
    public var customCategories: [AppCategory] {
        layout.customCategories.map(\.category).sorted { lhs, rhs in
            let r = lhs.displayName.localizedStandardCompare(rhs.displayName)
            return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
        }
    }

    /// Items for current `tab` / `query`.
    public var visibleItems: [GridItem] { items(tab: tab, query: query) }

    /// Non-empty query → flat list of matching apps (including ones inside folders), ignoring tab.
    /// `.all` → folders (manual + Finder) + apps not in any folder, alphabetical (localized, case-insensitive).
    /// `.category` → flat alphabetical list of apps in that category (folders ignored).
    /// `.running` → flat alphabetical list of the running apps (folders ignored).
    /// Hidden apps never appear.
    public func items(tab: GridTab, query: String) -> [GridItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return Self.sorted(visibleApps.filter { $0.matches(q) }).map { .app($0) }
        }
        switch tab {
        case .running:
            return Self.sorted(visibleApps.filter { runningAppIDs.contains($0.id) }).map { .app($0) }
        case .category(let cat):
            return Self.sorted(visibleApps.filter { category(of: $0).id == cat.id }).map { .app($0) }
        case .all:
            let folders = allFolders
            let inFolders = Set(folders.flatMap(\.appIDs))
            var result: [GridItem] = []
            for f in folders {
                let fa = apps(in: f)
                if !fa.isEmpty { result.append(.folder(f, apps: fa)) }
            }
            result += visibleApps.filter { !inFolders.contains($0.id) }.map { .app($0) }
            return result.sorted { lhs, rhs in
                let r = lhs.title.localizedStandardCompare(rhs.title)
                return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
            }
        }
    }

    /// Override if set, else from Info.plist. An override to a deleted custom category is ignored.
    public func category(of app: AppEntry) -> AppCategory {
        if let raw = layout.categoryOverrides[app.id] {
            if !raw.hasPrefix(AppCategory.customPrefix) { return AppCategory.from(raw: raw) }
            if let custom = layout.customCategories.first(where: { $0.id == raw }) { return custom.category }
        }
        return AppCategory.from(raw: app.infoCategory)
    }

    /// Manual or Finder folder by id.
    public func folder(id: UUID) -> Folder? {
        layout.folders.first { $0.id == id } ?? finderFolders.first { $0.id == id }
    }

    /// The app's effective folder: a manual folder wins over a Finder folder.
    public func folderContaining(appID: String) -> Folder? {
        manualFolderContaining(appID: appID) ?? finderFolders.first { $0.appIDs.contains(appID) }
    }

    /// Installed, non-hidden apps of a folder, alphabetical.
    public func apps(in folder: Folder) -> [AppEntry] {
        let ids = Set(folder.appIDs)
        return Self.sorted(visibleApps.filter { ids.contains($0.id) })
    }

    public var hiddenApps: [AppEntry] {
        Self.sorted(apps.filter { layout.hidden.contains($0.id) })
    }

    // MARK: Finder folders

    /// Manual folders followed by synthesized Finder folders.
    private var allFolders: [Folder] { layout.folders + finderFolders }

    private func manualFolderContaining(appID: String) -> Folder? {
        layout.folders.first { $0.appIDs.contains(appID) }
    }

    /// Synthesized Finder folders (not ignored), each with the installed apps that are in no manual
    /// folder and either live there on disk (unless excluded) or were dropped into it in MenuFold.
    /// `appIDs` may include hidden apps; `apps(in:)` filters them.
    private var finderFolders: [Folder] {
        let manual = Set(layout.folders.flatMap(\.appIDs))
        var groups: [String: [String]] = [:]
        var order: [String] = []
        for app in apps where !manual.contains(app.id) {
            guard let key = finderKey(for: app), !layout.ignoredFinderFolders.contains(key) else { continue }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(app.id)
        }
        return order.map { path in
            let style = layout.finderStyles[path] ?? FinderFolderStyle()
            return Folder(id: FinderFolders.folderID(forPath: path), name: finderName(path),
                          color: style.color, symbol: style.symbol, appIDs: groups[path] ?? [], finderPath: path)
        }
    }

    /// Effective Finder folder of an app: a MenuFold drop wins, else its real location unless excluded.
    private func finderKey(for app: AppEntry) -> String? {
        if let added = layout.finderAdditions[app.id] { return added }
        if layout.finderExclusions.contains(app.id) { return nil }
        return nativeFinderKey(app.id)
    }

    private func nativeFinderKey(_ appID: String) -> String? {
        guard let app = apps.first(where: { $0.id == appID }) else { return nil }
        return FinderFolders.key(forAppPath: app.url.path, homeDirectory: homeDirectory)
    }

    private func finderName(_ path: String) -> String {
        if let cached = finderNameCache[path] { return cached }
        let name = finderNameResolver(path)
        finderNameCache[path] = name
        return name
    }

    private var visibleApps: [AppEntry] {
        apps.filter { !layout.hidden.contains($0.id) }
    }

    private static func sorted(_ list: [AppEntry]) -> [AppEntry] {
        list.sorted { lhs, rhs in
            let r = lhs.name.localizedStandardCompare(rhs.name)
            return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
        }
    }

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

    private func uniqueCategoryName(_ base: String) -> String {
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

    public func resetLayout() {
        openFolderID = nil
        renamingFolderID = nil
        renamingCategoryID = nil
        commit(Layout())
        removeUnusedIconFiles()
    }

    // MARK: Custom icons

    /// The user's icon file for `appID`, or nil to use the app's own icon.
    public func customIconURL(for appID: String) -> URL? {
        layout.customIcons[appID].map { iconsDirectory.appendingPathComponent($0) }
    }

    /// Installed apps that have a custom icon, sorted by name (listed in Settings).
    public var appsWithCustomIcons: [AppEntry] {
        Self.sorted(apps.filter { layout.customIcons[$0.id] != nil })
    }

    /// Uses `source` as the icon of `appID`: an image file as is, any other file (e.g. another app)
    /// by its Finder icon. The picture is copied as a PNG, so the original may be moved or deleted.
    /// Each change gets a new file name, so caches keyed by the file never show the old picture.
    /// The previous icon file is deleted only after the save succeeded, so a failure keeps it.
    public func setCustomIcon(for appID: String, from source: URL) throws {
        let data = try CustomIcons.pngData(from: source)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        try data.write(to: iconsDirectory.appendingPathComponent(name), options: .atomic)
        let old = layout.customIcons[appID]
        var l = layout
        l.customIcons[appID] = name
        try commitPersisting(l)
        if let old { try? FileManager.default.removeItem(at: iconsDirectory.appendingPathComponent(old)) }
    }

    /// Goes back to the app's own icon. The old icon file is deleted only after the save succeeded,
    /// so a failed save keeps the bytes it still points at.
    public func resetCustomIcon(for appID: String) {
        var l = layout
        guard let old = l.customIcons.removeValue(forKey: appID) else { return }
        do {
            try commitPersisting(l)
            try? FileManager.default.removeItem(at: iconsDirectory.appendingPathComponent(old))
        } catch {
            NSLog("MenuFold: failed to save layout: \(error.localizedDescription)")
        }
    }

    /// Deletes icon files that no layout entry points at (left over after a reset or a crash).
    /// Files modified less than a minute ago are kept: another MenuFold instance (two copies can
    /// run at once) may have just written an icon for a layout this process has not read yet.
    private func removeUnusedIconFiles() {
        let used = Set(layout.customIcons.values)
        let fresh = Date().addingTimeInterval(-60)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: iconsDirectory.path)) ?? []
        for file in files where file.hasSuffix(".png") && !used.contains(file) {
            let url = iconsDirectory.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attrs[.modificationDate] as? Date, modified > fresh { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Opens app via NSWorkspace, then calls `onLaunched` right away (the panel closes without
    /// waiting). A failure is reported later through `onLaunchFailed`. Usage is not recorded here:
    /// the app's did-launch observer (`AppDelegate.observeLaunches`) counts only launches that
    /// actually succeeded, so a failed launch does not pollute "Часті".
    public func launch(_ app: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            NSLog("%@", "MenuFold: failed to launch \(app.url.path): \(message)")
            Task { @MainActor in self?.onLaunchFailed?(app, message) }
        }
        onLaunched?()
    }

    public func revealInFinder(_ app: AppEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// Shell calls this each time the panel opens: clears query, closes open folder, and goes back
    /// to the "Все" tab (the panel always opens on all apps, not on the last category).
    public func panelDidOpen() {
        query = ""
        openFolderID = nil
        renamingFolderID = nil
        renamingCategoryID = nil
        tab = .all
        selectedItemID = nil
        pendingTrashAppID = nil
    }

    // MARK: Helpers

    /// Removes the app from every folder it is in. Does NOT dissolve anything: the caller dissolves
    /// afterwards, with `dissolveSingleAppFolders`, once the layout is in its final shape. Keeping the
    /// two apart is what stops a move from destroying an unrelated folder (e.g. the drop target's).
    private static func detach(_ appID: String, from l: inout Layout) {
        for i in l.folders.indices where l.folders[i].appIDs.contains(appID) {
            l.folders[i].appIDs.removeAll { $0 == appID }
        }
    }

    /// Dissolves manual folders left with ≤1 app. Counting is on the stored `appIDs`, so a folder keeps
    /// the IDs of uninstalled (or hidden) apps. Call only after the layout has its final shape for the
    /// intent, so a folder that was just given its members survives.
    private static func dissolveSingleAppFolders(_ l: inout Layout) {
        l.folders.removeAll { $0.appIDs.count <= 1 }
    }

    /// Clears a pending inline rename and returns nil: the result of every rejected folder drop.
    @discardableResult
    private func rejectFolderDrop() -> UUID? {
        renamingFolderID = nil
        return nil
    }

    private func closeOpenFolderIfGone() {
        if let id = openFolderID, folder(id: id).map({ apps(in: $0).isEmpty }) ?? true {
            openFolderID = nil
        }
    }

    /// Clears `selectedItemID` when the item it points to is no longer shown.
    func clearSelectionIfGone() {
        guard let id = selectedItemID else { return }
        if !navigableSections.contains(where: { $0.contains(id) }) { selectedItemID = nil }
    }

    /// Guarantees `tab ∈ availableTabs`.
    private func validateTab() {
        if tab != .all, !availableTabs.contains(tab) { tab = .all }
    }

    /// Applies and saves a layout. The version is normalized first, because `LayoutStore.save` writes
    /// `Layout.currentVersion` to disk: without it the in-memory `layout.version` would drift from the
    /// file. Comparing after normalizing keeps repeated identical intents from rewriting the file.
    /// Throws when the save failed (the in-memory layout is still updated).
    private func commitPersisting(_ newLayout: Layout) throws {
        var committed = newLayout
        committed.version = Layout.currentVersion
        guard committed != layout else { return }
        layout = committed
        validateTab()
        // A folder made/dissolved or a category changed can take the selected tile out of view.
        clearSelectionIfGone()
        guard let store else { return }
        try store.save(committed)
        // The store refuses to save while the layout file is unreadable; a successful save means
        // the file is gone or readable again, so a load-time warning is stale now.
        if case .unreadable = layoutOutcome { layoutOutcome = .loaded }
    }

    private func commit(_ newLayout: Layout) {
        do { try commitPersisting(newLayout) } catch {
            NSLog("MenuFold: failed to save layout: \(error.localizedDescription)")
        }
    }

    // MARK: Preview

    /// Sample model for SwiftUI previews: real system apps (/System/Applications/…),
    /// one manual folder, the "Утиліти" Finder folder (Terminal), a few categories, no store.
    public static var preview: GridModel {
        func app(_ id: String, _ name: String, _ path: String, _ cat: String?) -> AppEntry {
            AppEntry(id: id, name: name, url: URL(fileURLWithPath: path, isDirectory: true),
                     infoCategory: cat.map { "public.app-category." + $0 })
        }
        let sys = "/System/Applications/"
        let apps = [
            app("com.apple.mail", "Mail", sys + "Mail.app", "productivity"),
            app("com.apple.Notes", "Notes", sys + "Notes.app", "productivity"),
            app("com.apple.iCal", "Calendar", sys + "Calendar.app", "productivity"),
            app("com.apple.Safari", "Safari", "/Applications/Safari.app", nil),
            app("com.apple.Music", "Music", sys + "Music.app", "music"),
            app("com.apple.Photos", "Photos", sys + "Photos.app", "photography"),
            app("com.apple.Maps", "Maps", sys + "Maps.app", "travel"),
            app("com.apple.MobileSMS", "Messages", sys + "Messages.app", "social-networking"),
            app("com.apple.FaceTime", "FaceTime", sys + "FaceTime.app", "social-networking"),
            app("com.apple.Preview", "Preview", sys + "Preview.app", "productivity"),
            app("com.apple.TextEdit", "TextEdit", sys + "TextEdit.app", "productivity"),
            app("com.apple.calculator", "Calculator", sys + "Calculator.app", "utilities"),
            app("com.apple.Chess", "Chess", sys + "Chess.app", "board-games"),
            app("com.apple.AppStore", "App Store", sys + "App Store.app", nil),
            app("com.apple.systempreferences", "System Settings", sys + "System Settings.app", "utilities"),
            app("com.apple.Terminal", "Terminal", sys + "Utilities/Terminal.app", "developer-tools"),
        ]
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        model.layout = Layout(folders: [
            Folder(name: L("Робота"), color: .blue, appIDs: ["com.apple.mail", "com.apple.Notes", "com.apple.iCal"]),
        ])
        return model
    }
}
