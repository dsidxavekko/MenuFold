import Foundation

/// Launch statistics for Settings → Статистика: per day, per app, how many times it was opened.
/// Only aggregates are kept (no launch timestamps), and days older than `retentionDays` are dropped.
/// Stored in `usage-log.json` in the default support folder, never in a synced data folder:
/// it is per-Mac data. The `enabled` switch lives in the file too.
public struct UsageLog: Codable, Equatable, Sendable {
    /// "yyyy-MM-dd" (local calendar) → bundle ID → launches that day.
    public var days: [String: [String: Int]]
    /// Whether launches are recorded at all.
    public var enabled: Bool

    public static let retentionDays = 366

    public init(days: [String: [String: Int]] = [:], enabled: Bool = true) {
        self.days = days
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case days, enabled }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = try c.decodeIfPresent([String: [String: Int]].self, forKey: .days) ?? [:]
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The key of `date`'s day.
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The start of the day a key stands for (nil for a malformed key).
    public static func date(forKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Adds one launch of `id` on `date`'s day (does nothing while disabled) and drops old days.
    @discardableResult
    public mutating func record(_ id: String, at date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        days[Self.dayKey(date, calendar: calendar), default: [:]][id, default: 0] += 1
        prune(at: date, calendar: calendar)
        return true
    }

    /// Drops days older than `retentionDays` and malformed keys.
    public mutating func prune(at date: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: date) else { return }
        let cutoffKey = Self.dayKey(cutoff, calendar: calendar)
        days = days.filter { $0.key >= cutoffKey && Self.date(forKey: $0.key, calendar: calendar) != nil }
    }

    /// Launches of `id` over all kept days.
    public func total(for id: String) -> Int {
        days.values.reduce(0) { $0 + ($1[id] ?? 0) }
    }

    public var isEmpty: Bool { days.isEmpty }
}

/// Loads/saves `UsageLog`. A missing or damaged file gives an empty (enabled) log: it is only statistics.
public final class UsageLogStore: @unchecked Sendable {
    public let fileURL: URL

    public static var defaultURL: URL {
        LayoutStore.defaultURL.deletingLastPathComponent().appendingPathComponent("usage-log.json")
    }

    public init(fileURL: URL = UsageLogStore.defaultURL) { self.fileURL = fileURL }

    public func load() -> UsageLog {
        guard let data = try? Data(contentsOf: fileURL) else { return UsageLog() }
        return (try? JSONDecoder().decode(UsageLog.self, from: data)) ?? UsageLog()
    }

    public func save(_ log: UsageLog) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(log).write(to: fileURL, options: .atomic)
    }
}

/// Observable owner of the log, used by the app shell (records launches) and Settings (shows them).
@MainActor @Observable
public final class UsageLogger {
    public static let shared = UsageLogger()

    public private(set) var log: UsageLog
    @ObservationIgnored private let store: UsageLogStore
    @ObservationIgnored private var lastRecorded: [String: Date] = [:]
    @ObservationIgnored private let now: () -> Date

    /// A second launch of the same app within this interval is the same launch (MenuFold's own
    /// launch is also reported by NSWorkspace).
    public static let dedupeInterval: TimeInterval = UsageStats.dedupeInterval

    public init(store: UsageLogStore = UsageLogStore(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        self.log = store.load()
    }

    public var isEnabled: Bool {
        get { log.enabled }
        set {
            guard newValue != log.enabled else { return }
            log.enabled = newValue
            save()
        }
    }

    public func record(appID: String) {
        guard log.enabled else { return }
        let date = now()
        if let last = lastRecorded[appID], date.timeIntervalSince(last) >= 0,
           date.timeIntervalSince(last) < Self.dedupeInterval { return }
        lastRecorded[appID] = date
        if log.record(appID, at: date) { save() }
    }

    /// Erases all collected statistics (the on/off switch stays).
    public func erase() {
        log.days = [:]
        lastRecorded = [:]
        save()
    }

    public func totalLaunches(of appID: String) -> Int { log.total(for: appID) }

    public func report(topCount: Int = 10) -> UsageReport {
        UsageReport.make(from: log, now: now(), topCount: topCount)
    }

    private func save() {
        do { try store.save(log) } catch {
            NSLog("%@", "MenuFold: failed to save the usage statistics: \(error.localizedDescription)")
        }
    }
}
