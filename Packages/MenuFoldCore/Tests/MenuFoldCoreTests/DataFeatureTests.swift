import AppKit
import Foundation
import Testing
@testable import MenuFoldCore

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MF-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func app(_ id: String, _ name: String, _ path: String, lastUsed: Date? = nil) -> AppEntry {
    AppEntry(id: id, name: name, url: URL(fileURLWithPath: path, isDirectory: true), infoCategory: nil, lastUsedDate: lastUsed)
}

private let day: TimeInterval = 24 * 3600

// MARK: - History

@MainActor
@Suite struct AppHistoryTests {
    let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func firstRunStampsDistantPastThenNewAppsGetNow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let historyStore = AppHistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        let cat = StaticAppCatalog(apps: [app("a", "A", "/Applications/A.app")])
        let model = GridModel(catalog: cat, store: nil, historyStore: historyStore)
        #expect(model.history.firstSeen["a"] == .distantPast)
        #expect(!model.isNew("a"))

        model.now = { self.base }
        cat.replace([app("a", "A", "/Applications/A.app"), app("b", "B", "/Applications/B.app")])
        #expect(model.history.firstSeen["b"] == base)
        #expect(model.isNew("b"))
        #expect(historyStore.load().firstSeen["b"] == base) // saved

        // Removed then reinstalled: still the old first-seen date, kept in the file.
        cat.replace([app("a", "A", "/Applications/A.app")])
        #expect(model.history.firstSeen["b"] == base)

        // Older than 7 days: no longer new.
        model.now = { self.base.addingTimeInterval(8 * day) }
        #expect(!model.isNew("b"))
    }

    @Test func launchAndMarkSeenClearNew() {
        let cat = StaticAppCatalog(apps: [app("a", "A", "/Applications/A.app")])
        let model = GridModel(catalog: cat, store: nil)
        model.now = { self.base }
        cat.replace([app("a", "A", "/Applications/A.app"), app("b", "B", "/Applications/B.app"),
                     app("c", "C", "/Applications/C.app")])
        #expect(model.isNew("b") && model.isNew("c"))
        model.markSeen("b")
        #expect(!model.isNew("b"))
        #expect(model.history.lastLaunched["b"] == nil) // seen is not a launch
        model.now = { self.base.addingTimeInterval(60) }
        model.recordUse(appID: "c")
        #expect(!model.isNew("c"))
        #expect(model.history.lastLaunched["c"] == base.addingTimeInterval(60))
    }

    @Test func lenientDecodingAndCorruptFile() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        try Data(#"{"firstSeen":{"a":0}}"#.utf8).write(to: url)
        let h = AppHistoryStore(fileURL: url).load()
        #expect(h.firstSeen["a"] == Date(timeIntervalSinceReferenceDate: 0))
        #expect(h.lastLaunched.isEmpty && h.seen.isEmpty)
        try Data("nope".utf8).write(to: url)
        #expect(AppHistoryStore(fileURL: url).load() == AppHistory())
        // The corrupt file was moved aside, not left to be overwritten.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(aside.contains { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") })
    }

    @Test func lastUsedAndUnusedOrder() {
        let now = base
        let apps = [
            app("recent", "Recent", "/Applications/Recent.app", lastUsed: now.addingTimeInterval(-1 * day)),
            app("old", "Old", "/Applications/Old.app", lastUsed: now.addingTimeInterval(-100 * day)),
            app("older", "Older", "/Applications/Older.app", lastUsed: now.addingTimeInterval(-200 * day)),
            app("never", "Never", "/Applications/Never.app"),
            app("sys", "Sys", "/System/Applications/Sys.app"),
            app("launched", "Launched", "/Applications/Launched.app", lastUsed: now.addingTimeInterval(-300 * day)),
            app("hidden", "Hidden", "/Applications/Hidden.app"),
        ]
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        model.now = { now }
        model.hide("hidden")
        model.recordUse(appID: "launched") // MenuFold's date beats Spotlight's older one
        #expect(model.lastUsed(apps[5]) == now)
        #expect(model.lastUsed(apps[3]) == nil)
        #expect(model.unusedApps(olderThan: 30 * day).map(\.id) == ["never", "older", "old"])
    }

    @Test func justInstalledNeverUsedIsNotUnused() {
        let cat = StaticAppCatalog(apps: [app("a", "A", "/Applications/A.app")])
        let model = GridModel(catalog: cat, store: nil)
        model.now = { self.base }
        cat.replace([app("a", "A", "/Applications/A.app"), app("b", "B", "/Applications/B.app")])
        #expect(model.unusedApps(olderThan: 30 * day).map(\.id) == ["a"])
    }
}

// MARK: - Backups

@MainActor
@Suite struct LayoutBackupTests {
    @Test func noLayoutFileNoBackup() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: LayoutStore(fileURL: dir.appendingPathComponent("layout.json")))
        model.makeLaunchBackup()
        #expect(model.backups.isEmpty)
    }

    @Test func onePerDayKeepSeven() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout(hidden: ["x"]))
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        #expect(model.backups.count == 1) // made at launch (real date)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Backups"))
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for i in 0..<10 {
            model.now = { start.addingTimeInterval(Double(i) * day) }
            model.makeLaunchBackup()
            model.now = { start.addingTimeInterval(Double(i) * day + 60) }
            model.makeLaunchBackup() // same day: no second copy
        }
        let backups = model.backups
        #expect(backups.count == 7)
        #expect(backups == backups.sorted { $0.date > $1.date })
        let newest = Calendar.current.startOfDay(for: start.addingTimeInterval(9 * day))
        #expect(backups.first?.date == newest)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Backups").path)
        #expect(files.count == 7)
    }

    @Test func restoreValidatesKeepsIconsAndIsUndoable() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout(hidden: ["old"], customIcons: ["a": "OLD.png"]))
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        model.now = { Date(timeIntervalSinceReferenceDate: 800_000_000) }
        let backup = try #require(model.backups.first) // made at launch

        var current = model.layout
        current.hidden = ["new"]
        current.customIcons = ["a": "CUR.png"]
        model.commit(current)

        try model.restore(backup)
        #expect(model.layout.hidden == ["old"])
        #expect(model.layout.customIcons == ["a": "CUR.png"]) // current icons kept
        #expect(store.load().hidden == ["old"])

        // A damaged backup or a newer one is refused and changes nothing.
        try Data("{ broken".utf8).write(to: backup.url)
        #expect(throws: LayoutDataError.damaged) { try model.restore(backup) }
        try Data(#"{"version":999}"#.utf8).write(to: backup.url)
        #expect(throws: LayoutDataError.newerVersion) { try model.restore(backup) }
        #expect(model.layout.hidden == ["old"])
    }

    @Test func decodeValidatedDropsInvalidEntries() throws {
        let json = #"{"version":1,"folders":[{"id":"\#(UUID().uuidString)","name":"F","appIDs":["a"]}],"customIcons":{"a":"../x.png"}}"#
        let l = try LayoutStore.decodeValidated(Data(json.utf8))
        #expect(l.folders.isEmpty)
        #expect(l.customIcons.isEmpty)
    }
}

// MARK: - Export / import

@MainActor
@Suite struct LayoutTransferTests {
    func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func roundtripWithIcons() throws {
        let a = tempDir(), b = tempDir()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        let storeA = LayoutStore(fileURL: a.appendingPathComponent("layout.json"))
        let source = GridModel(catalog: StaticAppCatalog(apps: []), store: storeA)
        let icons = storeA.iconsDirectory
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let bytes = try png()
        try bytes.write(to: icons.appendingPathComponent("ICON.png"))
        try bytes.write(to: icons.appendingPathComponent("UNUSED.png"))
        let folder = Folder(name: "F", appIDs: ["x", "y"])
        source.commit(Layout(folders: [folder], hidden: ["h"],
                             customIcons: ["x": "ICON.png", "y": "ICON.png", "gone": "MISSING.png"]))
        let file = a.appendingPathComponent("export.json")
        try source.exportLayout(to: file)

        // Only the used icon is exported, and the dangling entry is dropped.
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(raw["format"] as? String == "menufold-layout")
        #expect((raw["icons"] as? [String: Any]).map { Set($0.keys) } == ["ICON.png"])

        let storeB = LayoutStore(fileURL: b.appendingPathComponent("layout.json"))
        let target = GridModel(catalog: StaticAppCatalog(apps: []), store: storeB)
        try target.importLayout(from: file)
        #expect(target.layout.folders == [folder])
        #expect(target.layout.hidden == ["h"])
        let newName = try #require(target.layout.customIcons["x"])
        #expect(newName != "ICON.png")
        #expect(target.layout.customIcons["y"] == newName) // shared file stays shared
        #expect(target.layout.customIcons["gone"] == nil)
        #expect(try Data(contentsOf: storeB.iconsDirectory.appendingPathComponent(newName)) == bytes)
        #expect(storeB.load() == target.layout)
    }

    @Test func rejectsNewerAndForeignFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: nil)
        let file = dir.appendingPathComponent("f.json")

        try Data(#"{"format":"menufold-layout","version":2,"layout":{},"icons":{}}"#.utf8).write(to: file)
        #expect(throws: LayoutDataError.newerVersion) { try model.importLayout(from: file) }
        try Data(#"{"format":"menufold-layout","version":1,"layout":{"version":99}}"#.utf8).write(to: file)
        #expect(throws: LayoutDataError.newerVersion) { try model.importLayout(from: file) }
        try Data(#"{"hello":1}"#.utf8).write(to: file)
        #expect(throws: LayoutDataError.notMenuFoldFile) { try model.importLayout(from: file) }
        try Data(#"{"format":"menufold-layout","version":1,"layout":{"hidden":7}}"#.utf8).write(to: file)
        #expect(throws: LayoutDataError.damaged) { try model.importLayout(from: file) }
        #expect(LayoutDataError.newerVersion.errorDescription?.isEmpty == false)
    }

    @Test func nonImageIconIsNotWritten() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        let junk = Data("not a png".utf8).base64EncodedString()
        let file = dir.appendingPathComponent("f.json")
        try Data(#"{"format":"menufold-layout","version":1,"layout":{"customIcons":{"a":"X.png"},"hidden":["q"]},"icons":{"X.png":"\#(junk)"}}"#.utf8).write(to: file)
        try model.importLayout(from: file)
        #expect(model.layout.customIcons.isEmpty)
        #expect(model.layout.hidden == ["q"])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.iconsDirectory.path)) ?? []).isEmpty)
    }
}

// MARK: - Sync reload

@MainActor
@Suite struct LayoutReloadTests {
    @Test func appliesValidChangesIgnoresBrokenOnes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout(hidden: ["a"]))
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        let undoCount = model.undoStack.count

        try LayoutStore(fileURL: store.fileURL).save(Layout(hidden: ["b"]))
        model.reloadLayoutFromDisk()
        #expect(model.layout.hidden == ["b"])
        #expect(model.undoStack.count == undoCount)

        // Half-written file: ignored and NOT quarantined.
        try Data("{ partial".utf8).write(to: store.fileURL)
        model.reloadLayoutFromDisk()
        #expect(model.layout.hidden == ["b"])
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ partial")
        let corrupt = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("corrupt") }
        #expect(corrupt.isEmpty)
    }
}

// MARK: - Leftovers

@Suite struct AppLeftoversTests {
    let id = "com.example.Editor"

    func makeLibrary() throws -> (URL, URL) {
        let root = tempDir()
        let lib = root.appendingPathComponent("Library", isDirectory: true)
        let fm = FileManager.default
        func file(_ rel: String, _ size: Int = 10) throws {
            let url = lib.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: url)
        }
        func dir(_ rel: String) throws { try fm.createDirectory(at: lib.appendingPathComponent(rel), withIntermediateDirectories: true) }
        // Positives
        try file("Preferences/\(id).plist")
        try file("Preferences/\(id).helper.plist")
        try file("Preferences/ByHost/\(id).0000-1111.plist")
        try file("Caches/\(id)/cache.db", 5000)
        try file("HTTPStorages/\(id).binarycookies")
        try dir("WebKit/\(id)")
        try dir("Saved Application State/\(id).savedState")
        try dir("Containers/\(id)")
        try dir("Application Scripts/\(id)")
        try dir("Logs/\(id)")
        try dir("Application Support/\(id)")
        try dir("Group Containers/ABCDE12345.\(id)")
        try file("LaunchAgents/\(id).updater.plist")
        // Negatives
        try dir("Application Support/Editor")             // named after the app: siblings share such folders
        try file("Preferences/\(id).beta.plist")          // another installed app
        try file("Preferences/\(id)X.plist")              // different id
        try file("Preferences/com.example.Other.plist")
        try dir("Group Containers/com.evil.\(id)")       // prefix with dots
        try dir("Caches/com.example")
        return (root, lib)
    }

    @Test func findsOnlyWhatBelongsToTheApp() throws {
        let (root, lib) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AppLeftovers(library: lib).find(bundleID: id, appURL: URL(fileURLWithPath: "/Applications/Editor.app"),
                                                    otherBundleIDs: [id + ".beta"])
        let names = Set(found.map { $0.url.path.replacingOccurrences(of: lib.standardizedFileURL.path + "/", with: "") })
        #expect(names == [
            "Preferences/\(id).plist", "Preferences/\(id).helper.plist", "Preferences/ByHost/\(id).0000-1111.plist",
            "Caches/\(id)", "HTTPStorages/\(id).binarycookies", "WebKit/\(id)",
            "Saved Application State/\(id).savedState", "Containers/\(id)", "Application Scripts/\(id)",
            "Logs/\(id)", "Application Support/\(id)",
            "Group Containers/ABCDE12345.\(id)", "LaunchAgents/\(id).updater.plist",
        ])
        let cache = try #require(found.first { $0.url.lastPathComponent == id && $0.url.path.contains("/Caches/") })
        #expect(cache.size >= 5000)
    }

    @Test func conservativeNegatives() throws {
        let (root, lib) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let finder = AppLeftovers(library: lib)
        try FileManager.default.createDirectory(at: lib.appendingPathComponent("Preferences"), withIntermediateDirectories: true)
        try Data().write(to: lib.appendingPathComponent("Preferences/com.apple.Safari.plist"))
        #expect(finder.find(bundleID: "com.apple.Safari", appURL: URL(fileURLWithPath: "/Applications/Safari.app")).isEmpty)
        // A bundle id without a dot or with path characters matches nothing.
        #expect(finder.find(bundleID: "Editor", appURL: URL(fileURLWithPath: "/Applications/Editor.app")).isEmpty)
        #expect(finder.find(bundleID: "../Caches", appURL: URL(fileURLWithPath: "/Applications/X.app")).isEmpty)
        // Application Support folders named after an app are never taken (only bundle-id names).
        for name in ["Google", "Microsoft", "Adobe", "Apple", "App"] {
            try FileManager.default.createDirectory(at: lib.appendingPathComponent("Application Support/\(name)"), withIntermediateDirectories: true)
            let found = finder.find(bundleID: "com.vendor.\(name.lowercased())x", appURL: URL(fileURLWithPath: "/Applications/\(name).app"))
            #expect(!found.contains { $0.url.lastPathComponent == name }, "\(name)")
        }
    }

    @Test func doesNotFollowSymlinksOutOfLibrary() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("Library", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent(id), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("Caches"), withDestinationURL: outside)
        #expect(AppLeftovers(library: lib).find(bundleID: id, appURL: URL(fileURLWithPath: "/Applications/Editor.app")).isEmpty)
    }

    @Test func diskUsageSumsFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 10_000).write(to: dir.appendingPathComponent("a"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 20_000).write(to: dir.appendingPathComponent("sub/b"))
        #expect(DiskUsage.allocatedSize(of: dir) >= 30_000)
        #expect(DiskUsage.allocatedSize(of: dir.appendingPathComponent("missing")) == 0)
    }
}

// MARK: - Catalog fields

@Suite struct CatalogFieldTests {
    @Test func filterCarriesLastUsedAndStoreID() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let entries = AppFilter.filter([
            AppCandidate(path: "/Applications/A.app", bundleID: "a", name: "A", infoCategory: nil, modificationDate: nil,
                         lastUsedDate: date, appStoreID: "497799835"),
            AppCandidate(path: "/Applications/B.app", bundleID: "b", name: "B", infoCategory: nil, modificationDate: nil),
        ], homeDirectory: "/Users/me")
        #expect(entries[0].lastUsedDate == date && entries[0].appStoreID == "497799835")
        #expect(entries[1].lastUsedDate == nil && entries[1].appStoreID == nil)
    }

    @MainActor @Test func storeIDParsing() {
        #expect(SpotlightAppCatalog.storeID(NSNumber(value: 123)) == "123")
        #expect(SpotlightAppCatalog.storeID(NSNumber(value: 0)) == nil)
        #expect(SpotlightAppCatalog.storeID(" 456 ") == "456")
        #expect(SpotlightAppCatalog.storeID("") == nil)
        #expect(SpotlightAppCatalog.storeID(nil) == nil)
    }
}
