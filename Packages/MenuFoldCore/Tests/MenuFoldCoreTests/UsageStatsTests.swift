import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct UsageStatsTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    /// `#expect` can't call a mutating method inline.
    func rec(_ s: inout UsageStats, _ id: String, at date: Date) -> Bool { s.record(id, at: date) }

    @Test func decayHalvesEveryHalfLife() {
        var s = UsageStats()
        #expect(rec(&s, "a", at: t0))
        #expect(s.score(of: "a", at: t0) == 1)
        #expect(abs(s.score(of: "a", at: t0 + 7 * 24 * 3600) - 0.5) < 1e-9)
        #expect(abs(s.score(of: "a", at: t0 + 14 * 24 * 3600) - 0.25) < 1e-9)
        #expect(s.score(of: "missing", at: t0) == 0)
        // A date before lastUsed counts as no time passing.
        #expect(s.score(of: "a", at: t0 - 1000) == 1)
        // The next use adds 1 to the decayed score.
        #expect(rec(&s, "a", at: t0 + UsageStats.halfLife))
        #expect(abs(s.score(of: "a", at: t0 + UsageStats.halfLife) - 1.5) < 1e-9)
    }

    @Test func oldEntriesAreForgottenOnRecord() {
        var s = UsageStats()
        s.record("old", at: t0)
        // 7 half-lives: 1/128 < 0.01.
        s.record("new", at: t0 + 7 * UsageStats.halfLife)
        #expect(s.entries["old"] == nil)
        #expect(s.entries["new"] != nil)
    }

    @Test func dedupeWithinInterval() {
        var s = UsageStats()
        #expect(rec(&s, "a", at: t0))
        #expect(!rec(&s, "a", at: t0 + 5))
        #expect(s.entries["a"] == .init(score: 1, lastUsed: t0))
        #expect(rec(&s, "a", at: t0 + 10))
        #expect(s.entries["a"]?.lastUsed == t0 + 10)
        // An earlier date is not a duplicate; Δt counts as 0 for decay.
        #expect(rec(&s, "a", at: t0))
        #expect(abs((s.entries["a"]?.score ?? 0) - 3) < 1e-3)
    }

    @Test func topOrderingTiesFilteringLimit() {
        var s = UsageStats()
        s.record("b", at: t0)
        s.record("a", at: t0)
        s.record("c", at: t0)
        s.record("c", at: t0 + 20)
        s.record("d", at: t0)
        s.entries["zero"] = .init(score: 0, lastUsed: t0)
        let now = t0 + 20
        #expect(s.top(10, among: ["a", "b", "c", "zero", "never"], at: now) == ["c", "a", "b"])
        #expect(s.top(2, among: ["a", "b", "c", "d"], at: now) == ["c", "a"])
        #expect(s.top(0, among: ["a"], at: now) == [])
        #expect(s.top(-1, among: ["a"], at: now) == [])
        #expect(s.top(3, among: [], at: now) == [])
    }

    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested")
            .appendingPathComponent("usage.json")
    }

    @Test func storeRoundTrip() throws {
        let store = UsageStore(fileURL: tempURL())
        #expect(store.load() == UsageStats())
        var s = UsageStats()
        s.record("a", at: t0)
        s.record("b", at: t0 + 100)
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test func corruptFileGivesEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)
        let store = UsageStore(fileURL: url)
        #expect(store.load() == UsageStats())
        // No quarantine: the file stays where it was.
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func defaultURLIsNextToLayout() {
        #expect(UsageStore.defaultURL.lastPathComponent == "usage.json")
        #expect(UsageStore.defaultURL.deletingLastPathComponent() == LayoutStore.defaultURL.deletingLastPathComponent())
    }
}
