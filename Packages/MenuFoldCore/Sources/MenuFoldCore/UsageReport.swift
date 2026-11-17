import Foundation

/// What Settings → Статистика shows, computed from a `UsageLog`.
public struct UsageReport: Equatable, Sendable {
    public struct Top: Equatable, Sendable, Identifiable {
        public let appID: String
        public let count: Int
        public var id: String { appID }
    }
    public struct Day: Equatable, Sendable, Identifiable {
        public let date: Date
        public let count: Int
        public var id: Date { date }
    }

    /// Launches of all kept days.
    public let totalLaunches: Int
    /// Most launched apps over `windowDays`, most first (ties by id).
    public let top: [Top]
    /// Launches per weekday over `windowDays`, index 0 = first weekday of the calendar.
    public let weekdayCounts: [Int]
    /// Calendar weekday numbers (1 = Sunday … 7) in the order of `weekdayCounts`.
    public let weekdayNumbers: [Int]
    /// One entry per day of the last `recentDays` days, oldest first (zero days included).
    public let recent: [Day]

    public static let windowDays = 90
    public static let recentDays = 30

    public static func make(from log: UsageLog, now: Date, topCount: Int = 10,
                            calendar: Calendar = .current) -> UsageReport {
        let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: now))
            ?? .distantPast
        var perApp: [String: Int] = [:]
        var perWeekday = [Int](repeating: 0, count: 7)
        var perDay: [String: Int] = [:]
        var total = 0
        for (key, apps) in log.days {
            guard let day = UsageLog.date(forKey: key, calendar: calendar) else { continue }
            let sum = apps.values.reduce(0, +)
            total += sum
            perDay[key] = sum
            guard day >= windowStart else { continue }
            let weekday = calendar.component(.weekday, from: day)
            perWeekday[weekday - 1] += sum
            for (id, n) in apps { perApp[id, default: 0] += n }
        }
        let top = perApp
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(max(0, topCount))
            .map { Top(appID: $0.key, count: $0.value) }
        let first = calendar.firstWeekday
        let numbers = (0..<7).map { (first - 1 + $0) % 7 + 1 }
        let today = calendar.startOfDay(for: now)
        let recent = (0..<recentDays).reversed().compactMap { back -> Day? in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            return Day(date: d, count: perDay[UsageLog.dayKey(d, calendar: calendar)] ?? 0)
        }
        return UsageReport(totalLaunches: total, top: top,
                           weekdayCounts: numbers.map { perWeekday[$0 - 1] },
                           weekdayNumbers: numbers, recent: recent)
    }

    /// Ids from `ids` not opened for `days` days (or never), by `lastUsed`. Ids first seen within
    /// that period are not reported (`firstSeen`): they were only just installed.
    public static func notOpened(ids: [String], days: Int = 90, now: Date,
                                 lastUsed: (String) -> Date?, firstSeen: (String) -> Date? = { _ in nil }) -> [String] {
        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 86_400)
        return ids.filter { id in
            if let used = lastUsed(id) { return used < cutoff }
            if let first = firstSeen(id), first > cutoff { return false }
            return true
        }
    }
}
