import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct SmartAndProfileTests {
    static func app(_ id: String, _ name: String, _ cat: String? = nil, source: AppInstallSource? = nil) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                 infoCategory: cat.map { "public.app-category." + $0 }, installSource: source)
    }

    let sample: [AppEntry] = [
        app("com.adobe.photoshop", "Photoshop", "graphics-design"),
        app("com.adobe.illustrator", "Illustrator", "graphics-design", source: .appStore),
        app("com.apple.mail", "Mail", "productivity", source: .appStore),
        app("com.foo.notes", "Notes", "productivity"),
        app("com.foo.chess", "Chess", "board-games"),
    ]

    func makeModel(store: LayoutStore? = nil) -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: sample), store: store)
    }
    func ids(_ items: [GridItem]) -> [String] { items.map(\.id) }

    @Test func prefixAndSourceRulesMakeDynamicTabs() throws {
        let m = makeModel()
        let adobe = try #require(m.addSmartRule(SmartRule(name: "Adobe", bundlePrefixes: ["COM.Adobe."])))
        #expect(adobe.id.hasPrefix(AppCategory.smartPrefix))
        #expect(ids(m.items(tab: .category(adobe.category), query: "")) == ["app:com.adobe.illustrator", "app:com.adobe.photoshop"])
        // Smart tab right after custom ones, before system categories; "Графіка" is now empty and gone.
        #expect(m.availableTabs[1] == .category(adobe.category))
        let store = try #require(m.addSmartRule(SmartRule(name: "App Store", source: .appStore)))
        // Illustrator went to the first matching rule (Adobe); only Mail remains for App Store.
        #expect(ids(m.items(tab: .category(store.category), query: "")) == ["app:com.apple.mail"])
        // A rule without criteria or name is refused.
        #expect(m.addSmartRule(SmartRule(name: "Порожнє")) == nil)
        #expect(m.addSmartRule(SmartRule(name: "  ", source: .homebrew)) == nil)
    }

    @Test func tabDisappearsWhenNoAppMatches() throws {
        let m = makeModel()
        let r = try #require(m.addSmartRule(SmartRule(name: "Brew", source: .homebrew)))
        #expect(!m.availableTabs.contains(.category(r.category)))
    }

    @Test func manualOverrideWins() throws {
        let m = makeModel()
        let work = m.createCategory(named: "Робота", assigning: "com.adobe.photoshop")
        let adobe = try #require(m.addSmartRule(SmartRule(name: "Adobe", bundlePrefixes: ["com.adobe."])))
        #expect(ids(m.items(tab: .category(work), query: "")) == ["app:com.adobe.photoshop"])
        #expect(ids(m.items(tab: .category(adobe.category), query: "")) == ["app:com.adobe.illustrator"])
    }

    @Test func sizeAndUnusedCriteria() throws {
        let m = makeModel()
        m.appSizes = ["com.foo.notes": 600_000_000, "com.foo.chess": 10_000_000]
        let big = try #require(m.addSmartRule(SmartRule(name: "Великі", minSizeMB: 500)))
        #expect(ids(m.items(tab: .category(big.category), query: "")) == ["app:com.foo.notes"])
        let now = Date()
        m.now = { now }
        m.history.lastLaunched["com.foo.chess"] = now.addingTimeInterval(-40 * 86_400)
        m.history.lastLaunched["com.apple.mail"] = now.addingTimeInterval(-2 * 86_400)
        let old = try #require(m.addSmartRule(SmartRule(name: "Забуті", unusedDays: 30)))
        // Photoshop has no known launch date: it does not match.
        #expect(ids(m.items(tab: .category(old.category), query: "")) == ["app:com.foo.chess"])
    }

    @Test func rulePureMatching() {
        let rule = SmartRule(name: "x", bundlePrefixes: ["com.foo."], source: .setapp, minSizeMB: 1, unusedDays: 1)
        let a = AppEntry(id: "com.foo.a", name: "A", url: URL(fileURLWithPath: "/A.app"), infoCategory: nil, installSource: .setapp)
        let now = Date()
        #expect(rule.matches(a, size: 2_000_000, lastLaunch: now.addingTimeInterval(-90_000), now: now))
        #expect(!rule.matches(a, size: nil, lastLaunch: now.addingTimeInterval(-90_000), now: now))
        #expect(!rule.matches(a, size: 2_000_000, lastLaunch: now, now: now))
        #expect(!SmartRule(name: "n").matches(a, size: nil, lastLaunch: nil, now: now))
    }

    @Test func rulesPersistAndOldFilesLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("smart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let m = makeModel(store: store)
        let rule = try #require(m.addSmartRule(SmartRule(name: "Adobe", bundlePrefixes: ["com.adobe."], minSizeMB: 5)))
        let p = m.createProfile(named: "Робота", hidden: ["com.foo.chess"])
        m.setActiveProfile(p.id)
        let (loaded, outcome) = (LayoutStore(fileURL: store.fileURL).loadWithOutcome().layout, LayoutStore(fileURL: store.fileURL).loadWithOutcome().outcome)
        #expect(loaded.smartRules == [rule])
        #expect(loaded.profiles == [p])
        #expect(loaded.activeProfileID == p.id)
        if case .loaded = outcome {} else { Issue.record("expected loaded, got \(outcome)") }
        // An old file without the new keys loads without quarantine.
        let old = Data(#"{"version":1,"folders":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(Layout.self, from: old)
        #expect(decoded.smartRules.isEmpty && decoded.profiles.isEmpty && decoded.activeProfileID == nil)
    }

    @Test func invalidRulesAndProfilesAreDroppedOnLoad() {
        var l = Layout()
        l.smartRules = [SmartRule(id: "x.bad", name: "Bad", source: .appStore), SmartRule(name: "NoCrit"),
                        SmartRule(name: "Ok", source: .appStore)]
        l.profiles = [Profile(id: "p1", name: "A"), Profile(id: "p1", name: "Dup"), Profile(id: "p2", name: " ")]
        l.activeProfileID = "p2"
        l.categoryOrder = ["smart.gone", l.smartRules[2].id]
        let v = l.droppingInvalidFolders()
        #expect(v.smartRules.map(\.name) == ["Ok"])
        #expect(v.profiles.map(\.name) == ["A"])
        #expect(v.activeProfileID == nil)
        #expect(v.categoryOrder == [l.smartRules[2].id])
    }

    // MARK: Profiles

    @Test func profileFiltersAppsTabsAndPinned() throws {
        let m = makeModel()
        m.pin("com.apple.mail")
        let work = m.createProfile(named: "Робота", hidden: ["com.foo.chess"], pinned: ["com.foo.notes"],
                                   visibleCategories: ["public.app-category.productivity", "public.app-category.graphics-design"])
        #expect(m.profileNames == ["Робота"])
        #expect(m.items(tab: .all, query: "").count == 5)
        #expect(m.setActiveProfile(named: " робота "))
        #expect(m.activeProfileID == work.id)
        #expect(ids(m.items(tab: .all, query: "")).sorted() ==
                ["app:com.adobe.illustrator", "app:com.adobe.photoshop", "app:com.apple.mail", "app:com.foo.notes"])
        #expect(!m.availableTabs.contains(.category(.other)))
        #expect(m.visiblePinnedApps.map(\.id) == ["com.apple.mail", "com.foo.notes"])
        #expect(!m.setActiveProfile(named: "нема"))
        #expect(m.activeProfileID == work.id)
        m.setActiveProfile(nil)
        #expect(m.items(tab: .all, query: "").count == 5)
    }

    @Test func switchingProfileIsNotAnUndoStep() throws {
        let m = makeModel()
        let p = m.createProfile(named: "Дім", hidden: ["com.foo.chess"])
        m.hide("com.foo.notes")
        let steps = m.undoStack.count
        m.setActiveProfile(p.id)
        #expect(m.undoStack.count == steps)
        m.undo()  // undoes hide, keeps the profile
        #expect(m.activeProfileID == p.id)
        #expect(!m.layout.hidden.contains("com.foo.notes"))
        m.undo()  // undoes profile creation: it is gone, so no active profile
        #expect(m.profiles.isEmpty)
        #expect(m.activeProfileID == nil)
        m.redo()
        #expect(m.profiles.count == 1)
        #expect(m.activeProfileID == nil)
    }

    @Test func deletingActiveProfileResets() {
        let m = makeModel()
        let p = m.createProfile(named: "Ігри")
        m.setActiveProfile(p.id)
        m.deleteProfile(id: p.id)
        #expect(m.activeProfileID == nil)
        #expect(m.createProfile(named: "A").name == "A")
        #expect(m.createProfile(named: "a").name == "a 2")
    }
}
