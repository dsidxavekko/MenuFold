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

    /// Drops: no bundle ID, MenuFold itself, apps nested in another bundle (.app/.framework/…),
    /// /System/Library/CoreServices/** (except Finder and CoreServices/Applications/*),
    /// anything else under /System/Library, /Library or ~/Library.
    /// De-duplicates by bundle ID preferring /Applications, /System/Applications, ~/Applications, then newest.
    /// Result is sorted by name (localizedStandardCompare).
    public static func filter(_ candidates: [AppCandidate], homeDirectory: String = NSHomeDirectory()) -> [AppEntry] {
        var best: [String: AppCandidate] = [:]
        for var c in candidates {
            c.path = normalize(c.path)
            guard let id = c.bundleID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { continue }
            c.bundleID = id
            guard id != ownBundleID, isAllowed(path: c.path, homeDirectory: homeDirectory) else { continue }
            if let existing = best[id] {
                if isPreferred(c, over: existing, homeDirectory: homeDirectory) { best[id] = c }
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

    /// Strips trailing "/" and the Data-volume firmlink prefix.
    static func normalize(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let data = "/System/Volumes/Data"
        if p.hasPrefix(data + "/") { p.removeFirst(data.count) }
        return p
    }

    /// Bundle-like directory extensions: an app inside any of these is a helper, not a user app.
    static let bundleExtensions = [".app", ".framework", ".bundle", ".plugin", ".appex", ".xpc", ".prefpane", ".kext", ".systemextension"]

    static func isAllowed(path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let components = path.split(separator: "/")
        // Any bundle component before the last one → helper nested inside another bundle.
        if components.dropLast().contains(where: { c in
            let lower = c.lowercased()
            return bundleExtensions.contains { lower.hasSuffix($0) }
        }) { return false }
        if path.hasPrefix(coreServicesPrefix) {
            if coreServicesWhitelist.contains(path) { return true }
            if path.hasPrefix(coreServicesAppsPrefix) { return true }
            return false
        }
        // Library folders hold agents / input methods / support helpers, never user-facing apps.
        let home = normalize(homeDirectory)
        if path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/") || path.hasPrefix(home + "/Library/") {
            return false
        }
        return true
    }

    static func rank(_ path: String, homeDirectory: String) -> Int {
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix("/System/Applications/") { return 1 }
        let home = normalize(homeDirectory)
        if path.hasPrefix(home + "/Applications/") { return 2 }
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
