import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct SearchUpgradeTests {
    nonisolated static func app(_ id: String, _ name: String, _ cat: String? = nil, path: String? = nil) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
                 infoCategory: cat.map { "public.app-category." + $0 })
    }

    nonisolated static let sample: [AppEntry] = [
        app("com.apple.Safari", "Safari"),
        app("com.google.Chrome", "Google Chrome"),
        app("com.apple.mail", "Mail", "productivity"),
        app("com.apple.dt.Xcode", "Xcode", "developer-tools"),
        app("com.microsoft.VSCode", "Visual Studio Code", "developer-tools"),
        app("com.example.zelda", "Zelda", "action-games"),
        app("com.example.chess", "Chess", "board-games"),
        app("org.nodejs.node", "Node.js"),
        app("com.example.cpp", "C++ Studio"),
        app("com.example.calc15", "Calc 1.5"),
    ]

    func model(_ apps: [AppEntry] = sample, usageStore: UsageStore? = nil) -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: apps), store: nil, usageStore: usageStore)
    }
    func titles(_ m: GridModel, _ q: String) -> [String] { m.items(tab: .all, query: q).map(\.title) }

    // MARK: keyboard layout

    @Test func punctuationAndDigitsSkipLayoutSwap() {
        #expect(!KeyboardLayout.shouldConvert("node.js"))
        #expect(!KeyboardLayout.shouldConvert("c++"))
        #expect(!KeyboardLayout.shouldConvert("1.5"))
        #expect(!KeyboardLayout.shouldConvert("office365"))
        #expect(KeyboardLayout.shouldConvert("ghbdsn"))
        #expect(KeyboardLayout.shouldConvert("ghbdsn "))
        #expect(KeyboardLayout.shouldConvert("rjv;"))
        #expect(SearchMatcher.Query("node.js").converted == nil)
        #expect(SearchMatcher.Query("c++").converted == nil)
        #expect(SearchMatcher.Query("1.5").converted == nil)
        #expect(SearchMatcher.Query("ghbdsn").converted == "привіт")
    }

    @Test func codeLikeQueriesFindApps() {
        let m = model()
        #expect(titles(m, "node.js") == ["Node.js"])
        #expect(titles(m, "c++").first == "C++ Studio")
        #expect(titles(m, "1.5").first == "Calc 1.5")
    }

    // MARK: metadata

    @Test func synonymsAndBundleID() {
        let m = model()
        #expect(titles(m, "browser").contains("Safari"))
        #expect(titles(m, "браузер").contains("Google Chrome"))
        #expect(titles(m, "ігри").contains("Zelda"))
        #expect(titles(m, "com.apple.dt") == ["Xcode"])
        #expect(titles(m, "nodejs").first == "Node.js")
        // A name match always beats metadata.
        let s = SearchMatcher.Target(names: ["Safari"], keywords: ["browser"], bundleID: "com.apple.safari")
        let byName = SearchMatcher.score(s, SearchMatcher.Query("safa"))!
        let byKeyword = SearchMatcher.score(s, SearchMatcher.Query("brow"))!
        #expect(byName > byKeyword)
        // Short queries never match by bundle ID.
        #expect(!titles(m, "exa").contains("Zelda"))
    }

    // MARK: prefixes

    @Test func prefixScopes() {
        let m = model()
        let id = m.createFolder(dropping: "com.apple.mail", onto: "com.apple.Safari")!
        m.rename(folder: id, to: "Zeta")
        #expect(titles(m, "/zet") == ["Zeta"])
        #expect(titles(m, ">zet").isEmpty)
        #expect(titles(m, ">zel") == ["Zelda"])
        #expect(titles(m, "/zel").isEmpty)
        #expect(titles(m, "?zel").isEmpty)
        #expect(m.items(tab: .all, query: ">").count == Self.sample.count)
        #expect(titles(m, "@розр").sorted() == ["Visual Studio Code", "Xcode"])
        #expect(titles(m, "@developer vis") == ["Visual Studio Code"])
        #expect(titles(m, "@").isEmpty)
    }

    @Test func settingsPrefix() {
        let m = model()
        m.query = "?bluetooth"
        #expect(!m.settingsPaneResults.isEmpty)
        #expect(m.matchingTabs.isEmpty)
        m.query = ">bluetooth"
        #expect(m.settingsPaneResults.isEmpty)
        m.query = "bluetooth"
        #expect(!m.settingsPaneResults.isEmpty)
    }

    // MARK: ranking

    @Test func adaptiveRanking() {
        let apps = [Self.app("a", "Alpha Tool"), Self.app("b", "Alpha Tune")]
        let m = model(apps)
        let first = titles(m, "alpha")
        let loser = first[1]
        let id = loser == "Alpha Tool" ? "a" : "b"
        m.query = "alpha"
        m.rememberSearchChoice(appID: id)
        m.rememberSearchChoice(appID: id)
        #expect(titles(m, "alpha").first == loser)
        // Another query is not affected, and an exact match still wins its tier.
        #expect(m.searchChoices.bonus(forFoldedQuery: "zzz", appID: id) == 0)
    }

    @Test func adaptivePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("choices-\(UUID().uuidString)")
        let usage = UsageStore(fileURL: dir.appendingPathComponent("usage.json"))
        let m = model(usageStore: usage)
        m.query = "saf"
        m.rememberSearchChoice(appID: "com.apple.Safari")
        let m2 = model(usageStore: usage)
        #expect(m2.searchChoices.bonus(forFoldedQuery: "saf", appID: "com.apple.Safari") > 0)
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func choiceBonusStaysInTier() {
        var c = SearchChoices()
        for _ in 0..<10 { c.record(query: "ab", appID: "x", at: Date()) }
        #expect(c.bonus(forFoldedQuery: "ab", appID: "x") <= SearchChoices.maxBonus)
        c.record(query: "a", appID: "x", at: Date())
        #expect(c.entries["a"] == nil)
    }

    // MARK: narrowing

    @Test func narrowingMatchesFullSearch() {
        let names = ["Safari", "Visual Studio Code", "Adobe Photoshop", "System Settings", "Xcode", "Calculator",
                     "Google Chrome", "Zoom", "Slack", "Spotify", "Sublime Text", "Terminal", "TextEdit"]
        let apps = names.enumerated().map { Self.app("id.\($0.offset)", $0.element) }
        let typing = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        for word in ["system settings", "visual studio", "sublime", "google chr", "photoshop", "calculator"] {
            var q = ""
            for ch in word {
                q.append(ch)
                let fresh = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
                #expect(typing.items(tab: .all, query: q).map(\.id) == fresh.items(tab: .all, query: q).map(\.id),
                        "query \(q)")
            }
        }
    }

    // MARK: perf / caches

    @Test func largeCatalogSearchIsFast() {
        var apps: [AppEntry] = []
        for i in 0..<800 {
            let folder = i % 10 == 0 ? "/Applications/Suite\(i % 7)" : "/Applications"
            apps.append(Self.app("com.vendor\(i).app", "Application Number \(i) Pro", path: "\(folder)/App\(i).app"))
        }
        let m = model(apps)
        let start = Date()
        var q = ""
        for ch in "application number 7" {
            q.append(ch)
            _ = m.items(tab: .all, query: q)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "took \(elapsed)s")
        #expect(m.allFolders.count == 7)
        // Cache follows layout changes.
        let f = m.allFolders.first!
        m.dissolve(folder: f.id)
        #expect(m.allFolders.count == 6)
    }
}
