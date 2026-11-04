import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct CategoryTests {
    @Test func knownMappings() {
        #expect(AppCategory.from(raw: "public.app-category.games").displayName == "Ігри")
        #expect(AppCategory.from(raw: "public.app-category.developer-tools").displayName == "Розробка")
        #expect(AppCategory.from(raw: "public.app-category.productivity").id == "public.app-category.productivity")
        #expect(AppCategory.from(raw: "PUBLIC.APP-CATEGORY.MUSIC").id == "public.app-category.music")
    }

    @Test func gameSubcategoriesCollapse() {
        for sub in ["action-games", "board-games", "role-playing-games", "word-games"] {
            let c = AppCategory.from(raw: "public.app-category.\(sub)")
            #expect(c.id == "public.app-category.games")
            #expect(c.displayName == "Ігри")
        }
    }

    @Test func unknownIsOther() {
        #expect(AppCategory.from(raw: nil) == .other)
        #expect(AppCategory.from(raw: "") == .other)
        #expect(AppCategory.from(raw: "com.example.whatever") == .other)
        #expect(AppCategory.from(raw: "other") == .other)
    }

    @Test func knownList() {
        let known = AppCategory.known
        #expect(known.count == 21)
        #expect(!known.contains(.other))
        #expect(Set(known.map(\.id)).count == known.count)
        for c in known { #expect(AppCategory.from(raw: c.id) == c) }
    }
}

@Suite struct AppFilterTests {
    let home = "/Users/test"

    func cand(_ path: String, _ id: String?, name: String = "X", date: Date? = nil) -> AppCandidate {
        AppCandidate(path: path, bundleID: id, name: name, infoCategory: nil, modificationDate: date)
    }

    @Test func dropsMissingBundleIDAndSelf() {
        let r = AppFilter.filter([
            cand("/Applications/A.app", nil),
            cand("/Applications/B.app", ""),
            cand("/Applications/MenuFold.app", "com.menufold.MenuFold"),
            cand("/Applications/C.app", "c"),
        ], homeDirectory: home)
        #expect(r.map(\.id) == ["c"])
    }

    @Test func dropsNested() {
        let r = AppFilter.filter([
            cand("/Applications/Xcode.app", "xcode"),
            cand("/Applications/Xcode.app/Contents/Applications/Instruments.app", "instruments"),
            cand("/Applications/Foo.app/Contents/Library/LoginItems/Helper.app", "helper"),
            cand("/Applications/Tools/Bar.app/", "bar"),
            cand("/System/Library/Frameworks/AddressBook.framework/Versions/A/Helpers/AB.app", "ab"),
            cand("/System/Library/Input Methods/AinuIM.app", "ainu"),
            cand("/Library/Image Capture/Support/X.app", "ic"),
            cand("/Users/test/Library/Application Support/Y.app", "y"),
        ], homeDirectory: home)
        #expect(Set(r.map(\.id)) == ["xcode", "bar"])
    }

    @Test func coreServicesWhitelist() {
        let r = AppFilter.filter([
            cand("/System/Volumes/Data/System/Library/CoreServices/Finder.app", "finder"),
            cand("/System/Library/CoreServices/Finder.app", "finder"),
            cand("/System/Library/CoreServices/Dock.app", "dock"),
            cand("/System/Library/CoreServices/SystemUIServer.app", "sysui"),
            cand("/System/Library/CoreServices/Applications/Archive Utility.app", "archive"),
            cand("/System/Library/CoreServices/Applications/Screen Sharing.app", "screens"),
            cand("/System/Volumes/Data/System/Library/CoreServices/Siri.app", "siri"),
        ], homeDirectory: home)
        // The Data-volume spelling is the same file: same bundle id, canonical path, whitelisted.
        #expect(Set(r.map(\.id)) == ["finder", "archive", "screens"])
        #expect(r.first { $0.id == "finder" }?.url.path == "/System/Library/CoreServices/Finder.app")
    }

    @Test func dedupPreference() {
        let old = Date(timeIntervalSince1970: 0), new = Date()
        let r = AppFilter.filter([
            cand("/Users/test/Applications/A.app", "a", date: new),
            cand("/Applications/A.app", "a", date: old),
            cand("/System/Applications/B.app", "b", date: old),
            cand("/Users/test/Applications/B.app", "b", date: new),
            cand("/Users/test/Applications/C.app", "c", date: old),
            cand("/Users/test/Desktop/C.app", "c", date: new),
            // Other volumes are excluded outright now, so the tiebreak is exercised on local paths.
            cand("/Users/test/Downloads/D.app", "d", date: old),
            cand("/Users/test/Desktop/D.app", "d", date: new),
        ], homeDirectory: home)
        let byID = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0.url.path) })
        #expect(byID["a"] == "/Applications/A.app") // /Applications wins over ~/Applications
        #expect(byID["b"] == "/System/Applications/B.app") // /System/Applications wins over ~/Applications
        #expect(byID["c"] == "/Users/test/Applications/C.app") // ~/Applications wins over anywhere else
        #expect(byID["d"] == "/Users/test/Desktop/D.app") // same rank: newest wins
    }

    @Test func sortedByName() {
        let r = AppFilter.filter([
            cand("/Applications/b.app", "b", name: "beta"),
            cand("/Applications/a.app", "a", name: "Alpha"),
            cand("/Applications/c.app", "c", name: "App 10"),
            cand("/Applications/d.app", "d", name: "App 9"),
        ], homeDirectory: home)
        #expect(r.map(\.name) == ["Alpha", "App 9", "App 10", "beta"])
    }

    /// External disks, Time Machine backups, temp dirs and the Trash: backup and throw-away copies
    /// of apps must never appear as tiles.
    @Test func dropsOtherVolumesTempAndTrash() {
        let r = AppFilter.filter([
            cand("/Volumes/Backup/X.app", "backup"),
            cand("/Volumes/.timemachine/X.app", "tm"),
            cand("/private/tmp/X.app", "tmp"),
            cand("/tmp/X.app", "tmp2"),
            cand("/private/var/folders/xy/T/X.app", "varFolders"),
            cand("/Users/test/.Trash/X.app", "trash"),
            cand("/Applications/X.app", "ok"),
        ], homeDirectory: home)
        #expect(r.map(\.id) == ["ok"])
        // A volume-mounted app folder is still fine.
        let inside = AppFilter.filter([cand("/Applications/Робота/X.app", "work")], homeDirectory: home)
        #expect(inside.map(\.id) == ["work"])
    }

    @Test func rejectsDotDotAndRelativePaths() {
        // ".." is resolved lexically: "./" is harmless, a climb above "/" or inside a root is junk.
        let r = AppFilter.filter([
            cand("/Applications/Tools/../X.app", "dots"),
            cand("/Applications/./Y.app", "dot"),
            cand("relative/Z.app", "relative"),
            cand("/Applications/W.app", "w"),
        ], homeDirectory: home)
        #expect(Set(r.map(\.id)) == ["dots", "dot", "w"])
        #expect(r.allSatisfy { $0.url.path.hasPrefix("/") })
        #expect(Set(r.map(\.url.path)) == ["/Applications/X.app", "/Applications/Y.app", "/Applications/W.app"])
    }

    /// A root account has homeDirectory "/": `~/Library` is still `/Library`, which stays excluded.
    @Test func rootHomeDirectoryStillExcludesLibrary() {
        for rootHome in ["/", ""] {
            let r = AppFilter.filter([
                cand("/Applications/A.app", "a"),
                cand("/Library/B.app", "b"),
                cand("/System/Library/CoreServices/Applications/Archive Utility.app", "archive"),
            ], homeDirectory: rootHome)
            #expect(Set(r.map(\.id)) == ["a", "archive"], "home \(rootHome)")
        }
    }

    @Test func homeDirectoryWithTrailingSlash() {
        let r = AppFilter.filter([
            cand("/Users/test/Applications/A.app", "a"),
            cand("/Users/test/Library/Application Support/B.app", "b"),
        ], homeDirectory: "/Users/test/")
        #expect(r.map(\.id) == ["a"])
    }
}

@Suite struct BundleReaderTests {
    /// Builds a temp `X.app` with `Contents/Info.plist` from `plist` (nil = no plist at all).
    func fixture(name: String = "Demo", plist: [String: Any]?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        if let plist {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        }
        return app
    }

    /// The existing test filter must clean up this suite's fixtures.
    func cleanup(_ app: URL) {
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    @Test func readsRealBundle() throws {
        let app = try fixture(plist: [
            "CFBundleIdentifier": " com.example.demo ",
            "CFBundleDisplayName": "Demo Display",
            "CFBundleName": "DemoName",
            "LSApplicationCategoryType": "public.app-category.games",
        ])
        defer { cleanup(app) }
        let c = try #require(BundleReader.candidate(atPath: app.path))
        #expect(c.bundleID == "com.example.demo") // trimmed
        #expect(c.name == "Demo Display") // DisplayName wins over Name and file name
        #expect(c.infoCategory == "public.app-category.games")
        #expect(c.modificationDate != nil)
    }

    @Test func bundleWithoutIdentityIsNotAnApp() throws {
        let noPlist = try fixture(name: "NoPlist", plist: nil)
        defer { cleanup(noPlist) }
        #expect(BundleReader.candidate(atPath: noPlist.path) == nil)

        let noID = try fixture(name: "NoID", plist: ["CFBundleName": "NoID"])
        defer { cleanup(noID) }
        #expect(BundleReader.candidate(atPath: noID.path) == nil)

        let blankID = try fixture(name: "BlankID", plist: ["CFBundleIdentifier": "   "])
        defer { cleanup(blankID) }
        #expect(BundleReader.candidate(atPath: blankID.path) == nil)

        #expect(BundleReader.candidate(atPath: "/Applications/Does Not Exist.app") == nil)
    }

    @Test func displayNameFallsBackToTheFileName() throws {
        let url = URL(fileURLWithPath: "/Applications/Fallback.app", isDirectory: true)
        #expect(BundleReader.displayName(url: url, info: nil) == "Fallback")
        #expect(BundleReader.displayName(url: url, info: ["CFBundleName": "Name Only"]) == "Name Only")
        #expect(BundleReader.displayName(url: url, info: ["CFBundleDisplayName": " ", "CFBundleName": "Name"]) == "Name")
    }

    /// A symlinked bundle is filtered by its real location, so a link from a temp dir to
    /// /Applications cannot smuggle a Temp app into the grid.
    @Test func symlinkedCandidateUsesRealPath() throws {
        let app = try fixture(plist: ["CFBundleIdentifier": "com.example.link"])
        defer { cleanup(app) }
        let link = app.deletingLastPathComponent().appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let c = try #require(BundleReader.candidate(atPath: link.path))
        #expect(c.path == app.resolvingSymlinksInPath().path)
        #expect(c.path == app.path)
    }
}
