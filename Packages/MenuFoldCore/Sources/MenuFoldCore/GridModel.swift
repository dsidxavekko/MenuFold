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
    /// Clipboard history (`GridModel.clipboard`). The very first tab, before "Все"; not reorderable;
    /// `showsClipboardTab` hides it.
    case clipboard
    case all
    /// Apps running right now (`GridModel.runningAppIDs`). Fixed right after "Все", not reorderable.
    case running
    /// Recently launched apps, newest first (`GridModel.recentApps`). Right after "Запущені", not
    /// reorderable; `showsRecentTab` hides it.
    case recent
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
    public private(set) var apps: [AppEntry] = [] { didSet { invalidateDerivedCaches(catalogChanged: true) } }
    public private(set) var layout: Layout = Layout() { didSet { invalidateDerivedCaches(catalogChanged: false) } }
    /// False until the catalog delivers its first result (even an empty one).
    public private(set) var isLoaded: Bool = false
    /// What `LayoutStore.loadWithOutcome()` found at launch, so Settings can tell the user (see
    /// `LayoutHealth.from(outcome:fileURL:quarantineFailedInPlace:)`). `.missing` without a store.
    public private(set) var layoutOutcome: LoadOutcome = .missing

    /// The layout.json this model reads and writes (nil without a store: previews, tests).
    public var layoutFileURL: URL? { store?.fileURL }

    /// True when an unusable layout could not be moved aside: saving is blocked to protect it.
    public var quarantineFailedInPlace: Bool { store?.lastQuarantineFailed ?? false }

    public var tab: GridTab = .all {
        didSet {
            guard tab != oldValue else { return }
            selectedItemID = nil
            clipboardSelectedID = nil
            // On the clipboard tab the search field filters the history; leaving it must not turn
            // that text into an app search.
            if oldValue == .clipboard, !query.isEmpty { query = "" }
            // The files section never shows on the clipboard tab, so a query there starts no search.
            fileQueryDidChange()
        }
    }
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            selectedItemID = nil
            clipboardSelectedID = nil
            // The "Документи" section follows the field: re-plan its search for the new text.
            fileQueryDidChange()
        }
    }
    /// Folder currently expanded over the grid.
    public var openFolderID: UUID? {
        didSet {
            guard openFolderID != oldValue else { return }
            selectedItemID = nil
            // Files are a search result; nothing is searched while a folder covers the grid.
            fileQueryDidChange()
        }
    }
    /// Files the current query matched, best first (see GridModel+Files.swift). Empty unless the
    /// query asks for files, so the "Документи" section only has rows when it belongs on screen.
    public internal(set) var fileResults: [FileItem] = []
    /// True while a file query is in flight: the panel keeps the rows it has (or an empty grid)
    /// instead of announcing "нічого не знайдено" before the answer is in.
    public internal(set) var isSearchingFiles = false
    /// Answers file queries; nil in previews and in tests that do not care, where the section stays
    /// empty. Set once by `AppDelegate` to `SpotlightFileSearchProvider`.
    @ObservationIgnored public var fileSearchProvider: FileSearching? {
        didSet { fileQueryDidChange() }
    }
    /// Pause before a file query starts, so typing does not start one per keystroke (250 ms).
    @ObservationIgnored var fileSearchDelay: Duration = .milliseconds(250)
    /// Text whose answer `fileResults` holds; nil when the rows belong to no query.
    @ObservationIgnored var fileSearchText: String?
    /// Bumped whenever a file query is planned: an answer from an older generation is dropped.
    @ObservationIgnored var fileSearchGeneration = 0
    /// The running (mostly sleeping) file query, cancelled when the query moves on.
    @ObservationIgnored var fileSearchTask: Task<Void, Never>?
    /// Keyboard selection: a `GridItem.id` ("app:…" / "folder:…"), or `frequentSelectionID(_:)` for
    /// a tile of the "Часті" row. Inside an open folder it is the "app:…" id of one of its apps.
    /// Reset when `tab`, `query` or `openFolderID` change, and on `panelDidOpen`.
    public var selectedItemID: String?
    /// App waiting for the in-panel "move to Trash" confirmation; nil when none is shown.
    public var pendingTrashAppID: String?
    /// App whose ⌘I info card is shown in the panel; nil when none.
    public var infoAppID: String?
    /// Newer versions found by `refreshAvailableUpdates(using:)`, by bundle id (empty while the feature is off).
    public internal(set) var availableUpdates: [String: AvailableUpdate] = [:]
    /// App for which the "Створити папку з…" picker is open; nil when none.
    public var folderPickerSourceID: String?
    /// App whose Tab quick-action list is shown in the panel; nil when none. `quickActionIndex` is
    /// the highlighted row.
    public var quickActionsAppID: String?
    public var quickActionIndex = 0
    /// The ⌘/ list of keyboard shortcuts is shown in the panel.
    public var showsShortcutsHelp = false
    /// True for a moment after the calculator result was copied (the row shows "Скопійовано").
    public var calculatorCopied = false

    /// Launch statistics behind `frequentApps`.
    public internal(set) var usage = UsageStats()
    /// Shows the "Часті" row (a Settings switch; the app persists it).
    public var showsFrequent = true { didSet { if showsFrequent != oldValue { clearSelectionIfGone() } } }
    /// True while `moveToTrash` is waiting for the system: the confirmation card must stay up
    /// (Esc and clicks outside don't close it) so the result reaches the user.
    public internal(set) var isTrashing = false
    /// How many apps the "Часті" row holds (one grid row).
    public var frequentLimit = 7
    /// Bundle ID → size on disk in bytes, measured off the main actor when a smart rule needs sizes
    /// (see SmartRules.swift). Empty until measured.
    public internal(set) var appSizes: [String: Int64] = [:] { didSet { invalidateDerivedCaches(catalogChanged: false) } }
    /// Measured bundle sizes per path, valid while the bundle's modification date is unchanged.
    @ObservationIgnored var sizeCache: [String: CachedAppSize] = [:]
    @ObservationIgnored var modificationDateProvider: @Sendable (URL) -> Date? = { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
    /// Measures a bundle (injectable for tests).
    @ObservationIgnored var sizeProvider: @Sendable (URL) -> Int64? = { AppSizer.size(of: $0) }
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

    /// Shows the "Недавні" tab (a Settings switch; off by default here, like `showsRunningTab`).
    public var showsRecentTab = false {
        didSet { if showsRecentTab != oldValue { validateTab() } }
    }
    /// Shows the clipboard tab in front of "Все" (a Settings switch; off by default here, like the others).
    public var showsClipboardTab = false {
        didSet { if showsClipboardTab != oldValue { validateTab() } }
    }
    /// Copied texts, fed by the app's pasteboard monitor. Memory only.
    public var clipboard = ClipboardHistory()
    /// The history row picked with the arrow keys (see GridModel+Clipboard.swift).
    public var clipboardSelectedID: UUID?
    /// Shows the "Закріплені" row on "Все" (a Settings switch the app persists).
    public var showsPinned = true { didSet { if showsPinned != oldValue { clearSelectionIfGone() } } }
    /// Offers files and documents under the search results (a Settings switch; the app defaults it
    /// to on, here it is off like the other switches, so tests and previews never query the disk).
    /// Off means no Spotlight query at all, the `~`/`file:` prefix included.
    public var searchesFiles = false {
        didSet { if searchesFiles != oldValue { fileQueryDidChange() } }
    }
    /// `panelDidOpen` keeps the current tab instead of going back to "Все" (a Settings switch).
    public var rememberLastTab = false
    /// Launch apps in the background and don't close the panel (a Settings switch): for opening
    /// several apps in a row. `onLaunched` is not called then.
    public var keepsPanelOpenAfterLaunch = false

    /// First-seen / last-launched dates per app (new-app dots, "Недавні", unused apps). See `AppHistory`.
    public internal(set) var history = AppHistory() { didSet { if !layout.smartRules.isEmpty { invalidateDerivedCaches(catalogChanged: false) } } }
    /// Layouts before the last changes, newest last (`undo()`); see GridModel+Arrange.swift.
    public internal(set) var undoStack: [Layout] = []
    /// Layouts undone, newest last (`redo()`).
    public internal(set) var redoStack: [Layout] = []
    /// True while `undo()`/`redo()` commit, so the commit does not record itself.
    @ObservationIgnored var isRestoringUndo = false
    /// history.json exists but could not be read (permissions, I/O): nothing is saved over it until
    /// a later read succeeds, and the catalog is not treated as a first run. See GridModel+Data.swift.
    @ObservationIgnored var historyUnreadable = false

    /// Called after an app was launched (Shell closes the panel).
    @ObservationIgnored public var onLaunched: (() -> Void)?
    /// Called on the main actor when a launch from `launch(_:)` fails (app removed since the last
    /// scan, damaged bundle, …), with the system's error text. The panel is already closed by then.
    @ObservationIgnored public var onLaunchFailed: ((AppEntry, String) -> Void)?

    @ObservationIgnored let catalog: AppCatalogProviding
    @ObservationIgnored let store: LayoutStore?
    @ObservationIgnored let usageStore: UsageStore?
    @ObservationIgnored let historyStore: AppHistoryStore?
    /// The store, for the data features in GridModel+Data.swift (backups, reload, export).
    @ObservationIgnored var layoutStore: LayoutStore? { store }
    /// Current time (injectable for tests).
    @ObservationIgnored var now: () -> Date = Date.init
    /// Home directory used to find ~/Applications (injectable for tests).
    @ObservationIgnored let homeDirectory: String
    /// Finder folder path → display name (injectable for tests; results are cached).
    @ObservationIgnored let finderNameResolver: (String) -> String
    @ObservationIgnored var finderNameCache: [String: String] = [:]

    // Caches derived from `apps` and `layout`, dropped by `invalidateDerivedCaches` whenever either
    // changes (search runs on every keystroke and used to rebuild all of this each time).
    @ObservationIgnored var appsByIDCache: [String: AppEntry]?
    @ObservationIgnored var visibleAppsCache: [AppEntry]?
    @ObservationIgnored var finderFoldersCache: [Folder]?
    /// Folded search data per app (see `SearchMatcher.Target`); rebuilt only when the catalog changes.
    @ObservationIgnored var searchTargetsCache: [String: SearchMatcher.Target]?
    /// Apps that matched the last search query, to narrow the next keystroke (GridModel+Search.swift).
    @ObservationIgnored var lastSearchMatch: (query: SearchMatcher.Query, ids: Set<String>)?
    /// Which app was launched after which query (adaptive ranking); see `SearchChoices`.
    @ObservationIgnored var searchChoices = SearchChoices()
    @ObservationIgnored var searchChoiceStore: SearchChoiceStore?

    /// A cache hit reads neither `apps` nor `layout`, so a SwiftUI body that only hits the cache would
    /// not be tracking them and never refresh when they change (the category tabs stayed as first
    /// drawn, without the system categories). Reading both registers the dependency.
    func trackCatalogAndLayout() {
        _ = apps
        _ = layout
    }

    func invalidateDerivedCaches(catalogChanged: Bool) {
        appsByIDCache = nil
        visibleAppsCache = nil
        finderFoldersCache = nil
        lastSearchMatch = nil
        if catalogChanged { searchTargetsCache = nil }
    }

    /// Installed apps by bundle ID (hidden ones too).
    var appsByID: [String: AppEntry] {
        if let cached = appsByIDCache { trackCatalogAndLayout(); return cached }
        let map = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        appsByIDCache = map
        return map
    }
    /// Folder that holds custom icon files. Without a store (previews, tests) a private temp folder.
    @ObservationIgnored public let iconsDirectory: URL

    public convenience init(catalog: AppCatalogProviding, store: LayoutStore?, usageStore: UsageStore? = nil,
                            historyStore: AppHistoryStore? = nil) {
        self.init(catalog: catalog, store: store, usageStore: usageStore, historyStore: historyStore,
                  homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                  finderNameResolver: FinderFolders.displayName(atPath:))
    }

    init(catalog: AppCatalogProviding, store: LayoutStore?, usageStore: UsageStore? = nil,
         historyStore: AppHistoryStore? = nil,
         homeDirectory: String, finderNameResolver: @escaping (String) -> String) {
        self.catalog = catalog
        self.store = store
        self.usageStore = usageStore
        self.historyStore = historyStore
        self.usage = usageStore?.load() ?? UsageStats()
        self.searchChoiceStore = usageStore.map {
            SearchChoiceStore(fileURL: $0.fileURL.deletingLastPathComponent().appendingPathComponent("search-choices.json"))
        }
        self.searchChoices = searchChoiceStore?.load() ?? SearchChoices()
        self.history = historyStore?.load() ?? AppHistory()
        self.historyUnreadable = historyStore?.lastLoadUnreadable ?? false
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
        //
        // Not in a shared (synced) folder: there a fresh empty file would sync to every other Mac and
        // wipe their layout too. The empty layout stays in memory only; the file is written by the
        // first change the user makes (or replaced by a valid one another Mac syncs in, which
        // `reloadLayoutFromDisk` picks up).
        if let store, !store.isShared {
            if case .quarantined = layoutOutcome {
                do { try store.save(layout) } catch {
                    NSLog("%@", "MenuFold: could not write a fresh layout after quarantine: \(error.localizedDescription)")
                }
            } else if case .incompatible = layoutOutcome {
                do { try store.save(layout) } catch {
                    NSLog("%@", "MenuFold: could not write a fresh layout after an incompatible file: \(error.localizedDescription)")
                }
            }
        }
        // Only a layout that was really read says which icon files are in use; after a quarantine
        // the old file still refers to them, so they are kept.
        if case .loaded = layoutOutcome {
            restorePersistedUndo()
            removeUnusedIconFiles()
            makeLaunchBackup()
        }
        self.apps = catalog.apps
        self.isLoaded = catalog.isLoaded
        if isLoaded { noteCatalogApps() }
        catalog.onChange = { [weak self] apps in
            self?.catalogDidChange(apps)
        }
        catalog.start()
    }

    private func catalogDidChange(_ newApps: [AppEntry]) {
        apps = newApps
        isLoaded = true
        noteCatalogApps()
        refreshAppSizes()
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
        return (showsClipboardTab ? [.clipboard] : []) + [.all] + (showsRunningTab ? [.running] : []) + (showsRecentTab ? [.recent] : [])
            + ordered.map { .category($0.element) }
    }

    /// Categories shown as tabs, in the default order (see `availableTabs`).
    var defaultCategoryOrder: [AppCategory] {
        var seen = Set<String>()
        var cats: [AppCategory] = []
        var hasOther = false
        for app in visibleApps {
            let c = category(of: app)
            if c.id == AppCategory.otherID { hasOther = true; continue }
            if c.isCustom || c.isSmart { continue }
            if seen.insert(c.id).inserted { cats.append(c) }
        }
        cats.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if hasOther { cats.append(.other) }
        let smart = smartCategories
        return (customCategories + smart + cats).filter { profileAllows(category: $0) }
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

    /// Non-empty query → `searchItems(query:)` (GridModel+Search.swift), ignoring tab.
    /// `.all` → folders (manual + Finder) + apps not in any folder, alphabetical (localized, case-insensitive).
    /// `.category` → flat alphabetical list of apps in that category (folders ignored).
    /// `.running` → flat alphabetical list of the running apps (folders ignored).
    /// Hidden apps never appear.
    public func items(tab: GridTab, query: String) -> [GridItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return searchItems(query: q)
        }
        switch tab {
        case .clipboard:
            return []
        case .running:
            return Self.sorted(visibleApps.filter { runningAppIDs.contains($0.id) }).map { .app($0) }
        case .recent:
            return recentApps.map { .app($0) }
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
            let alphabetical = result.sorted { lhs, rhs in
                let r = lhs.title.localizedStandardCompare(rhs.title)
                return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
            }
            return applyManualOrder(alphabetical)
        }
    }

    /// Override if set, else from Info.plist. An override to a deleted custom category is ignored.
    public func category(of app: AppEntry) -> AppCategory {
        if let raw = layout.categoryOverrides[app.id] {
            if !raw.hasPrefix(AppCategory.customPrefix) { return AppCategory.from(raw: raw) }
            if let custom = layout.customCategories.first(where: { $0.id == raw }) { return custom.category }
        }
        // A manual override (above) always wins; then the first matching smart rule.
        if let smart = smartCategory(for: app) { return smart }
        return AppCategory.automatic(for: app)
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

    public var visibleApps: [AppEntry] {
        if let cached = visibleAppsCache { trackCatalogAndLayout(); return cached }
        let list = apps.filter { !layout.hidden.contains($0.id) && profileAllows($0) }
        visibleAppsCache = list
        return list
    }

    static func sorted(_ list: [AppEntry]) -> [AppEntry] {
        list.sorted { lhs, rhs in
            let r = lhs.name.localizedStandardCompare(rhs.name)
            return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
        }
    }

    /// Opens app via NSWorkspace, then calls `onLaunched` right away (the panel closes without
    /// waiting). With `keepsPanelOpenAfterLaunch` a new launch goes to the background and the panel
    /// stays; an app that is already running is switched to as usual (activated, panel closed),
    /// since bringing it forward is the only thing such a click can do. A failure is reported later through `onLaunchFailed`. Usage is not recorded here:
    /// the app's did-launch observer (`AppDelegate.observeLaunches`) counts only launches that
    /// actually succeeded, so a failed launch does not pollute "Часті".
    /// `newInstance`: open another copy even when the app is running ("Новий екземпляр").
    public func launch(_ app: AppEntry, newInstance: Bool = false) {
        let switchesToRunning = keepsPanelOpenAfterLaunch && !newInstance
            && !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty
        let staysOpen = keepsPanelOpenAfterLaunch && !switchesToRunning
        let config = NSWorkspace.OpenConfiguration()
        config.activates = !staysOpen
        config.createsNewApplicationInstance = newInstance
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            NSLog("%@", "MenuFold: failed to launch \(app.url.path): \(message)")
            Task { @MainActor in self?.onLaunchFailed?(app, message) }
        }
        markSeen(app.id)
        rememberSearchChoice(appID: app.id)
        if !staysOpen { onLaunched?() }
    }

    /// "Відкрити всі" on a folder: launches every visible app in it (in the background but the last).
    public func launchAll(in folder: Folder) {
        let list = apps(in: folder)
        guard !list.isEmpty else { return }
        for app in list.dropLast() {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
                if let error { NSLog("%@", "MenuFold: failed to launch \(app.url.path): \(error.localizedDescription)") }
            }
            markSeen(app.id)
        }
        launch(list[list.count - 1])
    }

    public func revealInFinder(_ app: AppEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// Shell calls this each time the panel opens: clears query, closes open folder, and goes back
    /// to the "Все" tab unless `rememberLastTab` is on.
    public func panelDidOpen() {
        query = ""
        openFolderID = nil
        renamingFolderID = nil
        renamingCategoryID = nil
        if !rememberLastTab { tab = .all } else { validateTab() }
        selectedItemID = nil
        clipboardSelectedID = nil
        pendingTrashAppID = nil
        infoAppID = nil
        quickActionsAppID = nil
        showsShortcutsHelp = false
    }

    // MARK: Helpers

    /// Removes the app from every folder it is in. Does NOT dissolve anything: the caller dissolves
    /// afterwards, with `dissolveSingleAppFolders`, once the layout is in its final shape. Keeping the
    /// two apart is what stops a move from destroying an unrelated folder (e.g. the drop target's).
    static func detach(_ appID: String, from l: inout Layout) {
        for i in l.folders.indices where l.folders[i].appIDs.contains(appID) {
            l.folders[i].appIDs.removeAll { $0 == appID }
        }
    }

    /// Dissolves manual folders left with ≤1 app. Counting is on the stored `appIDs`, so a folder keeps
    /// the IDs of uninstalled (or hidden) apps. Call only after the layout has its final shape for the
    /// intent, so a folder that was just given its members survives.
    static func dissolveSingleAppFolders(_ l: inout Layout) {
        l.folders.removeAll { $0.appIDs.count <= 1 }
    }

    /// Clears a pending inline rename and returns nil: the result of every rejected folder drop.
    @discardableResult
    func rejectFolderDrop() -> UUID? {
        renamingFolderID = nil
        return nil
    }

    func closeOpenFolderIfGone() {
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
    func validateTab() {
        if tab != .all, !availableTabs.contains(tab) { tab = .all }
    }

    /// Applies and saves a layout. The version is normalized first, because `LayoutStore.save` writes
    /// `Layout.currentVersion` to disk: without it the in-memory `layout.version` would drift from the
    /// file. Comparing after normalizing keeps repeated identical intents from rewriting the file.
    /// Throws when the save failed (the in-memory layout is still updated).
    func commitPersisting(_ newLayout: Layout) throws {
        var committed = newLayout
        committed.version = Layout.currentVersion
        guard committed != layout else { return }
        if !isRestoringUndo { recordUndo(from: layout) }
        layout = committed
        persistUndo()
        validateTab()
        // A folder made/dissolved or a category changed can take the selected tile out of view.
        clearSelectionIfGone()
        guard let store else { return }
        try store.save(committed)
        // The store refuses to save while the layout file is unreadable; a successful save means
        // the file is gone or readable again, so a load-time warning is stale now.
        if case .unreadable = layoutOutcome { layoutOutcome = .loaded }
    }

    /// Applies a layout read from disk (another Mac changed the synced file) WITHOUT saving it:
    /// writing back would bounce the change between Macs and could overwrite a newer file.
    /// Undo/redo are cleared, since an undo across a sync would push stale state back out, and UI
    /// state pointing into the old layout (open folder, inline renames, selection, tab) is reset
    /// when its target is gone.
    func applyLayoutWithoutSaving(_ newLayout: Layout) {
        var applied = newLayout
        applied.version = Layout.currentVersion
        // An equal layout (usually the echo of this process's own save) changes nothing, undo included.
        guard applied != layout else { return }
        undoStack.removeAll()
        redoStack.removeAll()
        layout = applied
        validateTab()
        closeOpenFolderIfGone()
        if let id = renamingFolderID, !layout.folders.contains(where: { $0.id == id }) { renamingFolderID = nil }
        if let id = renamingCategoryID, !layout.customCategories.contains(where: { $0.id == id }) { renamingCategoryID = nil }
        clearSelectionIfGone()
    }

    func commit(_ newLayout: Layout) {
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
