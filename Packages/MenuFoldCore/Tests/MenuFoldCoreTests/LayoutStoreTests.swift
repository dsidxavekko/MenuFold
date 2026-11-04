import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct LayoutStoreTests {
    func tempStore() -> (LayoutStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (LayoutStore(fileURL: dir.appendingPathComponent("nested/layout.json")), dir)
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

    @Test func tolerantDecoding() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"version": 7, "futureField": 1,
         "folders": [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "F", "color": "ultraviolet", "appIDs": ["a","b"]},
                     {"garbage": true}],
         "hidden": ["x"]}
        """
        try Data(json.utf8).write(to: store.fileURL)
        let l = store.load()
        #expect(l.version == 7)
        #expect(l.folders.count == 2)
        #expect(l.folders[0].name == "F")
        #expect(l.folders[0].color == .gray)
        #expect(l.folders[0].appIDs == ["a", "b"])
        #expect(l.hidden == ["x"])
        #expect(l.categoryOverrides.isEmpty)
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
        let bad = #"{"finderStyles":{"/A":{"color":"nope"}},"ignoredFinderFolders":5}"#
        let l2 = try JSONDecoder().decode(Layout.self, from: Data(bad.utf8))
        #expect(l2.finderStyles["/A"] == FinderFolderStyle(color: .gray))
        #expect(l2.ignoredFinderFolders.isEmpty)
    }
}
