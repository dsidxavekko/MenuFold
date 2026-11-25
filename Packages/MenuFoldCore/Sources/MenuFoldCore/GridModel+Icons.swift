import Foundation
import Observation
import AppKit

extension GridModel {
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
    /// The previous icon file is left on disk, so undo can bring it back; the next launch's cleanup
    /// (`removeUnusedIconFiles`) deletes it once nothing points at it.
    public func setCustomIcon(for appID: String, from source: URL) throws {
        let data = try CustomIcons.pngData(from: source)
        try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        try data.write(to: iconsDirectory.appendingPathComponent(name), options: .atomic)
        var l = layout
        l.customIcons[appID] = name
        try commitPersisting(l)
    }

    /// Goes back to the app's own icon. The old file stays for undo (see `setCustomIcon`).
    public func resetCustomIcon(for appID: String) {
        var l = layout
        guard l.customIcons.removeValue(forKey: appID) != nil else { return }
        commit(l)
    }

    /// Deletes icon files that no layout entry points at (left over after a reset, an icon change
    /// or a crash). Runs only at launch after a real load: undo lives in memory, so after a relaunch
    /// nothing can bring an unreferenced file back.
    ///
    /// Only files MenuFold names itself (`<UUID>.png`) are touched, so anything else a user or
    /// another tool put into the folder survives. Nothing runs for a shared (synced) folder:
    /// another Mac's new icon may arrive before the layout.json that refers to it.
    /// Files modified less than a minute ago are kept: another MenuFold instance (two copies can
    /// run at once) may have just written an icon for a layout this process has not read yet.
    func removeUnusedIconFiles() {
        guard store?.isShared != true else { return }
        // Icons named by the undo steps restored from the last launch stay too.
        var used = Set(layout.customIcons.values).union(undoStack.flatMap { $0.customIcons.values })
        used.formUnion(iconsReferencedByBackups())
        let fresh = Date().addingTimeInterval(-60)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: iconsDirectory.path)) ?? []
        for file in files where Self.isOwnIconFileName(file) && !used.contains(file) {
            let url = iconsDirectory.appendingPathComponent(file)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let modified = attrs[.modificationDate] as? Date, modified > fresh { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Icon file names named by Backups/layout-*.json, layout.bak/.bak2 and layout.corrupt-*: restoring
    /// any of them must not find its icons gone. Reads only the `customIcons` field, and skips
    /// files above the size limit.
    func iconsReferencedByBackups() -> Set<String> {
        guard let store = layoutStore else { return [] }
        let fm = FileManager.default
        let dir = store.fileURL.deletingLastPathComponent()
        let stem = store.fileURL.deletingPathExtension().lastPathComponent
        var urls: [URL] = []
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        where name == stem + ".bak" || name == stem + ".bak2" || (name.hasPrefix(stem + ".corrupt-") && name.hasSuffix(".json")) {
            urls.append(dir.appendingPathComponent(name))
        }
        if let backups = backupsDirectory {
            for name in (try? fm.contentsOfDirectory(atPath: backups.path)) ?? []
            where name.hasPrefix("layout-") && name.hasSuffix(".json") {
                urls.append(backups.appendingPathComponent(name))
            }
        }
        struct IconsOnly: Decodable { var customIcons: [String: String]? }
        var result = Set<String>()
        for url in urls {
            guard let data = try? LayoutStore.readLimited(url),
                  let icons = try? JSONDecoder().decode(IconsOnly.self, from: data).customIcons else { continue }
            result.formUnion(icons.values)
        }
        return result
    }

    /// `<UUID>.png`: the only names `setCustomIcon` and imports ever write.
    static func isOwnIconFileName(_ name: String) -> Bool {
        guard name.hasSuffix(".png") else { return false }
        return UUID(uuidString: String(name.dropLast(".png".count))) != nil
    }
}
