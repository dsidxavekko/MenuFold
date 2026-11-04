import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct GridModelTests {
    static func app(_ id: String, _ name: String, _ cat: String? = nil) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                 infoCategory: cat.map { "public.app-category." + $0 })
    }

    let sample: [AppEntry] = [
        app("mail", "Mail", "productivity"),
        app("notes", "Notes", "productivity"),
        app("chess", "Chess", "board-games"),
        app("xcode", "Xcode", "developer-tools"),
        app("safari", "Safari"),
        app("cafe", "Café"),
    ]

    func makeModel(store: LayoutStore? = nil) -> (GridModel, StaticAppCatalog) {
        let cat = StaticAppCatalog(apps: sample)
        return (GridModel(catalog: cat, store: store), cat)
    }

    func titles(_ items: [GridItem]) -> [String] { items.map(\.title) }

    @Test func allTabAlphabetical() {
        let (m, _) = makeModel()
        #expect(titles(m.items(tab: .all, query: "")) == ["Café", "Chess", "Mail", "Notes", "Safari", "Xcode"])
    }

    @Test func createFolderAndAdd() throws {
        let (m, _) = makeModel()
        #expect(m.createFolder(dropping: "mail", onto: "mail") == nil)
        #expect(m.createFolder(dropping: "mail", onto: "missing") == nil)
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        #expect(m.renamingFolderID == id)
        #expect(m.folder(id: id)?.name == "Нова папка")
        #expect(m.folder(id: id)?.appIDs == ["mail", "notes"])
        #expect(m.folderContaining(appID: "notes")?.id == id)
        #expect(titles(m.items(tab: .all, query: "")) == ["Café", "Chess", "Нова папка", "Safari", "Xcode"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })

        m.add("xcode", to: id)
        #expect(m.apps(in: m.folder(id: id)!).map(\.id) == ["mail", "notes", "xcode"])

        // Dropping onto an app that is already in a folder joins that folder.
        #expect(m.createFolder(dropping: "chess", onto: "mail") == id)
        #expect(m.folder(id: id)?.appIDs.contains("chess") == true)
    }

    @Test func moveBetweenFoldersDissolvesSource() throws {
        let (m, _) = makeModel()
        let a = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let b = try #require(m.createFolder(dropping: "xcode", onto: "chess"))
        m.add("xcode", to: a)
        #expect(m.folder(id: b) == nil) // chess alone → dissolved
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes", "xcode"])
    }

    @Test func removeDissolvesAtOne() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.add("xcode", to: id)
        m.removeFromFolder("xcode")
        #expect(m.folder(id: id)?.appIDs == ["mail", "notes"])
        m.openFolderID = id
        m.removeFromFolder("notes")
        #expect(m.folder(id: id) == nil)
        #expect(m.layout.folders.isEmpty)
        #expect(m.openFolderID == nil)
    }

    @Test func renameStyleDissolve() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.rename(folder: id, to: "  Робота ")
        m.rename(folder: id, to: "   ")
        #expect(m.folder(id: id)?.name == "Робота")
        m.setStyle(folder: id, color: .red, symbol: "star")
        #expect(m.folder(id: id)?.color == .red)
        #expect(m.folder(id: id)?.symbol == "star")
        m.dissolve(folder: id)
        #expect(m.layout.folders.isEmpty)
        #expect(m.items(tab: .all, query: "").count == sample.count)
    }

    @Test func hiddenAppsExcluded() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.hide("safari")
        m.hide("mail")
        m.hide("notes")
        let all = m.items(tab: .all, query: "")
        #expect(!titles(all).contains("Safari"))
        #expect(!all.contains { if case .folder = $0 { return true }; return false }) // 0 visible → not shown
        #expect(m.items(tab: .all, query: "saf").isEmpty)
        #expect(m.hiddenApps.map(\.id) == ["mail", "notes", "safari"])
        m.unhide("mail")
        #expect(m.apps(in: m.folder(id: id)!).map(\.id) == ["mail"])
        #expect(m.items(tab: .all, query: "").contains { $0.id == "folder:\(id.uuidString)" })
    }

    @Test func categoryOverrides() {
        let (m, _) = makeModel()
        let safari = sample.first { $0.id == "safari" }!
        #expect(m.category(of: safari) == .other)
        let dev = AppCategory.from(raw: "public.app-category.developer-tools")
        m.setCategory(dev, for: "safari")
        #expect(m.category(of: safari) == dev)
        #expect(titles(m.items(tab: .category(dev), query: "")) == ["Safari", "Xcode"])
        m.setCategory(nil, for: "safari")
        #expect(m.category(of: safari) == .other)
    }

    @Test func categoryTabIgnoresFolders() throws {
        let (m, _) = makeModel()
        _ = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let prod = AppCategory.from(raw: "public.app-category.productivity")
        #expect(titles(m.items(tab: .category(prod), query: "")) == ["Mail", "Notes"])
    }

    @Test func searchIncludesFolderAppsAndIgnoresTab() throws {
        let (m, _) = makeModel()
        _ = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let games = AppCategory.from(raw: "public.app-category.games")
        #expect(titles(m.items(tab: .category(games), query: "NOT")) == ["Notes"])
        #expect(titles(m.items(tab: .all, query: "cafe")) == ["Café"]) // diacritic-insensitive
        #expect(titles(m.items(tab: .all, query: " A ")) == ["Café", "Mail", "Safari"])
    }

    @Test func tabs() {
        let (m, _) = makeModel()
        let names = m.availableTabs.map { tab -> String in
            switch tab {
            case .all: return "*"
            case .category(let c): return c.displayName
            }
        }
        #expect(names == ["*", "Ігри", "Продуктивність", "Розробка", "Інше"])
        m.hide("chess")
        #expect(!m.availableTabs.contains(.category(AppCategory.from(raw: "public.app-category.games"))))
    }

    @Test func catalogChangesKeepFolders() throws {
        let (m, cat) = makeModel()
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.openFolderID = id
        cat.replace(sample.filter { $0.id != "mail" && $0.id != "notes" })
        #expect(m.folder(id: id) != nil)
        #expect(m.openFolderID == nil)
        #expect(!m.items(tab: .all, query: "").contains { $0.id == "folder:\(id.uuidString)" })
        cat.replace(sample)
        #expect(m.apps(in: m.folder(id: id)!).count == 2)
    }

    @Test func panelDidOpenResets() {
        let (m, _) = makeModel()
        m.query = "x"
        m.openFolderID = UUID()
        m.panelDidOpen()
        #expect(m.query.isEmpty)
        #expect(m.openFolderID == nil)
    }

    @Test func staleTabFallsBackToAll() {
        let (m, cat) = makeModel()
        let games = GridTab.category(AppCategory.from(raw: "public.app-category.games"))
        let prod = GridTab.category(AppCategory.from(raw: "public.app-category.productivity"))
        m.tab = games
        m.panelDidOpen()
        #expect(m.tab == games) // still valid → kept
        m.hide("chess") // last game
        #expect(m.tab == .all)

        m.tab = prod
        cat.replace(sample.filter { $0.id != "mail" && $0.id != "notes" })
        #expect(m.tab == .all)

        m.tab = prod // set while unavailable (e.g. by UI); panel open repairs it
        m.panelDidOpen()
        #expect(m.tab == .all)
    }

    @Test func isLoaded() {
        let cat = StaticAppCatalog(apps: [])
        let m = GridModel(catalog: cat, store: nil)
        #expect(m.isLoaded) // StaticAppCatalog loads on start(), even when empty
        #expect(cat.isLoaded)
    }

    @Test func intentsPersistAndReload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("sub/layout.json"))
        let (m, _) = makeModel(store: store)
        let id = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.hide("safari")
        let (m2, _) = makeModel(store: store)
        #expect(m2.folder(id: id)?.appIDs == ["mail", "notes"])
        #expect(m2.layout.hidden == ["safari"])
        m2.resetLayout()
        #expect(store.load() == Layout())
    }

    @Test func previewModel() {
        let m = GridModel.preview
        #expect(m.apps.count >= 14)
        #expect(m.layout.folders.first?.name == "Робота")
        #expect(m.items(tab: .all, query: "").contains { $0.title == "Робота" })
    }
}
