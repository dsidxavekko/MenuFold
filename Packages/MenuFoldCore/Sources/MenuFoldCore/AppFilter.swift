import Foundation

/// Raw application found on disk, before filtering / de-duplication.
public struct AppCandidate: Hashable, Sendable {
    public var path: String
    public var bundleID: String?
    public var name: String
    public var infoCategory: String?
    public var modificationDate: Date?

    public init(path: String, bundleID: String?, name: String, infoCategory: String?, modificationDate: Date?) {
        self.path = path
        self.bundleID = bundleID
        self.name = name
        self.infoCategory = infoCategory
        self.modificationDate = modificationDate
    }
}

/// Pure filtering rules for the app catalog.
public enum AppFilter {
    public static let ownBundleID = "com.menufold.MenuFold"

    /// Apps under /System/Library/CoreServices that stay visible.
    public static let coreServicesWhitelist: Set<String> = [
        "/System/Library/CoreServices/Finder.app",
    ]
    static let coreServicesPrefix = "/System/Library/CoreServices/"
    static let coreServicesAppsPrefix = "/System/Library/CoreServices/Applications/"

    /// Top-level locations whose apps are not user apps: other volumes (external disks, Time
    /// Machine backups), temp dirs and the Trash. Backup and temp copies must never show in the grid.
    static let excludedRoots = ["/Volumes", "/private/tmp", "/private/var/tmp", "/private/var/folders", "/tmp", "/var/tmp"]

    /// Drops: no bundle ID, MenuFold itself, apps nested in another bundle (.app/.framework/…),
    /// /System/Library/CoreServices/** (except Finder and CoreServices/Applications/*),
    /// anything else under /System/Library, /Library or ~/Library, apps on other volumes
    /// (/Volumes), in temp directories or in the Trash.
    /// De-duplicates by bundle ID preferring /Applications, /System/Applications, ~/Applications, then newest.
    /// Result is sorted by name (localizedStandardCompare).
    public static func filter(_ candidates: [AppCandidate], homeDirectory: String = NSHomeDirectory()) -> [AppEntry] {
        let home = normalizeHome(homeDirectory)
        let tempRoots = excludedRoots + [NSTemporaryDirectory()]
        var best: [String: AppCandidate] = [:]
        for var c in candidates {
            c.path = normalize(c.path)
            guard let id = c.bundleID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { continue }
            c.bundleID = id
            guard id != ownBundleID, isAllowed(path: c.path, homeDirectory: home, tempRoots: tempRoots) else { continue }
            if let existing = best[id] {
                if isPreferred(c, over: existing, homeDirectory: home) { best[id] = c }
            } else {
                best[id] = c
            }
        }
        return best.values
            .map { c in
                AppEntry(id: c.bundleID!, name: c.name, url: URL(fileURLWithPath: c.path, isDirectory: true), infoCategory: c.infoCategory)
            }
            .sorted { lhs, rhs in
                let r = lhs.name.localizedStandardCompare(rhs.name)
                return r == .orderedSame ? lhs.id < rhs.id : r == .orderedAscending
            }
    }

    /// Strips trailing "/", the Data-volume firmlink prefix and "." components;
    /// returns "" for a path that is not absolute or whose ".." escapes the root (such a path is
    /// rejected by `isAllowed`).
    static func normalize(_ path: String) -> String {
        guard let standardized = FinderFolders.standardized(path) else { return "" }
        // Same prefix stretch FinderFolders uses, so "/System/Volumes/Data/Applications/X.app" and
        // "/Applications/X.app" are the same path everywhere (dedupe, ranking, CoreServices rules).
        return FinderFolders.normalize(standardized)
    }

    /// Home directory as a clean absolute path: "" and "/" both mean "no home root".
    static func normalizeHome(_ homeDirectory: String) -> String {
        guard let standardized = FinderFolders.standardized(homeDirectory), standardized != "/" else { return "" }
        return standardized
    }

    /// Bundle-like directory extensions: an app inside any of these is a helper, not a user app.
    static let bundleExtensions = [".app", ".framework", ".bundle", ".plugin", ".appex", ".xpc", ".prefpane", ".kext", ".systemextension"]

    static func isAllowed(path: String, homeDirectory: String = NSHomeDirectory(), tempRoots: [String] = []) -> Bool {
        let p = normalize(path)
        // Not absolute, or a ".." that climbs above "/": no such app can be shown safely.
        guard !p.isEmpty else { return false }
        let components = p.split(separator: "/")
        // Any bundle component before the last one → helper nested inside another bundle.
        if components.dropLast().contains(where: { c in
            let lower = c.lowercased()
            return bundleExtensions.contains { lower.hasSuffix($0) }
        }) { return false }
        if p.hasPrefix(coreServicesPrefix) {
            if coreServicesWhitelist.contains(p) { return true }
            if p.hasPrefix(coreServicesAppsPrefix) { return true }
            return false
        }
        // Library folders hold agents / input methods / support helpers, never user-facing apps.
        let home = normalizeHome(homeDirectory)
        let libraryRoots = ["/System/Library/", "/Library/"] + (home.isEmpty ? [] : [home + "/Library/"])
        if libraryRoots.contains(where: p.hasPrefix) { return false }
        // Other volumes, temp dirs and the Trash: backup copies and throw-away bundles.
        if excludedRoots.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
        if tempRoots.contains(where: { !$0.isEmpty && (p == $0 || p.hasPrefix($0 + "/")) }) { return false }
        let trashRoots = ["/.Trashes"] + (home.isEmpty ? [] : [home + "/.Trash"])
        if trashRoots.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) { return false }
        return true
    }

    static func rank(_ path: String, homeDirectory: String) -> Int {
        let p = normalize(path)
        if p.hasPrefix("/Applications/") { return 0 }
        if p.hasPrefix("/System/Applications/") { return 1 }
        let home = normalizeHome(homeDirectory)
        if !home.isEmpty, p.hasPrefix(home + "/Applications/") { return 2 }
        return 3
    }

    static func isPreferred(_ a: AppCandidate, over b: AppCandidate, homeDirectory: String) -> Bool {
        let ra = rank(a.path, homeDirectory: homeDirectory), rb = rank(b.path, homeDirectory: homeDirectory)
        if ra != rb { return ra < rb }
        let da = a.modificationDate ?? .distantPast, db = b.modificationDate ?? .distantPast
        if da != db { return da > db }
        return a.path < b.path // deterministic tiebreak
    }
}
