import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct SearchMatcherTests {
    func s(_ text: String, _ q: String) -> Double? { SearchMatcher.score(text, query: q) }

    @Test func tiersOrder() throws {
        let exact = try #require(s("Safari", "safari"))
        let prefix = try #require(s("Safari", "saf"))
        let word = try #require(s("Visual Studio Code", "stu"))
        let initials = try #require(s("Visual Studio Code", "vsc"))
        let substring = try #require(s("Safari", "far"))
        let fuzzy = try #require(s("Adobe Photoshop", "ps"))
        #expect(exact > prefix && prefix > word && word > initials && initials > substring && substring > fuzzy)
    }

    @Test func caseAndDiacritics() {
        #expect(s("Café", "CAFE") != nil)
        #expect(s("Калькулятор", "КАЛЬК") != nil)
    }

    @Test func wordsAndCamelCase() {
        #expect(s("iMovie", "mov") != nil)
        #expect(SearchMatcher.splitWords("VSCode") == ["VS", "Code"])
        #expect(SearchMatcher.splitWords("Office365 Pro") == ["Office", "365", "Pro"])
        #expect(s("Visual Studio Code", "vis cod") != nil)
        #expect(s("Visual Studio Code", "cod vis") == nil)
    }

    @Test func oneCharacterOnlyStartsWords() {
        #expect(s("Safari", "s") != nil)
        #expect(s("Visual Studio Code", "c") != nil)
        #expect(s("Safari", "a") == nil)
        #expect(s("Safari", "f") == nil)
    }

    @Test func fuzzy() {
        #expect(s("Adobe Photoshop", "ps") != nil)
        #expect(s("System Settings", "sysset") != nil)
        #expect(s("Safari", "xz") == nil)
        // The first letter must start a word.
        #expect(s("Safari", "ai") == nil)
        // Letters spread too thin are not a match.
        #expect(s("Disk Utility", "dy") == nil)
    }

    @Test func wrongKeyboardLayout() throws {
        #expect(KeyboardLayout.convert("іфа") == "saf")
        #expect(KeyboardLayout.convert("сщву") == "code")
        #expect(KeyboardLayout.convert("ghbdsn") == "привіт")
        #expect(KeyboardLayout.convert("123") == nil)
        let swapped = try #require(s("Safari", "іфа"))
        let direct = try #require(s("Safari", "saf"))
        #expect(swapped < direct)
        #expect(s("Visual Studio Code", "сщву") != nil)
        #expect(s("Нотатки", "yjnf") != nil)
        // Same tier as a direct prefix match, just lower.
        #expect(swapped > (try #require(s("Visual Studio Code", "stu"))))
    }

    @Test func emptyQuery() {
        #expect(s("Safari", "") == nil)
        #expect(s("Safari", "   ") == nil)
    }
}

@MainActor
@Suite struct GridSearchTests {
    static func app(_ id: String, _ name: String, _ cat: String? = nil, path: String? = nil,
                    alternate: String? = nil) -> AppEntry {
        AppEntry(id: id, name: name, alternateName: alternate,
                 url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
                 infoCategory: cat.map { "public.app-category." + $0 })
    }

    let sample: [AppEntry] = [
        app("vscode", "Visual Studio Code", "developer-tools"),
        app("ps", "Adobe Photoshop"),
        app("pages", "Pages", "productivity"),
        app("safari", "Safari"),
        app("sysset", "System Settings"),
        app("calc", "Калькулятор", alternate: "Calculator"),
        app("code2", "Codex"),
        app("xcode", "Xcode", "developer-tools"),
    ]

    func model() -> GridModel { GridModel(catalog: StaticAppCatalog(apps: sample), store: nil) }
    func titles(_ m: GridModel, _ q: String) -> [String] { m.items(tab: .all, query: q).map(\.title) }

    @Test func rankingPutsBestMatchFirst() {
        let m = model()
        // Prefix "Codex" beats word-prefix "Visual Studio Code" beats substring "Xcode".
        #expect(titles(m, "code") == ["Codex", "Visual Studio Code", "Xcode"])
        #expect(titles(m, "vsc").first == "Visual Studio Code")
        #expect(titles(m, "сщву").first == "Codex") // wrong layout
        #expect(titles(m, "calc") == ["Калькулятор"]) // alternate name
        #expect(titles(m, "ps").contains("Adobe Photoshop"))
    }

    @Test func usageBreaksTies() {
        let m = model()
        #expect(titles(m, "s").prefix(2) == ["Safari", "System Settings"])
        m.recordUse(appID: "sysset")
        #expect(titles(m, "s").prefix(2) == ["System Settings", "Safari"])
    }

    @Test func hiddenAppsNeverAppear() {
        let m = model()
        m.hide("safari")
        #expect(!titles(m, "saf").contains("Safari"))
    }

    @Test func foldersInResults() throws {
        let m = model()
        let id = try #require(m.createFolder(dropping: "pages", onto: "safari"))
        m.rename(folder: id, to: "Office")
        let items = m.items(tab: .all, query: "off")
        #expect(items.map(\.id) == ["folder:\(id.uuidString)"])
        // Apps inside folders are still found.
        #expect(titles(m, "pag") == ["Pages"])
        // A folder with no visible apps is not offered.
        m.hide("pages")
        m.hide("safari")
        #expect(m.items(tab: .all, query: "off").isEmpty)
    }

    @Test func finderFoldersInResults() {
        let apps = [Self.app("term", "Terminal", path: "/System/Applications/Utilities/Terminal.app"),
                    Self.app("mail", "Mail")]
        let m = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        let folders = m.items(tab: .all, query: "").filter { if case .folder = $0 { return true }; return false }
        guard let folder = folders.first else { return }
        let q = String(folder.title.prefix(3))
        #expect(m.items(tab: .all, query: q).contains { $0.id == folder.id })
    }

    @Test func matchingTabs() {
        let m = model()
        m.showsRunningTab = true
        m.query = ""
        #expect(m.matchingTabs.isEmpty)
        m.query = "розр"
        #expect(m.matchingTabs == [.category(AppCategory.from(raw: "public.app-category.developer-tools"))])
        m.query = "запущ"
        #expect(m.matchingTabs == [.running])
        m.query = "zzz"
        #expect(m.matchingTabs.isEmpty)
    }

    @Test func settingsPanes() {
        let m = model()
        m.query = "b"
        #expect(m.settingsPaneResults.isEmpty) // one character: no panes
        m.query = "blue"
        #expect(m.settingsPaneResults.first?.id == "com.apple.BluetoothSettings")
        m.query = "displays"
        #expect(m.settingsPaneResults.first?.id == "com.apple.Displays-Settings.extension")
        m.query = "дисп"
        #expect(m.settingsPaneResults.first?.id == "com.apple.Displays-Settings.extension")
        m.query = "wifi"
        #expect(m.settingsPaneResults.first?.id == "com.apple.wifi-settings-extension")
        m.query = "s"
        #expect(m.settingsPaneResults.isEmpty)
        m.query = "se"
        #expect(m.settingsPaneResults.count <= 8)
        #expect(m.settingsPaneResults.allSatisfy { $0.url.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.") })
    }

    @Test func paneCatalogIsSane() {
        let catalog = SystemSettingsPane.catalog
        #expect(catalog.count >= 40)
        #expect(Set(catalog.map(\.pane.id)).count == catalog.count)
        #expect(catalog.allSatisfy { !$0.pane.symbol.isEmpty && !$0.pane.name.isEmpty })
    }
}
