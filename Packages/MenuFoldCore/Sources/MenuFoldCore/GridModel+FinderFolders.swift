import Foundation
import Observation
import AppKit

extension GridModel {
    // MARK: Finder folders

    /// Manual folders followed by synthesized Finder folders.
    var allFolders: [Folder] { layout.folders + finderFolders }

    func manualFolderContaining(appID: String) -> Folder? {
        layout.folders.first { $0.appIDs.contains(appID) }
    }

    /// Synthesized Finder folders (not ignored), each with the installed apps that are in no manual
    /// folder and either live there on disk (unless excluded) or were dropped into it in MenuFold.
    /// `appIDs` may include hidden apps; `apps(in:)` filters them.
    var finderFolders: [Folder] {
        if let cached = finderFoldersCache { trackCatalogAndLayout(); return cached }
        let computed = computeFinderFolders()
        finderFoldersCache = computed
        return computed
    }

    func computeFinderFolders() -> [Folder] {
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
    func finderKey(for app: AppEntry) -> String? {
        if let added = layout.finderAdditions[app.id] { return added }
        if layout.finderExclusions.contains(app.id) { return nil }
        return nativeFinderKey(app.id)
    }

    func nativeFinderKey(_ appID: String) -> String? {
        guard let app = appsByID[appID] else { return nil }
        return FinderFolders.key(forAppPath: app.url.path, homeDirectory: homeDirectory)
    }

    func finderName(_ path: String) -> String {
        if let cached = finderNameCache[path] { return cached }
        let name = finderNameResolver(path)
        finderNameCache[path] = name
        return name
    }
}
