import Foundation
import Testing
@testable import MenuFoldCore

/// Review fixes around shared (synced) data folders, the sync reload, app history and leftovers.
@MainActor
@Suite struct SyncSafetyTests {
    let apps = [
        AppEntry(id: "mail", name: "Mail", url: URL(fileURLWithPath: "/Applications/Mail.app"), infoCategory: nil),
        AppEntry(id: "notes", name: "Notes", url: URL(fileURLWithPath: "/Applications/Notes.app"), infoCategory: nil),
        AppEntry(id: "chess", name: "Chess", url: URL(fileURLWithPath: "/Applications/Chess.app"), infoCategory: nil),
    ]

    func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MF-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: Reload

    @Test func reloadDoesNotWriteBackAndClearsUndo() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout())
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        model.pin("mail")
        #expect(model.canUndo)

        // Another Mac writes an older-version file (version 1): applied, but not rewritten.
        let json = #"{"version":1,"hidden":["chess"]}"#
        try Data(json.utf8).write(to: store.fileURL)
        model.reloadLayoutFromDisk()
        #expect(model.layout.hidden == ["chess"])
        #expect(model.layout.version == Layout.currentVersion)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == json)
        #expect(!model.canUndo && !model.canRedo)

        // An equal reload (the echo of an own save) keeps undo.
        model.pin("notes")
        model.reloadLayoutFromDisk()
        #expect(model.canUndo)
    }

    @Test func reloadIgnoresNewerVersionsWithoutQuarantine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout(hidden: ["mail"]))
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        let newer = #"{"version":\#(Layout.currentVersion + 1),"hidden":["notes"]}"#
        try Data(newer.utf8).write(to: store.fileURL)
        model.reloadLayoutFromDisk()
        #expect(model.layout.hidden == ["mail"])
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == newer)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("corrupt") })
    }

    @Test func reloadClearsRenamesWhoseTargetVanished() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try store.save(Layout())
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        let fid = try #require(model.createFolder(dropping: "notes", onto: "mail"))
        let cat = model.createCategory(named: "Ігри", assigning: "chess")
        model.openFolderID = fid
        model.renamingCategoryID = cat.id
        #expect(model.renamingFolderID == fid)

        try LayoutStore(fileURL: store.fileURL).save(Layout(hidden: ["x"]))
        model.reloadLayoutFromDisk()
        #expect(model.renamingFolderID == nil)
        #expect(model.renamingCategoryID == nil)
        #expect(model.openFolderID == nil)
    }

    // MARK: Shared folder

    @Test func sharedFolderGetsNoFreshLayoutAfterQuarantine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        store.isShared = true
        try Data("{ not json".utf8).write(to: store.fileURL)
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        guard case .quarantined = model.layoutOutcome else { Issue.record("not quarantined"); return }
        // Moved aside, and no empty layout written in its place.
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        // The first real change writes the file.
        model.pin("mail")
        #expect(store.load().pinned == ["mail"])
    }

    @Test func localFolderStillGetsFreshLayoutAfterQuarantine() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try Data("{ not json".utf8).write(to: store.fileURL)
        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: History

    /// history.json that exists but cannot be read is never saved over, and its apps are not
    /// stamped as a first run; once readable it is merged with what happened meanwhile.
    @Test func unreadableHistoryIsNotOverwritten() throws {
        let dir = tempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("history.json").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("history.json")
        let old = Date(timeIntervalSinceReferenceDate: 1000)
        let historyStore = AppHistoryStore(fileURL: url)
        try historyStore.save(AppHistory(firstSeen: ["mail": old, "gone": old], lastLaunched: ["mail": old]))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        let before = try #require(modificationDate(url))

        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil, historyStore: historyStore)
        #expect(historyStore.lastLoadUnreadable)
        #expect(model.history.firstSeen.isEmpty) // not stamped
        #expect(!model.isNew("notes"))
        model.recordUse(appID: "chess")
        #expect(modificationDate(url) == before)

        // Readable again: the next save merges the file with the in-memory changes.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        model.recordUse(appID: "notes")
        let saved = historyStore.load()
        #expect(!historyStore.lastLoadUnreadable)
        #expect(saved.firstSeen["gone"] == old)
        #expect(saved.lastLaunched["mail"] == old)
        #expect(saved.lastLaunched["chess"] != nil && saved.lastLaunched["notes"] != nil)
    }

    @Test func missingHistoryIsAFirstRun() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let historyStore = AppHistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil, historyStore: historyStore)
        #expect(model.history.firstSeen["mail"] == .distantPast)
        #expect(historyStore.load().firstSeen.count == apps.count)
    }

    // MARK: Leftovers

    /// Sibling apps share `Application Support/<name>`-style folders: only bundle-id names count.
    @Test func leftoversIgnoreAppNamedSupportFolders() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lib = root.appendingPathComponent("Library", isDirectory: true)
        for rel in ["Application Support/Firefox", "Application Support/org.mozilla.firefoxdeveloperedition"] {
            try FileManager.default.createDirectory(at: lib.appendingPathComponent(rel), withIntermediateDirectories: true)
        }
        let found = AppLeftovers(library: lib).find(
            bundleID: "org.mozilla.firefoxdeveloperedition",
            appURL: URL(fileURLWithPath: "/Applications/Firefox.app"))
        #expect(found.map(\.url.lastPathComponent) == ["org.mozilla.firefoxdeveloperedition"])
    }
}
