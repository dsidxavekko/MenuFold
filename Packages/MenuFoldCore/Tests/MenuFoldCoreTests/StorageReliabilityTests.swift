import AppKit
import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct StorageReliabilityTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func image(_ side: Int, type: NSBitmapImageRep.FileType = .png) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: type, properties: [:])!
    }

    func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    func transfer(icons: [String: Data], apps: [String: String]) -> LayoutTransfer {
        LayoutTransfer(format: LayoutTransfer.formatName, version: 1,
                       layout: Layout(customIcons: apps), icons: icons)
    }

    // MARK: File size before reading

    @Test func transferFileSizeIsCheckedBeforeReading() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.json")
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(LayoutTransfer.maxFileSize) + 1) // sparse
        try handle.close()
        #expect(throws: LayoutDataError.damaged) { try LayoutTransfer.decode(contentsOf: url) }
        #expect(throws: LayoutDataError.damaged) { try LayoutStore.readLimited(url, limit: 1024) }
    }

    @Test func transferMissingFileIsNotAMenuFoldFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: LayoutDataError.notMenuFoldFile) { try LayoutTransfer.decode(contentsOf: url) }
    }

    // MARK: Icon import

    @Test func importedIconIsReencodedAndDownscaled() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = image(1500)
        let t = transfer(icons: ["a.png": big], apps: ["app.a": "a.png"])
        var written: [URL] = []
        let result = try t.installIcons(into: dir, written: &written)
        let name = try #require(result.customIcons["app.a"])
        let data = try Data(contentsOf: dir.appendingPathComponent(name))
        #expect(data != big)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        let size = try #require(pixelSize(data))
        #expect(max(size.0, size.1) <= LayoutTransfer.storedIconPixels)
    }

    @Test func jpegIsConvertedToPNG() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = transfer(icons: ["a.png": image(64, type: .jpeg)], apps: ["app.a": "a.png"])
        var written: [URL] = []
        let result = try t.installIcons(into: dir, written: &written)
        let name = try #require(result.customIcons["app.a"])
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func oversizedAndNonImageIconsAreDropped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = transfer(icons: ["huge.png": image(LayoutTransfer.maxIconPixels + 1),
                                 "junk.png": Data("not an image".utf8),
                                 "ok.png": image(32)],
                         apps: ["huge": "huge.png", "junk": "junk.png", "ok": "ok.png", "missing": "gone.png"])
        var written: [URL] = []
        let result = try t.installIcons(into: dir, written: &written)
        #expect(Set(result.customIcons.keys) == ["ok"])
        #expect(written.count == 1)
        #expect(try names(dir).count == 1)
    }

    @Test func tooManyBytesIsRejected() {
        #expect(LayoutTransfer.reencodedIcon(Data(count: LayoutTransfer.maxIconBytes + 1)) == nil)
        #expect(LayoutTransfer.reencodedIcon(Data()) == nil)
    }

    @Test func twoAppsShareOneIconFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = transfer(icons: ["s.png": image(32)], apps: ["a": "s.png", "b": "s.png"])
        var written: [URL] = []
        let result = try t.installIcons(into: dir, written: &written)
        #expect(result.customIcons["a"] != nil)
        #expect(result.customIcons["a"] == result.customIcons["b"])
        #expect(written.count == 1)
    }

    @Test func exportWithoutIconsKeyDecodes() throws {
        let json = #"{"format":"menufold-layout","version":1,"layout":{"version":1}}"#
        let t = try LayoutTransfer.decode(Data(json.utf8))
        #expect(t.icons.isEmpty)
    }

    // MARK: Backups, quarantine retry, pruning

    @Test func backupsRotateAndKeepTwo() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout(hidden: ["A"]))
        #expect(!(try names(dir)).contains("layout.bak")) // nothing to back up yet
        try store.save(Layout(hidden: ["B"]))
        let bak = dir.appendingPathComponent("layout.bak")
        #expect(try LayoutStore.decodeValidated(Data(contentsOf: bak)).hidden == ["A"])
        try store.save(Layout(hidden: ["C"]))
        // Within the interval: no new rotation.
        #expect(try LayoutStore.decodeValidated(Data(contentsOf: bak)).hidden == ["A"])
        store.backupInterval = 0
        try store.save(Layout(hidden: ["D"]))
        #expect(try LayoutStore.decodeValidated(Data(contentsOf: bak)).hidden == ["C"])
        let bak2 = dir.appendingPathComponent("layout.bak2")
        #expect(try LayoutStore.decodeValidated(Data(contentsOf: bak2)).hidden == ["A"])
    }

    @Test func sharedStoreMakesNoBackups() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        store.isShared = true
        try store.save(Layout(hidden: ["A"]))
        try store.save(Layout(hidden: ["B"]))
        #expect(try names(dir) == ["layout.json"])
    }

    @Test func quarantineIsRetriedOnSave() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try Data("{broken".utf8).write(to: store.fileURL)
        store.isQuarantinable = { _ in false }
        _ = store.loadWithOutcome()
        #expect(store.lastQuarantineFailed)
        #expect(throws: LayoutStoreError.self) { try store.save(Layout()) }
        store.isQuarantinable = { _ in true }
        try store.save(Layout(hidden: ["ok"]))
        #expect(!store.lastQuarantineFailed)
        #expect(try names(dir).contains { $0.hasPrefix("layout.corrupt-") })
        #expect(store.load().hidden == ["ok"])
    }

    @Test func corruptBackupsAreCapped() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 1...8 {
            try Data("x".utf8).write(to: dir.appendingPathComponent("layout.corrupt-2020010\(i)-000000.json"))
        }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try Data("{broken".utf8).write(to: store.fileURL)
        _ = store.loadWithOutcome()
        let corrupt = try names(dir).filter { $0.hasPrefix("layout.corrupt-") }
        #expect(corrupt.count == LayoutStore.maxCorruptBackups)
        // The fresh one (current date) survives; the oldest are gone.
        #expect(!corrupt.contains("layout.corrupt-20200101-000000.json"))
        #expect(corrupt.contains { !$0.hasPrefix("layout.corrupt-2020") })
    }

    // MARK: Migration

    @Test func migrationRunsStepsInOrderAndKeepsOldFilesLoading() {
        var old = Layout(hidden: ["a"])
        old.version = 1
        let steps: [Int: @Sendable (inout Layout) -> Void] = [
            1: { $0.hidden.insert("m1") },
            2: { $0.hidden.insert("m2") },
        ]
        let migrated = old.migrated(using: steps, to: 3)
        #expect(migrated.version == 3)
        #expect(migrated.hidden == ["a", "m1", "m2"])
        // Already current: untouched.
        #expect(migrated.migrated(using: steps, to: 3).hidden == migrated.hidden)
        // The real chain is a no-op for today's schema, even for a bogus version.
        var zero = Layout(hidden: ["z"]); zero.version = 0
        #expect(zero.migrated().version == Layout.currentVersion)
        #expect(zero.migrated().hidden == ["z"])
    }

    @Test func versionlessFileLoads() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try Data(#"{"hidden":["q"]}"#.utf8).write(to: store.fileURL)
        let r = store.loadWithOutcome()
        #expect(r.outcome == .loaded)
        #expect(r.layout.hidden == ["q"])
        #expect(r.layout.version == Layout.currentVersion)
    }

    // MARK: Bundle extensions, case-insensitive prefixes, Cryptexes

    @Test func bundleExtensionsHaveOneSource() {
        #expect(AppFilter.bundleExtensions == FinderFolders.bundleExtensions)
        for ext in [".app", ".prefpane", ".kext", ".systemextension", ".xpc", ".framework"] {
            #expect(FinderFolders.isBundle("X\(ext)"))
            #expect(FinderFolders.isBundle("X\(ext.uppercased())"))
            #expect(!AppFilter.isAllowed(path: "/Applications/X\(ext)/Y.app"))
            #expect(FinderFolders.key(forAppPath: "/Applications/X\(ext)/Y.app", homeDirectory: "/Users/me") == nil)
        }
        #expect(!FinderFolders.isBundle("Робота"))
    }

    @Test func pathPrefixesIgnoreCase() {
        #expect(AppFilter.isAllowed(path: "/applications/X.app"))
        #expect(!AppFilter.isAllowed(path: "/library/Foo/X.app"))
        #expect(!AppFilter.isAllowed(path: "/system/library/coreservices/Boot.app"))
        #expect(AppFilter.isAllowed(path: "/system/library/coreservices/finder.app"))
        #expect(!AppFilter.isAllowed(path: "/volumes/Backup/X.app"))
        #expect(!AppFilter.isAllowed(path: "/Users/ME/library/X.app", homeDirectory: "/Users/me"))
        #expect(AppFilter.rank("/APPLICATIONS/X.app", homeDirectory: "/Users/me") == 0)
        #expect(FinderFolders.key(forAppPath: "/applications/Робота/X.app", homeDirectory: "/Users/me") == "/Applications/Робота")
        #expect(FinderFolders.key(forAppPath: "/system/applications/utilities/Terminal.app", homeDirectory: "/Users/me") == "/System/Applications/Utilities")
    }

    @Test func cryptexSafariDeduplicatesToApplications() {
        func c(_ path: String) -> AppCandidate {
            AppCandidate(path: path, bundleID: "com.apple.Safari", name: "Safari", infoCategory: nil,
                         modificationDate: Date(timeIntervalSince1970: path.contains("Cryptexes") ? 2_000_000_000 : 1))
        }
        let cryptex = "/System/Cryptexes/App/System/Applications/Safari.app"
        for order in [[c("/Applications/Safari.app"), c(cryptex)], [c(cryptex), c("/Applications/Safari.app")]] {
            let apps = AppFilter.filter(order, homeDirectory: "/Users/me")
            #expect(apps.count == 1)
            #expect(apps.first?.url.path == "/Applications/Safari.app")
        }
        // Alone, the cryptex copy still shows (Safari is not lost on a Mac without /Applications/Safari.app).
        #expect(AppFilter.filter([c(cryptex)], homeDirectory: "/Users/me").count == 1)
    }
}
