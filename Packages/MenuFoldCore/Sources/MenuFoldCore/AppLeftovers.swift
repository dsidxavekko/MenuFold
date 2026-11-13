import Foundation

/// Bytes an item really takes on disk.
public enum DiskUsage {
    /// Allocated size of a file, or the sum over everything inside a directory (an .app bundle).
    /// Symbolic links are counted as links: they are never followed, so a link to another volume
    /// does not inflate the size. 0 when the item cannot be read.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        func size(_ v: URLResourceValues) -> Int64 {
            Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        guard values.isDirectory == true, values.isSymbolicLink != true else { return size(values) }
        var total: Int64 = 0
        // The enumerator does not descend into symbolic links.
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
                                                        options: [], errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            if let v = try? item.resourceValues(forKeys: keys), v.isDirectory != true || v.isSymbolicLink == true {
                total += size(v)
            }
        }
        return total
    }
}

/// Finds an app's support files in ~/Library for the uninstaller.
///
/// Deliberately conservative: an item is listed only when its NAME ties it to the bundle id.
/// Folders named after the app (`Application Support/Firefox`) are never matched: sibling apps
/// (Firefox Developer Edition, Nightly, …) share them, and the name says nothing about which app
/// owns the data. Trashing someone else's data is far worse than leaving a few files behind, so
/// anything ambiguous is skipped:
/// - apps whose bundle id starts with `com.apple.` get nothing (system data is shared);
/// - `<id>.<suffix>.plist`-style matches skip a suffix that is itself another installed app
///   (`com.foo.App` must not take `com.foo.App.beta`'s files);
/// - nothing is ever reached through a symbolic link that leaves ~/Library.
public struct AppLeftovers: Sendable {
    /// The user's Library folder (injectable for tests).
    public let library: URL

    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)) {
        self.library = library
    }

    /// Support files of the app with `bundleID` at `appURL`. `otherBundleIDs`: the other installed
    /// apps, whose files must never be matched by a prefix. Sorted by path.
    /// `appURL` is not used for matching (see the type's comment); it stays for API stability.
    public func find(bundleID: String, appURL: URL, otherBundleIDs: Set<String> = []) -> [Leftover] {
        let id = bundleID
        guard Self.isPlausibleBundleID(id), !id.lowercased().hasPrefix("com.apple.") else { return [] }
        var urls: [URL] = []
        func add(_ relative: String) { urls.append(library.appendingPathComponent(relative)) }

        // Exact names.
        add("Preferences/\(id).plist")
        add("Caches/\(id)")
        add("HTTPStorages/\(id)")
        add("HTTPStorages/\(id).binarycookies")
        add("Cookies/\(id).binarycookies")
        add("WebKit/\(id)")
        add("Saved Application State/\(id).savedState")
        add("Containers/\(id)")
        add("Application Scripts/\(id)")
        add("Logs/\(id)")
        add("Application Support/\(id)")

        // "<id>.<something>.plist" (helper prefs, per-host prefs, launch agents).
        for dir in ["Preferences", "Preferences/ByHost", "LaunchAgents"] {
            for name in contents(of: dir) where name.hasSuffix(".plist") {
                let stem = String(name.dropLast(".plist".count))
                if dir == "LaunchAgents", stem == id { add("\(dir)/\(name)"); continue }
                guard stem.hasPrefix(id + "."), !belongsToOtherApp(stem, id: id, others: otherBundleIDs) else { continue }
                add("\(dir)/\(name)")
            }
        }

        // Group containers: "<TEAMID>.<id>" or "group.<id>".
        for name in contents(of: "Group Containers") where name.hasSuffix("." + id) {
            let prefix = name.dropLast(id.count + 1)
            if !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                add("Group Containers/\(name)")
            }
        }

        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted && isSafeItem($0) }
            .sorted { $0.path < $1.path }
            .map { Leftover(url: $0.standardizedFileURL, size: DiskUsage.allocatedSize(of: $0)) }
    }

    // MARK: Rules

    /// Letters, digits, ".", "-", "_" and at least one dot, so a bare word ("Safari") never matches.
    static func isPlausibleBundleID(_ id: String) -> Bool {
        guard id.contains("."), !id.hasPrefix("."), !id.hasSuffix("."), !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    /// `stem` ("com.foo.App.beta.something") is, or lives under, another installed app's id.
    private func belongsToOtherApp(_ stem: String, id: String, others: Set<String>) -> Bool {
        others.contains { other in
            other != id && other.count > id.count && (stem == other || stem.hasPrefix(other + "."))
        }
    }

    // MARK: File system

    private func contents(of relativeDir: String) -> [String] {
        let dir = library.appendingPathComponent(relativeDir, isDirectory: true)
        guard isInsideLibrary(dir) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// The item exists (as itself: a symlink counts, its target is not looked at) and its parent
    /// folder resolves to a place inside ~/Library, so a linked `Caches` cannot lead elsewhere.
    private func isSafeItem(_ url: URL) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return false }
        return isInsideLibrary(url.deletingLastPathComponent())
    }

    private func isInsideLibrary(_ dir: URL) -> Bool {
        let root = library.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = dir.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root || resolved.hasPrefix(root + "/")
    }
}
