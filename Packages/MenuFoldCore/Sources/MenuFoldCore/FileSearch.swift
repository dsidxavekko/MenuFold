import Foundation

// MARK: - Item

/// One file or document a search turned up.
///
/// The id is the path, not a fresh UUID: the same file reported twice stays one row, and the panel
/// can keep a picked row in the same selection state it uses for apps ("file:<path>"). Nothing here
/// touches the disk — a provider reads the name, date and size once and the rows only render them,
/// so scrolling never waits for Spotlight.
public struct FileItem: Identifiable, Hashable, Sendable {
    public let url: URL
    /// Name as Finder shows it: the last path component, or the localized name a provider read.
    public let name: String
    /// When the file was last changed; nil when the provider could not read it, so a row stays
    /// silent about the date instead of showing a made-up one.
    public let modified: Date?
    /// Size in bytes; nil for the same reason as `modified`.
    public let size: Int64?

    public init(url: URL, name: String = "", modified: Date? = nil, size: Int64? = nil) {
        self.url = url
        // A provider that fails to read a display name still gets a usable row instead of a blank one.
        self.name = name.isEmpty ? url.lastPathComponent : name
        self.modified = modified
        self.size = size
    }

    /// Stable row id, also the key the panel stores: the path, so re-running a query keeps the selection.
    public var id: String { url.path }

    /// Folder the item lies in, without a trailing slash ("/Users/me/Documents" for
    /// "/Users/me/Documents/report.pdf"): rows show it on their second line.
    public var parentPath: String { url.deletingLastPathComponent().path }

    /// `url.path` with the home folder written as "~", so the second line of a row fits the panel
    /// ("~/Documents/…" instead of the full user path).
    public var displayPath: String {
        let path = url.path
        let home = Self.homePath
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        // Matched, not counted: APFS is case-insensitive by default and a file system may hand back
        // names in another normalization, so the shortened form follows the range that really matched.
        guard let range = path.range(of: home, options: [.anchored, .caseInsensitive, .diacriticInsensitive]),
              path[range.upperBound...].hasPrefix("/") else { return path }
        return "~" + path[range.upperBound...]
    }

    /// Whether Finder hides it (a leading dot). A file search never offers those.
    public var isHiddenName: Bool { name.hasPrefix(".") }

    /// Whether it is an application bundle. The grid already shows apps, so a file search skips them.
    public var isAppBundle: Bool { url.pathExtension.lowercased() == "app" }

    /// Home folder without a trailing slash, "" when there is none. Shared by `displayPath` and
    /// `FileSearch`, so "~" means the same folder in both.
    static var homePath: String {
        let home = NSHomeDirectory()
        guard home.count > 1, home.hasPrefix("/") else { return "" }
        return home.hasSuffix("/") ? String(home.dropLast()) : home
    }
}

// MARK: - Query

/// What a file query asks of the panel. The app search keeps its own prefixes (`>`, `/`, `@`, `?`),
/// so this one only decides whether the typed text means "files" or "the usual grid".
public enum FileScope: Equatable, Sendable {
    /// No file prefix: apps and folders, exactly as before.
    case everything
    /// `~` or `file:`: files and documents instead of apps.
    case filesOnly
}

/// Splits the file prefix off a raw search field text.
///
/// The prefix has two spellings: `~`, which is quick to type, and `file:`, which is readable and
/// cannot be confused with a word — the colon keeps "filezilla" an ordinary query. Spaces around
/// the prefix are dropped first, so a pasted or space-led query still works, and the scope survives
/// an empty text so the panel can keep offering files while the field holds only the prefix.
public enum FileSearchQuery {
    /// Quick form of the prefix.
    public static let prefix = "~"
    /// Readable form of the prefix, matched ignoring case.
    public static let wordPrefix = "file:"

    /// Scope asked for by `raw` and the text left to match.
    public static func parse(_ raw: String) -> (scope: FileScope, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func rest(_ s: Substring) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.hasPrefix(prefix) {
            return (.filesOnly, rest(trimmed.dropFirst(prefix.count)))
        }
        if trimmed.lowercased().hasPrefix(wordPrefix) {
            return (.filesOnly, rest(trimmed.dropFirst(wordPrefix.count)))
        }
        return (.everything, trimmed)
    }
}

// MARK: - Ranking and filter

/// The pure heart of the file search: which files may be offered, how well they match and in which
/// order they come back. The provider that runs Spotlight and the view that draws the rows stay
/// outside, so every rule here is a function of its arguments and testable without a disk.
public enum FileSearch {
    /// Files shown under a query by default: enough to be useful below the app results, few enough
    /// that the panel never scrolls for a two-letter query.
    public static let defaultLimit = 8
    /// Hard ceiling, whatever a caller asks for: a broad Spotlight query must not be able to fill
    /// the panel with hundreds of rows.
    public static let maxLimit = 20

    /// The files matching `query`, best first, at most `limit` of them (and at most `maxLimit`).
    ///
    /// Scores come from `SearchMatcher`, the same tiers as the app search, plus a small bonus when
    /// the query is the name without its extension: "notes" is what the user means when "Notes.md"
    /// and "Notes-2024.txt" both match. The bonus is capped inside its tier, so a boosted prefix
    /// match can never outrank an exact one. Ties go to the fresher file, then to the name, then to
    /// the path, so the order never depends on the order the provider happened to return.
    ///
    /// An empty query gives no results: the panel would be showing an arbitrary sample of the disk.
    /// Items are expected to have passed `isCandidate` (the provider filters while Spotlight streams).
    public static func rank(_ items: [FileItem], query: String, limit: Int = FileSearch.defaultLimit) -> [FileItem] {
        let room = min(max(limit, 0), maxLimit)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard room > 0, !text.isEmpty else { return [] }
        // Prepared once: folding the query (and its keyboard-layout twin) per candidate would repeat
        // the same work for every file.
        let prepared = SearchMatcher.Query(text)
        var scored: [(item: FileItem, score: Double)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            guard let raw = SearchMatcher.score(item.name, prepared) else { continue }
            let boosted = raw + stemBonus(for: item.name, query: prepared.direct)
            scored.append((item, min(boosted, tierCeiling(raw))))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // A missing date counts as ancient: it must not win freshness ties by accident.
            let left = lhs.item.modified ?? .distantPast
            let right = rhs.item.modified ?? .distantPast
            if left != right { return left > right }
            let byName = lhs.item.name.localizedStandardCompare(rhs.item.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.item.id < rhs.item.id
        }
        return scored.prefix(room).map(\.item)
    }

    /// Whether a found file is worth showing. The provider calls this on every Spotlight hit, so it
    /// is pure, cheap, and looks at the path only (it never reads the file system).
    ///
    /// Rejected: hidden names, application bundles (the grid shows apps already), folders (this
    /// search is about files and documents), anything inside a bundle, and the parts of the disk
    /// that only mirror apps or cache data — `~/Library`, `~/Applications`, the Trash,
    /// `Library/Developer`, `.git`, `node_modules`, `.build`. Spotlight skips most of those by
    /// itself; the filter is here so a provider that widens its query cannot leak them into the panel.
    public static func isCandidate(_ item: FileItem) -> Bool {
        guard !item.isHiddenName, !item.isAppBundle, !item.url.hasDirectoryPath else { return false }
        let path = normalizedPath(item.url)
        guard !path.isEmpty, path != "/" else { return false }
        return !isExcluded(path: path)
    }

    // MARK: Scoring details

    /// Exact match of the name without its extension ("notes" ↔ "Notes.md"). Inside one tier that is
    /// clearly a better answer than "Notes-2024.txt", and 45 points is far below a tier (100 apart),
    /// so it never changes which kind of match wins.
    static let exactStemBonus = 45.0

    /// `exactStemBonus` when `name` minus its extension is exactly `query` (already folded).
    static func stemBonus(for name: String, query: String) -> Double {
        guard !query.isEmpty else { return 0 }
        let nsName = name as NSString
        // A dotfile has no extension, and deleting one would empty the name.
        let stem = nsName.pathExtension.isEmpty ? name : nsName.deletingPathExtension
        return SearchMatcher.fold(stem) == query ? exactStemBonus : 0
    }

    /// Top of the tier `raw` belongs to (scores are `tier * 100 + fine`), the same cap `GridModel`
    /// puts on its usage bonus: a bonus may reorder matches inside a tier, never across tiers.
    static func tierCeiling(_ raw: Double) -> Double {
        (raw / 100).rounded(.down) * 100 + 99
    }

    // MARK: Filter details

    /// Path components that hold build output or version-control data. Any depth matches, so a
    /// document inside a checkout is filtered as well.
    static let excludedComponents: Set<String> = [".git", "node_modules", ".build"]

    /// Folders that belong to apps rather than to the user's documents. `home` is "" when unknown.
    static func excludedRoots(home: String) -> [String] {
        let trash = "/.Trashes"
        guard !home.isEmpty else { return [trash] }
        return [trash, home + "/Library", home + "/Applications", home + "/.Trash"]
    }

    /// Absolute, ".."-free form of `url` (lexical only, no disk access; the Data-volume firmlink is
    /// stripped like everywhere else), "" for a relative URL: the rules compare path prefixes and
    /// components, and face the same paths the app grid does.
    static func normalizedPath(_ url: URL) -> String {
        guard let standardized = FinderFolders.standardized(url.path) else { return "" }
        return FinderFolders.normalize(standardized)
    }

    /// Whether `path` (already normalized) sits somewhere a file search must not offer.
    static func isExcluded(path: String) -> Bool {
        let lower = path.split(separator: "/").map { $0.lowercased() }
        // A file inside an app bundle is part of an app, never a document the user looks for.
        if lower.dropLast().contains(where: { FinderFolders.isBundle($0) }) { return true }
        if lower.contains(where: excludedComponents.contains) { return true }
        // Xcode caches and simulator data: any "<…>/Library/Developer" path.
        if lower.indices.dropLast().contains(where: { lower[$0] == "library" && lower[$0 + 1] == "developer" }) {
            return true
        }
        let home = FileItem.homePath
        return excludedRoots(home: home).contains { root in
            path.caseInsensitiveCompare(root) == .orderedSame || FinderFolders.hasPathPrefix(path, root + "/")
        }
    }
}

// MARK: - Provider contract

/// What the panel asks for files. An implementation must search locally — a Spotlight
/// `NSMetadataQuery` over the user's own volumes — and never a network service, a shell command or
/// a third-party index: the term changes on every keystroke, so the answer has to be fast, private
/// and available offline. It is also expected to run the disk work off the main actor, to pass its
/// hits through `FileSearch.isCandidate`, and to honour `limit`.
public protocol FileSearching: Sendable {
    func searchFiles(matching term: String, limit: Int) async -> [FileItem]
}
