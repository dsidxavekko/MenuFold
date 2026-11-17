import Foundation

/// How often each app is opened ("frecency"), for the "Часті" row. Stored in its own file
/// (`usage.json`), apart from `layout.json`, so resetting or quarantining the layout keeps it.
/// Each use adds 1 to a score that halves every `halfLife`; the row shows the highest scores.
public struct UsageStats: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Score as of `lastUsed` (decay is applied on read and on the next use).
        public var score: Double
        public var lastUsed: Date
        public init(score: Double, lastUsed: Date) {
            self.score = score
            self.lastUsed = lastUsed
        }
    }

    /// Bundle ID → entry.
    public var entries: [String: Entry]

    /// A score halves every 7 days.
    public static let halfLife: TimeInterval = 7 * 24 * 3600
    /// A second use of the same app within this interval is ignored (a launch from MenuFold is
    /// also reported by NSWorkspace's did-launch notification).
    public static let dedupeInterval: TimeInterval = 10
    /// Entries whose score decayed below this are dropped on the next `record`.
    public static let forgetBelow = 0.01

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// Records one use at `date`. Returns false when it was ignored as a duplicate.
    @discardableResult
    public mutating func record(_ id: String, at date: Date) -> Bool {
        if let entry = entries[id] {
            let dt = date.timeIntervalSince(entry.lastUsed)
            if dt >= 0, dt < Self.dedupeInterval { return false }
            entries[id] = Entry(score: Self.decayed(entry, at: date) + 1, lastUsed: date)
        } else {
            entries[id] = Entry(score: 1, lastUsed: date)
        }
        // Forget apps not used for about six weeks (score below 0.01), so the file stays small.
        entries = entries.filter { Self.decayed($0.value, at: date) >= Self.forgetBelow }
        return true
    }

    /// Records one use without the duplicate check (the caller already did it).
    mutating func recordForced(_ id: String, at date: Date) {
        if let entry = entries[id] {
            entries[id] = Entry(score: Self.decayed(entry, at: date) + 1, lastUsed: max(date, entry.lastUsed))
        } else {
            entries[id] = Entry(score: 1, lastUsed: date)
        }
    }

    /// Several devices' stats as one: per app the decayed scores are added (each device's use is
    /// counted once), and the latest use wins.
    public static func combined(_ parts: [UsageStats]) -> UsageStats {
        var result = UsageStats()
        let ids = Set(parts.flatMap { $0.entries.keys })
        for id in ids {
            let entries = parts.compactMap { $0.entries[id] }
            guard let last = entries.map(\.lastUsed).max() else { continue }
            let score = entries.reduce(0) { $0 + decayed($1, at: last) }
            result.entries[id] = Entry(score: score, lastUsed: last)
        }
        return result
    }

    /// The decayed score of `id` at `date` (0 if never used).
    public func score(of id: String, at date: Date) -> Double {
        entries[id].map { Self.decayed($0, at: date) } ?? 0
    }

    /// `entry.score` decayed from `entry.lastUsed` to `date`; a date before `lastUsed` counts as no time.
    private static func decayed(_ entry: Entry, at date: Date) -> Double {
        let dt = max(0, date.timeIntervalSince(entry.lastUsed))
        return entry.score * pow(0.5, dt / halfLife)
    }

    /// Up to `n` ids from `ids` with the highest current score (> 0), highest first; ties by id.
    public func top(_ n: Int, among ids: Set<String>, at date: Date) -> [String] {
        guard n > 0 else { return [] }
        let scored = ids.compactMap { id -> (String, Double)? in
            let s = score(of: id, at: date)
            return s > 0 ? (id, s) : nil
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            .prefix(n)
            .map(\.0)
    }
}

/// Loads/saves `UsageStats` as JSON with atomic writes. A missing or unreadable/undecodable file
/// gives empty stats (no quarantine: the data is only a convenience).
///
/// With a `deviceID` (a data folder shared between Macs) the file holds one `UsageStats` per device
/// (`{"devices": {id: {...}}}`): `load()` returns all of them combined, `save` writes only this
/// device's part and keeps the others as they are on disk, so uses are never counted twice and no
/// Mac overwrites another's numbers. A plain file (`{"entries": …}`) read in that mode counts as one
/// extra device ("legacy"), which makes a copy of an old usage.json work as a starting point.
public final class UsageStore: @unchecked Sendable {
    public let fileURL: URL
    public let deviceID: String?
    private let lock = NSLock()
    /// This device's own part and the last combined value handed out (device mode only).
    private var own = UsageStats()
    private var lastCombined = UsageStats()

    private struct DevicesFile: Codable {
        var devices: [String: UsageStats]
    }

    /// ~/Library/Application Support/MenuFold/usage.json
    public static var defaultURL: URL {
        LayoutStore.defaultURL.deletingLastPathComponent().appendingPathComponent("usage.json")
    }

    public init(fileURL: URL = UsageStore.defaultURL, deviceID: String? = nil) {
        self.fileURL = fileURL
        self.deviceID = deviceID
    }

    /// Reads the per-device parts (device mode). Nil when the file is unreadable.
    private func readDevices() -> [String: UsageStats]? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        if let file = try? JSONDecoder().decode(DevicesFile.self, from: data) { return file.devices }
        if let legacy = try? JSONDecoder().decode(UsageStats.self, from: data) { return ["legacy": legacy] }
        // Present but undecodable (half-synced, other version): never treat it as empty, or the
        // next save would erase the other devices' parts.
        return nil
    }

    public func load() -> UsageStats {
        if let deviceID {
            lock.lock(); defer { lock.unlock() }
            guard let devices = readDevices() else { return lastCombined }
            if let mine = devices[deviceID] { own = mine }
            lastCombined = UsageStats.combined(Array(devices.filter { $0.key != deviceID }.values) + [own])
            return lastCombined
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return UsageStats() }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            NSLog("%@", "MenuFold: could not read usage stats, starting empty: \(error.localizedDescription)")
            return UsageStats()
        }
        do {
            return try JSONDecoder().decode(UsageStats.self, from: data)
        } catch {
            NSLog("%@", "MenuFold: usage stats are corrupt, starting empty: \(error)")
            return UsageStats()
        }
    }

    public func save(_ stats: UsageStats) throws {
        if let deviceID {
            try saveDevice(stats, deviceID: deviceID)
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(stats)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension UsageStore {
    /// Device mode: finds what changed between the combined stats handed out last and `stats`
    /// (one more use of an app, or everything cleared) and applies it to this device's part only.
    fileprivate func saveDevice(_ stats: UsageStats, deviceID: String) throws {
        lock.lock(); defer { lock.unlock() }
        if stats.entries.isEmpty {
            own = UsageStats()
        } else {
            for (id, entry) in stats.entries where lastCombined.entries[id]?.lastUsed != entry.lastUsed {
                own.recordForced(id, at: entry.lastUsed)
            }
        }
        lastCombined = stats
        // Other devices' parts are re-read, so a change that arrived meanwhile is kept.
        guard var devices = readDevices() else { return }
        devices[deviceID] = own
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(DevicesFile(devices: devices)).write(to: fileURL, options: .atomic)
    }
}
