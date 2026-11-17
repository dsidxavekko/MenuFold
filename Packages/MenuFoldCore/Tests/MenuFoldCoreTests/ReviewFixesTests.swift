import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct ReviewFixesTests {
    func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MFReview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func oldDate() -> Date { Date().addingTimeInterval(-3600) }

    // MARK: 1. hotkeys

    @Test func hotkeyValidation() {
        #expect(AppHotkey(keyCode: 0, modifiers: 256).isValid)
        #expect(AppHotkey(keyCode: 5, modifiers: 4096 | 512).isValid)
        #expect(AppHotkey(keyCode: 5, modifiers: 2048).isValid)
        #expect(!AppHotkey(keyCode: 5, modifiers: 0).isValid)
        #expect(!AppHotkey(keyCode: 5, modifiers: 512).isValid) // shift only
        #expect(!AppHotkey(keyCode: 128, modifiers: 256).isValid)
    }

    @Test func loadDropsInvalidHotkeys() {
        var l = Layout()
        l.appHotkeys = [
            "app:good": AppHotkey(keyCode: 1, modifiers: 256),
            "app:bare": AppHotkey(keyCode: 2, modifiers: 0),
            "app:shift": AppHotkey(keyCode: 3, modifiers: 512),
            "app:range": AppHotkey(keyCode: 999, modifiers: 256),
        ]
        let v = try? LayoutStore.validated(l)
        #expect(v?.appHotkeys.keys.sorted() == ["app:good"])
    }

    // MARK: 2. usage in a shared folder

    @Test func unreadableUsageFileIsNotOverwritten() throws {
        let url = tempDir().appendingPathComponent("usage.json")
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        let store = UsageStore(fileURL: url, deviceID: "mac1")
        var stats = UsageStats()
        _ = stats.record("a", at: Date())
        try store.save(stats)
        #expect(try Data(contentsOf: url) == garbage)
    }

    // MARK: 3. icons referenced by backups

    @Test func iconCleanupKeepsBackupReferencedIcons() throws {
        let dir = tempDir()
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        try FileManager.default.createDirectory(at: model.iconsDirectory, withIntermediateDirectories: true)
        let names = (0..<5).map { _ in UUID().uuidString + ".png" }
        for n in names {
            let u = model.iconsDirectory.appendingPathComponent(n)
            try Data([1]).write(to: u)
            try FileManager.default.setAttributes([.modificationDate: oldDate()], ofItemAtPath: u.path)
        }
        func layoutJSON(_ icon: String) -> Data { Data("{\"version\":1,\"customIcons\":{\"x\":\"\(icon)\"}}".utf8) }
        let backups = dir.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try layoutJSON(names[0]).write(to: backups.appendingPathComponent("layout-20260101.json"))
        try layoutJSON(names[1]).write(to: dir.appendingPathComponent("layout.bak"))
        try layoutJSON(names[2]).write(to: dir.appendingPathComponent("layout.bak2"))
        try layoutJSON(names[3]).write(to: dir.appendingPathComponent("layout.corrupt-20260101-000000.json"))
        model.removeUnusedIconFiles()
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: model.iconsDirectory.path))
        #expect(left == Set(names[0...3]))
    }

    // MARK: 4. corrupt pruning

    @Test func pruningKeepsNewerVersionFiles() throws {
        let dir = tempDir()
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let newer = dir.appendingPathComponent("layout.corrupt-20200101-000000.json")
        try Data("{\"version\":999}".utf8).write(to: newer)
        for i in 1...7 {
            try Data("garbage".utf8).write(to: dir.appendingPathComponent("layout.corrupt-2021010\(i)-000000.json"))
        }
        try Data("garbage".utf8).write(to: store.fileURL)
        _ = store.load()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains(newer.lastPathComponent))
        let plain = names.filter { $0.hasPrefix("layout.corrupt-") && $0 != newer.lastPathComponent }
        #expect(plain.count == LayoutStore.maxCorruptBackups)
    }

    // MARK: 5. undo persistence

    @Test func undoLoadRejectsOversizedAndInvalidSteps() throws {
        let dir = tempDir()
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let persistence = UndoPersistence(store: store)
        var current = Layout(); current.version = Layout.currentVersion
        var bad = Layout()
        bad.appHotkeys = ["app:x": AppHotkey(keyCode: 1, modifiers: 0)]
        persistence.save(current: current, undo: [bad])
        let steps = persistence.load(matching: current)
        #expect(steps.count == 1)
        #expect(steps[0].appHotkeys.isEmpty)

        var newer = Layout(); newer.version = Layout.currentVersion + 1
        persistence.save(current: current, undo: [newer])
        #expect(persistence.load(matching: current).isEmpty)
    }

    // MARK: 6. history retry keeps launch counts

    @Test func historyRetryMergeKeepsLaunchCounts() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("history.json")
        let store = AppHistoryStore(fileURL: url)
        var disk = AppHistory()
        disk.launchCounts = ["a": 3, "b": 1]
        try store.save(disk)
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: nil, historyStore: store)
        model.historyUnreadable = true
        model.history.launchCounts = ["a": 2, "c": 4]
        #expect(model.retryHistoryIfUnreadable())
        #expect(model.history.launchCounts == ["a": 3, "b": 1, "c": 4])
    }
}
