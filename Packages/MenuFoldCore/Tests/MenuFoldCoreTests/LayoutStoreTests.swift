import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct LayoutStoreTests {
    func tempStore() -> (LayoutStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (LayoutStore(fileURL: dir.appendingPathComponent("nested/layout.json")), dir)
    }

    /// A temp directory holding `layout.json` with `bytes`, plus a store pointing at it.
    func storeWithFile(_ bytes: String) throws -> (LayoutStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try Data(bytes.utf8).write(to: store.fileURL)
        return (store, dir)
    }

    func directoryEntries(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    @Test func defaultURL() {
        #expect(LayoutStore.defaultURL.path.hasSuffix("Library/Application Support/MenuFold/layout.json"))
    }

    @Test func roundTrip() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.load() == Layout()) // missing
        let layout = Layout(
            folders: [Folder(name: "Робота", color: .blue, symbol: "briefcase", appIDs: ["a", "b"])],
            categoryOverrides: ["a": "public.app-category.games"],
            hidden: ["z", "y"]
        )
        try store.save(layout)
        #expect(store.load() == layout)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text.contains("\n")) // pretty
        #expect(text.contains("\"hidden\" : [\n    \"y\",\n    \"z\""))
    }

    @Test func outcomes() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Missing.
        let missing = store.loadWithOutcome()
        #expect(missing.outcome == .missing)
        #expect(missing.layout == Layout())
        // Loaded.
        try store.save(Layout(hidden: ["a"]))
        let loaded = store.loadWithOutcome()
        #expect(loaded.outcome == .loaded)
        #expect(loaded.layout.hidden == ["a"])
        // Quarantined: the destination is reported so a caller can tell the user where the file went.
        try Data("{ not json".utf8).write(to: store.fileURL)
        let corrupt = store.loadWithOutcome()
        guard case .quarantined(let url) = corrupt.outcome else {
            Issue.record("expected .quarantined, got \(corrupt.outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(corrupt.layout == Layout())
    }

    @Test func corruptFile() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        #expect(store.load() == Layout())
        // Corrupt file moved aside, original path freed.
        let parent = store.fileURL.deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.range(of: #"^layout\.corrupt-\d{8}-\d{6}\.json$"#, options: .regularExpression) != nil)
        #expect(try String(contentsOf: parent.appendingPathComponent(name), encoding: .utf8) == "{ not json")
        // Saving afterwards doesn't touch the backup.
        try store.save(Layout(hidden: ["a"]))
        #expect(store.load().hidden == ["a"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).count == 2)
    }

    @Test func missingFileNotQuarantined() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let parent = store.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(store.load() == Layout())
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    /// A read error is not corruption: the file must stay where it is (so a retry can succeed),
    /// not be renamed to a `.corrupt-` backup.
    @Test func readErrorDoesNotQuarantine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // layout.json is a directory: it exists, but reading it as data fails.
        let fileURL = dir.appendingPathComponent("layout.json")
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let store = LayoutStore(fileURL: fileURL)

        let result = store.loadWithOutcome()
        guard case .unreadable = result.outcome else {
            Issue.record("expected .unreadable, got \(result.outcome)")
            return
        }
        #expect(result.layout == Layout())
        #expect(try directoryEntries(dir) == ["layout.json"])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!store.lastQuarantineFailed)
    }

    /// If the corrupt file cannot be moved aside, saving must not overwrite it: that would be the
    /// silent data loss the quarantine exists to prevent. `isQuarantinable` is injectable so this
    /// works with or without SIP (which may forbid moving files under $TMPDIR).
    @Test func quarantineFailureIsSurfacedAndSaveRefuses() throws {
        let (store, dir) = try storeWithFile("{ not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        store.isQuarantinable = { _ in false }

        let result = store.loadWithOutcome()
        #expect(result.outcome == .quarantined(store.fileURL))
        #expect(store.lastQuarantineFailed)
        #expect(throws: LayoutStoreError.quarantinePending(store.fileURL)) {
            try store.save(Layout(hidden: ["a"]))
        }
        // The unusable file is still there, byte for byte.
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "{ not json")
    }

    /// The real path: moving fails because the destination directory vanished, and the store
    /// reports that instead of pretending the corrupt file was saved elsewhere.
    @Test func quarantineMoveFailureIsNotSilent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("nested/layout.json"))
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.fileURL)
        // Fail exactly the way a vanished/read-only directory fails, without relying on real chmod.
        store.isQuarantinable = { _ in false }
        let outcome = store.loadWithOutcome().outcome
        #expect(outcome == .quarantined(store.fileURL))
        #expect(store.lastQuarantineFailed)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        // Saving stays refused until the file is dealt with; it never overwrites the original.
        #expect(throws: LayoutStoreError.quarantinePending(store.fileURL)) {
            try store.save(Layout())
        }
    }

    /// A file from a newer MenuFold must not be rewritten in the old schema.
    @Test func higherVersionIsQuarantinedNotDowngraded() throws {
        let (store, dir) = try storeWithFile(#"{"version":99,"folders":[],"hidden":["from-the-future"]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = store.loadWithOutcome()
        guard case .incompatible(let url) = result.outcome else {
            Issue.record("expected .incompatible, got \(result.outcome)")
            return
        }
        #expect(try String(contentsOf: url, encoding: .utf8).contains("from-the-future"))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(result.layout == Layout())
        // The path is free again, so the model can write a fresh layout without losing the backup.
        #expect(store.loadWithOutcome().outcome == .missing)
        try store.save(Layout(hidden: ["z"]))
        #expect(store.load().hidden == ["z"])
    }

    /// Missing keys keep their defaults (old and future files still load); a present key with the
    /// wrong shape is corruption, and the file is preserved instead of being partly reloaded and
    /// then saved back without the lost data.
    @Test func tolerantDecoding() throws {
        let (store, dir) = try storeWithFile("""
        {"version": 1, "futureField": 1,
         "folders": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "F", "appIDs": ["a","b"]},
                     {"id": "0B5A3D1A-1111-4222-8333-444455556666", "appIDs": ["c","d"]}],
         "hidden": ["x"]}
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = store.load()
        #expect(l.version == Layout.currentVersion) // normalized while loading
        // A file from a NEWER version is not read leniently: it is quarantined untouched (see
        // higherVersionIsQuarantinedNotDowngraded), because saving it back would drop its new fields.
        #expect(l.folders.count == 2)
        #expect(l.folders[0].name == "F")
        #expect(l.folders[0].color == .gray) // missing → default
        #expect(l.folders[0].appIDs == ["a", "b"])
        #expect(l.hidden == ["x"])
        #expect(l.categoryOverrides.isEmpty)
        // The second folder has no name: it keeps the default, nothing is lost.
        #expect(l.folders[1].name == "Папка")
        #expect(l.folders[1].appIDs == ["c", "d"])

        // Present but malformed: quarantine and keep the original bytes.
        var dirs: [URL] = []
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        for (label, json) in [
            ("appIDs with a number", #"{"folders":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","appIDs":["a",42]}]}"#),
            ("folder without id", #"{"folders":[{"name":"F","appIDs":["a","b"]}]}"#),
            ("unknown colour", #"{"folders":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","color":"ultraviolet","appIDs":["a","b"]}]}"#),
            ("hidden not an array", #"{"hidden":5}"#),
            ("finderAdditions not a dictionary", #"{"finderAdditions":["a"]}"#),
            ("category override with a number", #"{"categoryOverrides":{"a":5}}"#),
        ] {
            let (bad, badDir) = try storeWithFile(json)
            dirs.append(badDir)
            let outcome = bad.loadWithOutcome()
            guard case .quarantined(let backup) = outcome.outcome else {
                Issue.record("\(label): expected .quarantined, got \(outcome.outcome)")
                continue
            }
            #expect(try String(contentsOf: backup, encoding: .utf8) == json, "\(label): the backup keeps the original bytes")
        }
    }

    /// Duplicate ids break SwiftUI identity (two tiles share one id) and only the first matches.
    @Test func duplicateFolderIDsAreDeduplicated() throws {
        let dup = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        let (store, dir) = try storeWithFile("""
        {"folders":[{"id":"\(dup)","name":"A","appIDs":["a","b"]},
                    {"id":"\(dup)","name":"B","appIDs":["c","d"]}]}
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = store.load()
        #expect(l.folders.count == 1)
        #expect(l.folders.first?.name == "A")
        // Nothing was lost to the file itself, so it is not quarantined either.
        #expect(try directoryEntries(dir).contains("layout.json"))
    }

    /// Duplicate bundle ids inside one folder would make "≤1 app is dissolved" lie about its size.
    @Test func duplicateAppIDsInsideAFolderAreRemoved() throws {
        let (store, dir) = try storeWithFile("""
        {"folders":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","appIDs":["a","b","a"]}]}
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.load().folders.first?.appIDs == ["a", "b"])
    }

    /// Dead entries that the model would never show (or would show as junk) are dropped on load,
    /// otherwise they would be saved back forever.
    @Test func invalidFoldersAreDroppedOnLoad() throws {
        let (store, dir) = try storeWithFile("""
        {"folders":[{"id":"11111111-1111-4111-8111-111111111111","name":"Alone","appIDs":["a"]},
                    {"id":"22222222-2222-4222-8222-222222222222","name":"Empty","appIDs":[]},
                    {"id":"33333333-3333-4333-8333-333333333333","name":"Good","appIDs":["a","b"]},
                    {"id":"44444444-4444-4444-8444-444444444444","name":"Dots","appIDs":["a","b"],"finderPath":"/Applications/../etc"}],
         "finderStyles":{"/Applications/..":{"color":"red"},"/Applications/Робота":{"color":"blue"}},
         "ignoredFinderFolders":["/Applications/..","relative/path","/Applications/Gone"],
         "finderAdditions":{"x":"/Applications/..","y":"/Applications/Робота"}}
        """)
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = store.load()
        #expect(l.folders.map(\.name) == ["Good"])
        #expect(Set(l.finderStyles.keys) == ["/Applications/Робота"])
        #expect(l.ignoredFinderFolders == ["/Applications/Gone"])
        #expect(l.finderAdditions == ["y": "/Applications/Робота"])
        // A save round-trips only the sanitized layout.
        try store.save(l)
        #expect(store.load() == l)
    }

    /// An absurdly large file is never a layout: refuse it instead of reading it into memory.
    @Test func oversizedFileIsNotRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        // A sparse file: reported as huge, costs no disk space.
        try Data().write(to: store.fileURL)
        let handle = try FileHandle(forWritingTo: store.fileURL)
        try handle.truncate(atOffset: UInt64(LayoutStore.maxFileSize) + 1)
        try handle.close()
        let outcome = store.loadWithOutcome().outcome
        guard case .unreadable = outcome else {
            Issue.record("expected .unreadable, got \(outcome)")
            return
        }
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}

@Suite struct FinderLayoutCodingTests {
    @Test func roundTripFinderFields() throws {
        let layout = Layout(
            finderStyles: ["/Applications/Робота": FinderFolderStyle(color: .green, symbol: "hammer"),
                           "/System/Applications/Utilities": FinderFolderStyle(color: .red)],
            ignoredFinderFolders: ["/Applications/B", "/Applications/A"],
            finderExclusions: ["com.x", "com.a"]
        )
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(Layout.self, from: data) == layout)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""finderExclusions":["com.a","com.x"]"#))
    }

    @Test func lenientDefaultsForOldFiles() throws {
        let old = #"{"version":1,"folders":[],"categoryOverrides":{},"hidden":["z"]}"#
        let l = try JSONDecoder().decode(Layout.self, from: Data(old.utf8))
        #expect(l.hidden == ["z"])
        #expect(l.finderStyles.isEmpty && l.ignoredFinderFolders.isEmpty && l.finderExclusions.isEmpty)
        // Missing keys are fine…
        #expect(try JSONDecoder().decode(Layout.self, from: Data("{}".utf8)) == Layout())
        // …but a present value of the wrong shape is not silently replaced by a default:
        // it throws, so the store quarantines the file instead of loading half of it.
        var threw = false
        do { _ = try JSONDecoder().decode(Layout.self, from: Data(#"{"ignoredFinderFolders":5}"#.utf8)) }
        catch { threw = true }
        #expect(threw)
    }

    @Test func finderStyleDefaultsAndStrictColor() throws {
        let l = try JSONDecoder().decode(Layout.self, from: Data(#"{"finderStyles":{"/A":{}}}"#.utf8))
        #expect(l.finderStyles["/A"] == FinderFolderStyle(color: .gray))
        var threw = false
        do { _ = try JSONDecoder().decode(Layout.self, from: Data(#"{"finderStyles":{"/A":{"color":"nope"}}}"#.utf8)) }
        catch { threw = true }
        #expect(threw, "an unknown colour must not be quietly reset to gray")
    }
}
