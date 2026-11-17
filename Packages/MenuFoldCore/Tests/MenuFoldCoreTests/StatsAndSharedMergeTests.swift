import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct StatsAndSharedMergeTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }
    func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
    }
    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("menufold-stats-\(UUID().uuidString)").appendingPathComponent(name)
    }

    @Test func logCountsPerDayAndPrunes() {
        var log = UsageLog()
        let d = date(2026, 11, 17)
        log.record("a", at: d, calendar: cal)
        log.record("a", at: d, calendar: cal)
        log.record("b", at: d, calendar: cal)
        #expect(log.days["2026-11-17"] == ["a": 2, "b": 1])
        #expect(log.total(for: "a") == 2)
        log.record("a", at: date(2028, 1, 1), calendar: cal)
        #expect(log.days["2026-11-17"] == nil)
        #expect(log.total(for: "a") == 1)
    }

    @Test func disabledLogRecordsNothing() {
        var log = UsageLog(enabled: false)
        let recorded = log.record("a", at: Date(), calendar: cal)
        #expect(!recorded)
        #expect(log.isEmpty)
    }

    @Test func logStoreRoundTripAndLenientDecode() throws {
        let url = tempURL("usage-log.json")
        let store = UsageLogStore(fileURL: url)
        var log = UsageLog()
        log.record("a", at: date(2026, 11, 17), calendar: cal)
        try store.save(log)
        #expect(store.load() == log)
        try Data("{}".utf8).write(to: url)
        #expect(store.load() == UsageLog())
        try Data("garbage".utf8).write(to: url)
        #expect(store.load() == UsageLog())
    }

    @Test func reportTopWeekdaysAndRecent() {
        var log = UsageLog()
        let wed = date(2026, 11, 18) // Wednesday
        let now = date(2026, 11, 20)
        for _ in 0..<3 { log.record("a", at: wed, calendar: cal) }
        log.record("b", at: wed, calendar: cal)
        log.record("c", at: date(2026, 11, 20), calendar: cal)
        let r = UsageReport.make(from: log, now: now, topCount: 2, calendar: cal)
        #expect(r.totalLaunches == 5)
        #expect(r.top.map(\.appID) == ["a", "b"])
        #expect(r.weekdayNumbers == [2, 3, 4, 5, 6, 7, 1])
        #expect(r.weekdayCounts[2] == 4) // Wednesday
        #expect(r.recent.count == UsageReport.recentDays)
        #expect(r.recent.last?.count == 1)
    }

    @Test func notOpened() {
        let now = date(2026, 11, 20)
        let old = date(2026, 1, 1), fresh = date(2026, 11, 10)
        let r = UsageReport.notOpened(ids: ["old", "fresh", "never", "newInstall"], now: now,
                                      lastUsed: { ["old": old, "fresh": fresh][$0] },
                                      firstSeen: { $0 == "newInstall" ? fresh : nil })
        #expect(r == ["old", "never"])
    }

    @Test func historyMergeIsCommutativeAndIdempotent() {
        let t1 = Date(timeIntervalSince1970: 1000), t2 = Date(timeIntervalSince1970: 2000)
        let a = AppHistory(firstSeen: ["x": t2, "y": t1], lastLaunched: ["x": t1], seen: ["x"])
        let b = AppHistory(firstSeen: ["x": t1], lastLaunched: ["x": t2, "z": t1], seen: ["y"])
        let m = a.merged(with: b)
        #expect(m.firstSeen == ["x": t1, "y": t1])
        #expect(m.lastLaunched == ["x": t2, "z": t1])
        #expect(m.seen == ["x", "y"])
        #expect(m == b.merged(with: a))
        #expect(m.merged(with: a) == m)
    }

    @Test func sharedHistoryStoreLoadForMergeLeavesBadFileAlone() throws {
        let url = tempURL("history.json")
        let store = AppHistoryStore(fileURL: url)
        #expect(store.loadForMerge() == AppHistory())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{half".utf8).write(to: url)
        #expect(store.loadForMerge() == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func combinedUsageCountsEachDeviceOnce() throws {
        let url = tempURL("usage.json")
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let mac1 = UsageStore(fileURL: url, deviceID: "mac1")
        let mac2 = UsageStore(fileURL: url, deviceID: "mac2")
        var u1 = mac1.load()
        u1.record("a", at: t0)
        try mac1.save(u1)
        var u2 = mac2.load()
        #expect(u2.score(of: "a", at: t0) == 1)
        u2.record("a", at: t0 + 100)
        try mac2.save(u2)
        // mac1 picks up mac2's use; saving again must not copy mac2's count into its own part.
        var again = mac1.load()
        #expect(abs(again.score(of: "a", at: t0 + 100) - 2) < 0.01)
        again.record("b", at: t0 + 200)
        try mac1.save(again)
        let final = UsageStore(fileURL: url, deviceID: "mac3").load()
        #expect(abs(final.score(of: "a", at: t0 + 200) - 2) < 0.01)
        #expect(final.score(of: "b", at: t0 + 200) > 0.99)
    }

    @Test func plainFileCountsAsLegacyDevice() throws {
        let url = tempURL("usage.json")
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var plain = UsageStats()
        plain.record("a", at: t0)
        try UsageStore(fileURL: url).save(plain)
        let shared = UsageStore(fileURL: url, deviceID: "mac1")
        #expect(shared.load().score(of: "a", at: t0) == 1)
        var u = shared.load()
        u.record("b", at: t0 + 50)
        try shared.save(u)
        let reread = UsageStore(fileURL: url, deviceID: "mac2").load()
        #expect(reread.score(of: "a", at: t0 + 50) > 0.99 && reread.score(of: "b", at: t0 + 50) > 0.99)
    }

    @Test func clearingOnlyClearsOwnPart() throws {
        let url = tempURL("usage.json")
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let m1 = UsageStore(fileURL: url, deviceID: "m1"), m2 = UsageStore(fileURL: url, deviceID: "m2")
        var a = m1.load(); a.record("a", at: t0); try m1.save(a)
        var b = m2.load(); b.record("b", at: t0); try m2.save(b)
        try m1.save(UsageStats())
        let r = UsageStore(fileURL: url, deviceID: "m3").load()
        #expect(r.entries["a"] == nil && r.entries["b"] != nil)
    }
}
