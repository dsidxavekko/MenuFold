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
        #expect(m.folder(id: b) == nil) // source: chess alone → dissolved
        // The target must keep everything it had and gain the moved app.
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes", "xcode"])
        #expect(m.folderContaining(appID: "chess") == nil)
    }

    /// The regression: `detach` used to dissolve every ≤1-app folder, so one drag could delete the
    /// drop TARGET's folder too. Now only the folder the dragged app actually left may dissolve.
    /// Here the target is a top-level app in no folder, so a new folder is built — and the old one
    /// is left alone entirely.
    @Test func createFolderNeverDestroysTheTargetsFolder() throws {
        let (m, _) = makeModel()
        // "Ігри" = {chess, xcode}: the dragged app's source.
        let games = try #require(m.createFolder(dropping: "xcode", onto: "chess"))
        m.rename(folder: games, to: "Ігри")
        // "Робота" = {notes, safari}: must survive the drag untouched.
        let work = try #require(m.createFolder(dropping: "safari", onto: "notes"))
        m.rename(folder: work, to: "Робота")

        // mail is top-level (in no folder) → new folder {mail, xcode}.
        let new = try #require(m.createFolder(dropping: "xcode", onto: "mail"))
        // Source is left with chess alone → dissolved by the documented rule.
        #expect(m.folder(id: games) == nil)
        #expect(m.folderContaining(appID: "chess") == nil)
        // The unrelated folder survives, same id, name and members.
        #expect(m.folder(id: work)?.name == "Робота")
        #expect(m.folder(id: work)?.appIDs == ["notes", "safari"])
        // The new folder holds exactly the two dropped apps.
        #expect(m.folder(id: new)?.appIDs == ["mail", "xcode"])
        #expect(m.folder(id: new)?.name == "Нова папка")
        #expect(m.renamingFolderID == new)
        // No app vanished: six apps, one new folder tile.
        #expect(titles(m.items(tab: .all, query: "")).sorted()
                == ["Café", "Chess", "Нова папка", "Робота"].sorted())
    }

    /// A drop onto an app that already sits in a manual folder joins THAT folder (documented behaviour):
    /// no new folder, the target's folder keeps its id/name, and only the dragged app's old folder can go.
    @Test func createFolderOntoAppInAFolderJoinsIt() throws {
        let (m, _) = makeModel()
        let games = try #require(m.createFolder(dropping: "safari", onto: "chess"))
        m.rename(folder: games, to: "Ігри")
        let work = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.rename(folder: work, to: "Робота")

        let joined = m.createFolder(dropping: "chess", onto: "mail")
        #expect(joined == work)
        #expect(m.layout.folders.count == 2 - 1) // only the emptied source went
        #expect(m.folder(id: work)?.name == "Робота")
        #expect(m.folder(id: work)?.appIDs == ["mail", "notes", "chess"])
        // The source is left with safari alone → dissolved by the documented rule; safari surfaces at top level.
        #expect(m.folder(id: games) == nil)
        #expect(m.folderContaining(appID: "safari") == nil)
        #expect(titles(m.items(tab: .all, query: "")).contains("Safari"))
    }

    /// A folder is measured on stored IDs, not on visible apps: hiding the dragged app's only sibling
    /// must not let the move dissolve the target folder, and a hidden member is never resurrected.
    @Test func createFolderCountsStoredAppsNotVisibleOnes() throws {
        let (m, _) = makeModel()
        // "Веб" = {safari, chess}; safari is hidden, so chess is its only visible app.
        let web = try #require(m.createFolder(dropping: "chess", onto: "safari"))
        m.hide("safari")
        #expect(m.apps(in: m.folder(id: web)!).map(\.id) == ["chess"])

        // Drop mail onto chess: chess already sits in "Веб", so mail joins it — the drag can't create a
        // second folder or dissolve the target's. The hidden safari is not resurrected anywhere.
        let joined = try #require(m.createFolder(dropping: "mail", onto: "chess"))
        #expect(joined == web)
        #expect(m.folder(id: web)?.appIDs == ["safari", "chess", "mail"])
    }

    @Test func dropOntoTargetInAFolderJoinsThatFolder() throws {
        // The contract for a target that already sits in a manual folder: dropping onto it means
        // "join that folder" (CLAUDE.md), so the returned id is the existing folder and the other
        // members keep their home. A drop must never dissolve or rename the folder either way.
        let (m, _) = makeModel()
        let seed = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.add("xcode", to: seed)
        m.add("safari", to: seed)
        m.rename(folder: seed, to: "Робота")
        #expect(m.folder(id: seed)?.appIDs.count == 4)

        // Evaluate the call once: `== nil` on the returned value is what is asserted, and writing
        // the call itself inside an interpolation is evaluated more than once.
        let joined: UUID? = m.createFolder(dropping: "chess", onto: "mail")
        #expect(joined == seed)                                  // the folder itself, not a new one
        #expect(m.folder(id: seed)?.name == "Робота")            // name/colour survive
        #expect(m.layout.folders.count == 1)                     // nothing new, nothing dissolved
        #expect(m.folder(id: seed)?.appIDs.count == 5)
        #expect(m.renamingFolderID == nil)                       // no inline rename is started
        // The same holds when other members are hidden: stored appIDs are what count.
        m.hide("notes")
        m.hide("safari")
        let joinedWithHidden: UUID? = m.createFolder(dropping: "cafe", onto: "mail")
        #expect(joinedWithHidden == seed)
        #expect(m.folder(id: seed)?.appIDs.count == 6)
        #expect(m.layout.folders.count == 1)
        // Repeating the exact drop is a no-op.
        let repeated: UUID? = m.createFolder(dropping: "cafe", onto: "mail")
        #expect(repeated == nil)
        #expect(m.folder(id: seed)?.appIDs.count == 6)
    }

    @Test func dropOntoSoleMemberOfItsFolderMovesIt() throws {
        // The target is alone in a folder that would be dissolved anyway (≤1 app): it moves into the
        // new folder with the dropped app.
        let (m, _) = makeModel()
        let lonely = Folder(name: "Самотня", appIDs: ["mail"])
        m.resetLayout()
        var l = m.layout
        l.folders = [lonely]
        m.hide("safari")                       // force a commit that keeps the folder in memory
        m.unhide("safari")
        let new = try #require(m.createFolder(dropping: "xcode", onto: "mail"))
        #expect(m.folder(id: new)?.appIDs == ["mail", "xcode"])
    }

    @Test func addToAFolderNeverDissolvesIt() throws {
        let (m, _) = makeModel()
        let a = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let b = try #require(m.createFolder(dropping: "chess", onto: "xcode"))
        m.add("safari", to: a)
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes", "safari"])
        m.add("safari", to: b) // moves out of a, into b
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes"]) // still ≥2 → intact
        #expect(m.folder(id: b)?.appIDs == ["xcode", "chess", "safari"]) // b was {xcode, chess}; safari appended
        #expect(m.folderContaining(appID: "safari")?.id == b)
    }

    /// A move into a folder never dissolves that folder, and the app left alone in its old folder
    /// dissolves only the old one (regression: one sweep used to hit both).
    @Test func addIntoThirdFolderDissolvesOnlyTheSource() throws {
        let (m, _) = makeModel()
        let a = try #require(m.createFolder(dropping: "notes", onto: "mail")) // {mail, notes}
        let b = try #require(m.createFolder(dropping: "xcode", onto: "chess")) // {chess, xcode}
        let c = try #require(m.createFolder(dropping: "safari", onto: "cafe")) // {safari, café}
        m.add("safari", to: a) // café left alone → dissolved
        #expect(m.folder(id: c) == nil)
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes", "safari"])
        m.add("safari", to: b) // moves out of a (2 left) into b
        #expect(m.folder(id: a)?.appIDs == ["mail", "notes"]) // intact
        #expect(m.folder(id: b)?.appIDs == ["chess", "xcode", "safari"]) // b was {chess, xcode}; safari appended
    }

    /// Every rejected drop clears `renamingFolderID`, so the UI can't start renaming a stale folder.
    @Test func invalidCreateFolderClearsRenamingRequest() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "safari", onto: "chess"))
        #expect(m.renamingFolderID == id)

        #expect(m.createFolder(dropping: "mail", onto: "mail") == nil)
        #expect(m.renamingFolderID == nil)

        m.renamingFolderID = id // as if the user was still renaming
        #expect(m.createFolder(dropping: "missing", onto: "mail") == nil)
        #expect(m.renamingFolderID == nil)

        m.renamingFolderID = id
        // Already a member of the target's folder → nothing to do, but the rename request is cleared.
        let work = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.renamingFolderID = work
        #expect(m.createFolder(dropping: "notes", onto: "mail") == nil)
        #expect(m.renamingFolderID == nil)
    }

    @Test func setCategoryNilIsANoOpWithoutAnOverride() {
        let (m, _) = makeModel()
        let before = m.layout
        m.setCategory(nil, for: "mail") // no override to remove
        m.setCategory(nil, for: "does.not.exist") // unknown ID
        #expect(m.layout == before)
        #expect(m.layout.categoryOverrides.isEmpty)

        m.setCategory(AppCategory.from(raw: "public.app-category.games"), for: "mail")
        #expect(m.layout.categoryOverrides == ["mail": "public.app-category.games"])
        m.setCategory(AppCategory.from(raw: "public.app-category.games"), for: "mail") // same value again
        #expect(m.layout.categoryOverrides == ["mail": "public.app-category.games"])
        m.setCategory(nil, for: "mail")
        #expect(m.layout.categoryOverrides.isEmpty)
        m.setCategory(nil, for: "mail") // second clear is a no-op
        #expect(m.layout.categoryOverrides.isEmpty)
    }

    /// The store writes `Layout.currentVersion`; the in-memory layout must agree, even when the loaded
    /// file had another version (and stays quiet on repeats, so nothing is rewritten for nothing).
    @Test func commitKeepsMemoryAndDiskVersionInStep() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("layout.json")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"version":0,"hidden":["safari"]}"#.utf8).write(to: url)

        let store = LayoutStore(fileURL: url)
        let (m, _) = makeModel(store: store)
        #expect(m.layout.version == Layout.currentVersion) // LayoutStore normalizes on load
        m.hide("chess")
        #expect(m.layout.version == Layout.currentVersion)
        #expect(try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url)).version == Layout.currentVersion)

        // A repeated identical intent doesn't change the layout (so it can't cause a rewrite).
        let applied = m.layout
        m.hide("chess")
        #expect(m.layout == applied)
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
            case .running: return "▶"
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
        m.tab = .category(AppCategory.from(raw: "public.app-category.productivity"))
        m.panelDidOpen()
        #expect(m.query.isEmpty)
        #expect(m.openFolderID == nil)
        #expect(m.tab == .all)
    }

    @Test func staleTabFallsBackToAll() {
        let (m, cat) = makeModel()
        let games = GridTab.category(AppCategory.from(raw: "public.app-category.games"))
        let prod = GridTab.category(AppCategory.from(raw: "public.app-category.productivity"))
        m.tab = games
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
