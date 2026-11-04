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

    public var tab: GridTab = .all
    public var query: String = ""
    /// Folder currently expanded over the grid.
    public var openFolderID: UUID?
    /// Set right after `createFolder` so UI can start inline rename; UI clears it.
    public var renamingFolderID: UUID?

    /// Called after an app was launched (Shell closes the panel).
    @ObservationIgnored public var onLaunched: (() -> Void)?

    @ObservationIgnored private let catalog: AppCatalogProviding
    @ObservationIgnored private let store: LayoutStore?
    /// Home directory used to find ~/Applications (injectable for tests).
    @ObservationIgnored private let homeDirectory: String
    /// Finder folder path → display name (injectable for tests; results are cached).
    @ObservationIgnored private let finderNameResolver: (String) -> String
    @ObservationIgnored private var finderNameCache: [String: String] = [:]

    public convenience init(catalog: AppCatalogProviding, store: LayoutStore?) {
        self.init(catalog: catalog, store: store,
                  homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                  finderNameResolver: FinderFolders.displayName(atPath:))
    }

    init(catalog: AppCatalogProviding, store: LayoutStore?, homeDirectory: String, finderNameResolver: @escaping (String) -> String) {
        self.catalog = catalog
        self.store = store
        self.homeDirectory = homeDirectory
        self.finderNameResolver = finderNameResolver
        self.layout = store?.load() ?? Layout()
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
    }

    // MARK: Queries

    /// `.all` + one tab per category that has at least one visible app, sorted by name; `.other` last.
    public var availableTabs: [GridTab] {
        var seen = Set<String>()
        var cats: [AppCategory] = []
        var hasOther = false
        for app in visibleApps {
            let c = category(of: app)
            if c.id == AppCategory.otherID { hasOther = true; continue }
            if seen.insert(c.id).inserted { cats.append(c) }
        }
        cats.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if hasOther { cats.append(.other) }
        return [.all] + cats.map { .category($0) }
    }

    /// Items for current `tab` / `query`.
    public var visibleItems: [GridItem] { items(tab: tab, query: query) }

    /// Non-empty query → flat list of matching apps (including ones inside folders), ignoring tab.
    /// `.all` → folders (manual + Finder) + apps not in any folder, alphabetical (localized, case-insensitive).
    /// `.category` → flat alphabetical list of apps in that category (folders ignored).
    /// Hidden apps never appear.
    public func items(tab: GridTab, query: String) -> [GridItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            return Self.sorted(visibleApps.filter { $0.name.localizedStandardContains(q) }).map { .app($0) }
        }
        switch tab {
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

    /// Override if set, else from Info.plist.
    public func category(of app: AppEntry) -> AppCategory {
        if let raw = layout.categoryOverrides[app.id] { return AppCategory.from(raw: raw) }
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

    /// Drop app onto app → new folder "Нова папка" with both; sets `renamingFolderID`. nil if invalid (same app, etc.).
    /// If the target already sits in a manual folder, the dropped app joins that folder (its id is returned, no rename).
    /// A target that is only in a Finder folder gets a new manual folder (manual wins over Finder).
    @discardableResult
    public func createFolder(dropping appID: String, onto targetAppID: String) -> UUID? {
        guard appID != targetAppID,
              apps.contains(where: { $0.id == appID }),
              apps.contains(where: { $0.id == targetAppID }) else { return nil }
        if let existing = manualFolderContaining(appID: targetAppID) {
            if existing.appIDs.contains(appID) { return nil }
            add(appID, to: existing.id)
            return existing.id
        }
        var l = layout
        Self.detach(appID, from: &l)
        let folder = Folder(name: "Нова папка", appIDs: [targetAppID, appID])
        l.folders.append(folder)
        commit(l)
        renamingFolderID = folder.id
        return folder.id
    }

    /// Moves app into a folder (removing it from any manual one). For a Finder folder the app is
    /// shown there in MenuFold only (`finderAdditions`); the file is not moved.
    public func add(_ appID: String, to folderID: UUID) {
        if let path = finderFolders.first(where: { $0.id == folderID })?.finderPath {
            var l = layout
            Self.detach(appID, from: &l)
            l.finderAdditions[appID] = path
            l.finderExclusions.remove(appID)
            commit(l)
            return
        }
        guard let target = layout.folders.first(where: { $0.id == folderID }), !target.appIDs.contains(appID) else { return }
        var l = layout
        Self.detach(appID, from: &l)
        // Target can't have been dissolved by detach (app wasn't in it).
        guard let idx = l.folders.firstIndex(where: { $0.id == folderID }) else { return }
        l.folders[idx].appIDs.append(appID)
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

    /// nil → remove override.
    public func setCategory(_ category: AppCategory?, for appID: String) {
        var l = layout
        if let category {
            l.categoryOverrides[appID] = category.id
        } else {
            l.categoryOverrides.removeValue(forKey: appID)
        }
        commit(l)
    }

    public func hide(_ appID: String) {
        var l = layout
        guard l.hidden.insert(appID).inserted else { return }
        commit(l)
        closeOpenFolderIfGone()
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
        commit(Layout())
    }

    /// Opens app via NSWorkspace, then calls `onLaunched`.
    public func launch(_ app: AppEntry) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, error in
            if let error { NSLog("MenuFold: failed to launch \(app.url.path): \(error.localizedDescription)") }
        }
        onLaunched?()
    }

    public func revealInFinder(_ app: AppEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    /// Shell calls this each time the panel opens: clears query, closes open folder.
    /// Keeps the current tab if it is still available, else falls back to `.all`.
    public func panelDidOpen() {
        query = ""
        openFolderID = nil
        renamingFolderID = nil
        validateTab()
    }

    // MARK: Helpers

    /// Removes the app from every folder; folders left with ≤1 app are dissolved.
    private static func detach(_ appID: String, from l: inout Layout) {
        for i in l.folders.indices where l.folders[i].appIDs.contains(appID) {
            l.folders[i].appIDs.removeAll { $0 == appID }
        }
        l.folders.removeAll { $0.appIDs.count <= 1 }
    }

    private func closeOpenFolderIfGone() {
        if let id = openFolderID, folder(id: id).map({ apps(in: $0).isEmpty }) ?? true {
            openFolderID = nil
        }
    }

    /// Guarantees `tab ∈ availableTabs`.
    private func validateTab() {
        if case .category = tab, !availableTabs.contains(tab) { tab = .all }
    }

    private func commit(_ newLayout: Layout) {
        guard newLayout != layout else { return }
        layout = newLayout
        validateTab()
        guard let store else { return }
        do { try store.save(newLayout) } catch {
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
            Folder(name: "Робота", color: .blue, appIDs: ["com.apple.mail", "com.apple.Notes", "com.apple.iCal"]),
        ])
        return model
    }
}
