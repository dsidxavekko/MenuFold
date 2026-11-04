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
            cand("/System/Library/CoreServices/Finder.app", "finder"),
            cand("/System/Library/CoreServices/Dock.app", "dock"),
            cand("/System/Library/CoreServices/SystemUIServer.app", "sysui"),
            cand("/System/Library/CoreServices/Applications/Archive Utility.app", "archive"),
            cand("/System/Library/CoreServices/Applications/Screen Sharing.app", "screens"),
            cand("/System/Volumes/Data/System/Library/CoreServices/Siri.app", "siri"),
        ], homeDirectory: home)
        #expect(Set(r.map(\.id)) == ["finder", "archive", "screens"])
    }

    @Test func dedupPreference() {
        let old = Date(timeIntervalSince1970: 0), new = Date()
        let r = AppFilter.filter([
            cand("/Users/test/Applications/A.app", "a", date: new),
            cand("/Applications/A.app", "a", date: old),
            cand("/System/Applications/B.app", "b", date: old),
            cand("/Users/test/Applications/B.app", "b", date: new),
            cand("/Users/test/Applications/C.app", "c", date: old),
            cand("/Volumes/Ext/C.app", "c", date: new),
            cand("/Volumes/X/D.app", "d", date: old),
            cand("/Volumes/Y/D.app", "d", date: new),
        ], homeDirectory: home)
        let byID = Dictionary(uniqueKeysWithValues: r.map { ($0.id, $0.url.path) })
        #expect(byID["a"] == "/Applications/A.app")
        #expect(byID["b"] == "/System/Applications/B.app")
        #expect(byID["c"] == "/Users/test/Applications/C.app")
        #expect(byID["d"] == "/Volumes/Y/D.app")
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
}
