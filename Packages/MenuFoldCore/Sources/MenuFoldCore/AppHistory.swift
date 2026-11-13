import Foundation

/// When each app was first seen in the catalog and last launched (never decays, unlike `UsageStats`).
/// Stored in `history.json` next to layout.json.
/// Entries of uninstalled apps are kept, so a reinstalled app is not "new" again.
public struct AppHistory: Codable, Equatable, Sendable {
    /// Bundle ID → first time the catalog listed it. On the very first run every app gets
    /// `.distantPast`, so nothing is marked new.
    public var firstSeen: [String: Date]
    /// Bundle ID → last launch (from MenuFold or anywhere else).
    public var lastLaunched: [String: Date]
    /// New apps the user already opened from MenuFold (`GridModel.markSeen`). Kept apart from
    /// `lastLaunched`, which feeds "Недавні": activating an already running app is not a launch.
    /// Pruned once an app is older than `newAppInterval`, since it cannot be new any more.
    public var seen: Set<String>

    /// How long an app counts as new after it first appeared.
    public static let newAppInterval: TimeInterval = 7 * 24 * 3600

    public init(firstSeen: [String: Date] = [:], lastLaunched: [String: Date] = [:], seen: Set<String> = []) {
        self.firstSeen = firstSeen
        self.lastLaunched = lastLaunched
        self.seen = seen
    }

    private enum CodingKeys: String, CodingKey { case firstSeen, lastLaunched, seen }

    /// Missing keys keep their defaults, so files from older/newer versions load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstSeen = try c.decodeIfPresent([String: Date].self, forKey: .firstSeen) ?? [:]
        lastLaunched = try c.decodeIfPresent([String: Date].self, forKey: .lastLaunched) ?? [:]
        seen = try c.decodeIfPresent(Set<String>.self, forKey: .seen) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(firstSeen, forKey: .firstSeen)
        try c.encode(lastLaunched, forKey: .lastLaunched)
        try c.encode(seen.sorted(), forKey: .seen)
    }
}

/// Loads/saves `AppHistory` as JSON with atomic writes.
///
/// A missing file gives an empty history (first run). A file that does not decode is moved aside
/// to `history.corrupt-<date>.json` (kept for inspection, like a corrupt layout) and also gives an
/// empty history. A file that exists but cannot be read (permissions, I/O) gives an empty history
/// with `lastLoadUnreadable` set: the file may be fine, so `GridModel` must not save over it.
public final class AppHistoryStore: @unchecked Sendable {
    public let fileURL: URL
    public static var defaultURL: URL {
        LayoutStore.defaultURL.deletingLastPathComponent().appendingPathComponent("history.json")
    }
    /// True when the last `load()` found a file it could not read (not a missing or corrupt one).
    public private(set) var lastLoadUnreadable = false

    public init(fileURL: URL = AppHistoryStore.defaultURL) { self.fileURL = fileURL }

    public func load() -> AppHistory {
        lastLoadUnreadable = false
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppHistory() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            NSLog("%@", "MenuFold: could not read app history, leaving the file alone: \(error.localizedDescription)")
            lastLoadUnreadable = true
            return AppHistory()
        }
        do {
            return try JSONDecoder().decode(AppHistory.self, from: data)
        } catch {
            NSLog("%@", "MenuFold: app history is corrupt, moving it aside: \(error)")
            moveAside()
            return AppHistory()
        }
    }

    /// Renames the file to `history.corrupt-<date>.json` in the same folder (a number is added if
    /// that name is taken). If the move fails the next save simply replaces the corrupt file.
    private func moveAside() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let dir = fileURL.deletingLastPathComponent()
        let stamp = f.string(from: Date())
        var dest = dir.appendingPathComponent("history.corrupt-\(stamp).json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("history.corrupt-\(stamp)-\(n).json")
            n += 1
        }
        do { try FileManager.default.moveItem(at: fileURL, to: dest) } catch {
            NSLog("%@", "MenuFold: could not move the corrupt app history aside: \(error.localizedDescription)")
        }
    }

    public func save(_ history: AppHistory) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(history).write(to: fileURL, options: .atomic)
    }
}
