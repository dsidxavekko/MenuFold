import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct ArrangeTests {
    nonisolated static func app(_ id: String, _ name: String, _ cat: String? = nil) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                 infoCategory: cat.map { "public.app-category." + $0 })
    }

    nonisolated static let sample: [AppEntry] = [
        app("mail", "Mail", "productivity"),
        app("notes", "Notes", "productivity"),
        app("chess", "Chess", "board-games"),
        app("xcode", "Xcode", "developer-tools"),
        app("safari", "Safari"),
        app("cafe", "Café"),
    ]

    func makeModel(_ apps: [AppEntry] = ArrangeTests.sample) -> (GridModel, StaticAppCatalog) {
        let cat = StaticAppCatalog(apps: apps)
        return (GridModel(catalog: cat, store: nil), cat)
    }

    func allIDs(_ m: GridModel) -> [String] { m.items(tab: .all, query: "").map(\.id) }

    // MARK: Pinned

    @Test func pinOrderAndDedupe() {
        let (m, _) = makeModel()
        m.pin("notes")
        m.pin("mail")
        m.pin("notes") // no-op
        m.pin("")      // ignored
        #expect(m.layout.pinned == ["notes", "mail"])
        #expect(m.pinnedApps.map(\.id) == ["notes", "mail"])
        #expect(m.isPinned("mail"))
        #expect(!m.isPinned("chess"))
        m.unpin("notes")
        #expect(m.layout.pinned == ["mail"])
    }

    @Test func pinnedRowOnlyOnAllWithoutQuery() {
        let (m, _) = makeModel()
        m.pin("mail")
        m.query = "mai"
        #expect(m.pinnedApps.isEmpty)
        m.query = ""
        m.tab = .category(AppCategory.from(raw: "public.app-category.productivity"))
        #expect(m.pinnedApps.isEmpty)
        m.tab = .all
        m.showsPinned = false
        #expect(m.pinnedApps.isEmpty)
        m.showsPinned = true
        #expect(m.pinnedApps.map(\.id) == ["mail"])
    }

    @Test func pinnedKeepsUninstalledAndHiddenApps() {
        let (m, cat) = makeModel()
        m.pin("mail"); m.pin("notes"); m.pin("chess")
        cat.replace(Self.sample.filter { $0.id != "notes" })
        m.hide("chess")
        #expect(m.pinnedApps.map(\.id) == ["mail"])
        #expect(m.layout.pinned == ["mail", "notes", "chess"])
        cat.replace(Self.sample)
        #expect(m.pinnedApps.map(\.id) == ["mail", "notes"])
    }

    @Test func movePinnedStepsOverInvisible() {
        let (m, cat) = makeModel()
        m.pin("mail"); m.pin("notes"); m.pin("chess")
        cat.replace(Self.sample.filter { $0.id != "notes" })
        m.movePinned("chess", by: -1)
        #expect(m.pinnedApps.map(\.id) == ["chess", "mail"])
        // The uninstalled app keeps its slot.
        #expect(m.layout.pinned == ["chess", "notes", "mail"])
        m.movePinned("chess", by: -1) // already first
        #expect(m.layout.pinned == ["chess", "notes", "mail"])
        m.movePinned("mail", by: 1)   // already last
        #expect(m.layout.pinned == ["chess", "notes", "mail"])
    }

    @Test func pinnedAppsLeftOutOfFrequent() {
        let (m, _) = makeModel()
        m.frequentLimit = 2
        m.usage.entries = ["mail": .init(score: 3, lastUsed: m.now()), "notes": .init(score: 2, lastUsed: m.now()),
                           "chess": .init(score: 1, lastUsed: m.now())]
        #expect(m.frequentApps.map(\.id) == ["mail", "notes"])
        m.pin("mail")
        #expect(m.frequentApps.map(\.id) == ["notes", "chess"])
        m.showsPinned = false
        #expect(m.frequentApps.map(\.id) == ["mail", "notes"])
    }

    @Test func pinnedValidation() {
        let l = Layout(pinned: ["a", "", "b", "a"], manualOrder: ["app:x", "", "app:x", "folder:y"])
            .droppingInvalidFolders()
        #expect(l.pinned == ["a", "b"])
        #expect(l.manualOrder == ["app:x", "folder:y"])
        #expect(Layout().droppingInvalidFolders().manualOrder == nil)
    }

    // MARK: Manual order

    @Test func moveItemMaterializesOrder() {
        let (m, _) = makeModel()
        #expect(!m.hasManualOrder)
        #expect(allIDs(m) == ["app:cafe", "app:chess", "app:mail", "app:notes", "app:safari", "app:xcode"])
        m.moveItem("app:xcode", relativeTo: "app:cafe", after: false)
        #expect(m.hasManualOrder)
        #expect(allIDs(m) == ["app:xcode", "app:cafe", "app:chess", "app:mail", "app:notes", "app:safari"])
        m.moveItem("app:xcode", relativeTo: "app:mail", after: true)
        #expect(allIDs(m) == ["app:cafe", "app:chess", "app:mail", "app:xcode", "app:notes", "app:safari"])
        // Unknown ids or moving onto itself: no-op.
        let before = m.layout
        m.moveItem("app:xcode", relativeTo: "app:xcode", after: true)
        m.moveItem("app:nope", relativeTo: "app:mail", after: true)
        #expect(m.layout == before)
        // Only the "Все" tab is affected.
        #expect(m.items(tab: .category(AppCategory.from(raw: "public.app-category.productivity")), query: "")
            .map(\.id) == ["app:mail", "app:notes"])
    }

    @Test func newAppsFollowListedOnesAlphabetically() {
        let (m, cat) = makeModel(Self.sample.filter { $0.id != "cafe" && $0.id != "safari" })
        m.moveItem("app:xcode", relativeTo: "app:chess", after: false)
        cat.replace(Self.sample)
        #expect(allIDs(m) == ["app:xcode", "app:chess", "app:mail", "app:notes", "app:cafe", "app:safari"])
    }

    @Test func uninstalledAppKeepsItsPlace() {
        let (m, cat) = makeModel()
        m.moveItem("app:xcode", relativeTo: "app:cafe", after: false)
        cat.replace(Self.sample.filter { $0.id != "chess" })
        m.moveItem("app:mail", relativeTo: "app:xcode", after: false)
        #expect(m.layout.manualOrder?.contains("app:chess") == true)
        cat.replace(Self.sample)
        // It stays right after the item it followed (Café).
        #expect(allIDs(m) == ["app:mail", "app:xcode", "app:cafe", "app:chess", "app:notes", "app:safari"])
    }

    @Test func vanishedFolderIsDroppedWhenWriting() throws {
        let (m, _) = makeModel()
        let fid = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let folderItem = "folder:\(fid.uuidString)"
        m.moveItem(folderItem, relativeTo: "app:cafe", after: false)
        #expect(allIDs(m).first == folderItem)
        m.dissolve(folder: fid)
        #expect(!allIDs(m).contains(folderItem))
        m.moveItem("app:xcode", relativeTo: "app:cafe", after: false)
        #expect(m.layout.manualOrder?.contains(folderItem) == false)
        // Dissolved apps were unlisted: they follow alphabetically.
        #expect(allIDs(m) == ["app:xcode", "app:cafe", "app:chess", "app:safari", "app:mail", "app:notes"])
    }

    @Test func newFolderTakesTheTargetsPlace() throws {
        let (m, _) = makeModel()
        m.moveItem("app:xcode", relativeTo: "app:cafe", after: false)
        let before = allIDs(m)
        let fid = try #require(m.createFolder(dropping: "notes", onto: "chess"))
        let after = allIDs(m)
        #expect(after.firstIndex(of: "folder:\(fid.uuidString)") == before.firstIndex(of: "app:chess"))
    }

    @Test func resetManualOrder() {
        let (m, _) = makeModel()
        m.moveItem("app:xcode", relativeTo: "app:cafe", after: false)
        m.resetManualOrder()
        #expect(!m.hasManualOrder)
        #expect(m.layout.manualOrder == nil)
        #expect(allIDs(m).first == "app:cafe")
    }

    // MARK: Recent

    @Test func recentNewestFirstAndLimited() {
        let (m, _) = makeModel()
        let base = Date(timeIntervalSince1970: 1_000_000)
        m.history.lastLaunched = ["mail": base, "chess": base.addingTimeInterval(60),
                                  "xcode": base.addingTimeInterval(30), "gone": base.addingTimeInterval(90)]
        #expect(m.recentApps.map(\.id) == ["chess", "xcode", "mail"])
        #expect(m.items(tab: .recent, query: "").map(\.id) == ["app:chess", "app:xcode", "app:mail"])
        m.hide("xcode")
        #expect(m.recentApps.map(\.id) == ["chess", "mail"])

        let many = (0..<40).map { Self.app("id\($0)", "App \($0)") }
        let (m2, _) = makeModel(many)
        m2.history.lastLaunched = Dictionary(uniqueKeysWithValues: many.enumerated().map {
            ($1.id, base.addingTimeInterval(Double($0)))
        })
        #expect(m2.recentApps.count == GridModel.recentLimit)
        #expect(m2.recentApps.first?.id == "id39")
    }

    // MARK: Undo

    @Test func undoRedo() throws {
        let (m, _) = makeModel()
        #expect(!m.canUndo && !m.canRedo)
        let fid = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.pin("chess")
        #expect(m.canUndo)
        m.undo()
        #expect(m.layout.pinned.isEmpty)
        #expect(m.folder(id: fid) != nil)
        #expect(m.canRedo)
        m.undo()
        #expect(m.folder(id: fid) == nil)
        #expect(!m.canUndo)
        m.redo()
        #expect(m.folder(id: fid) != nil)
        m.redo()
        #expect(m.layout.pinned == ["chess"])
        #expect(!m.canRedo)
        // A new change clears redo.
        m.undo()
        m.hide("safari")
        #expect(!m.canRedo)
    }

    @Test func undoClosesVanishedFolderAndRenames() throws {
        let (m, _) = makeModel()
        let fid = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.openFolderID = fid
        m.renamingFolderID = fid
        m.renamingCategoryID = "custom.x"
        m.undo()
        #expect(m.openFolderID == nil)
        #expect(m.renamingFolderID == nil)
        #expect(m.renamingCategoryID == nil)
    }

    @Test func undoStackIsCapped() {
        let (m, _) = makeModel()
        for i in 0..<60 { m.pin("p\(i)") }
        #expect(m.undoStack.count == 50)
    }

    /// Writes an (empty) icon file into the model's icons folder and returns its name.
    func iconFile(_ m: GridModel) throws -> String {
        try FileManager.default.createDirectory(at: m.iconsDirectory, withIntermediateDirectories: true)
        let name = UUID().uuidString + ".png"
        try Data([1]).write(to: m.iconsDirectory.appendingPathComponent(name))
        return name
    }

    /// Undo brings back the entry's icon mapping when its files still exist (icon files are only
    /// deleted by the next launch's cleanup now).
    @Test func undoRestoresIconsWhoseFilesExist() throws {
        let (m, _) = makeModel()
        defer { try? FileManager.default.removeItem(at: m.iconsDirectory) }
        let a = try iconFile(m), b = try iconFile(m)
        var l = m.layout
        l.customIcons["mail"] = a
        m.commit(l)
        l.customIcons["mail"] = b
        m.commit(l)
        m.undo()
        #expect(m.layout.customIcons == ["mail": a])
        m.undo()
        #expect(m.layout.customIcons.isEmpty)
        m.redo()
        m.redo()
        #expect(m.layout.customIcons == ["mail": b])
    }

    /// An entry naming a file that is gone keeps the current mapping for that app only; the other
    /// apps still get the entry's mapping.
    @Test func undoFallsBackPerAppWhenAFileIsMissing() throws {
        let (m, _) = makeModel()
        defer { try? FileManager.default.removeItem(at: m.iconsDirectory) }
        let kept = try iconFile(m), current = try iconFile(m)
        var l = m.layout
        l.customIcons = ["mail": kept, "notes": "\(UUID().uuidString).png"]
        m.commit(l)
        l.customIcons = ["notes": current]
        m.commit(l)
        m.undo()
        #expect(m.layout.customIcons == ["mail": kept, "notes": current])
    }

    @Test func resetLayoutIsUndoable() throws {
        let (m, _) = makeModel()
        let fid = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.pin("chess")
        var l = m.layout
        l.customIcons["mail"] = "gone.png"
        m.commit(l)
        m.resetLayout()
        #expect(m.layout.folders.isEmpty)
        m.undo()
        #expect(m.folder(id: fid) != nil)
        #expect(m.layout.pinned == ["chess"])
        // "gone.png" does not exist, so its mapping is not resurrected.
        #expect(m.layout.customIcons.isEmpty)
    }

    // MARK: Tabs

    @Test func tabCyclingWraps() {
        let (m, _) = makeModel()
        let tabs = m.availableTabs
        #expect(tabs.count > 2)
        m.cycleTab(by: -1)
        #expect(m.tab == tabs.last)
        m.cycleTab(by: 1)
        #expect(m.tab == .all)
        m.cycleTab(by: 1)
        #expect(m.tab == tabs[1])
        m.query = "x"
        m.selectTab(at: 0)
        #expect(m.tab == .all)
        #expect(m.query.isEmpty)
        m.selectTab(at: 99)
        #expect(m.tab == .all)
        m.selectTab(at: 2)
        #expect(m.tab == tabs[2])
    }

    // MARK: Dock menu

    @Test func foldersByName() throws {
        let (m, _) = makeModel()
        let a = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        m.rename(folder: a, to: "Work")
        let b = try #require(m.createFolder(dropping: "xcode", onto: "chess"))
        m.rename(folder: b, to: "Café")
        #expect(m.visibleFolders.map(\.id) == [b, a])
        #expect(m.folder(named: "  cafe ")?.id == b)
        #expect(m.folder(named: "WORK")?.id == a)
        #expect(m.folder(named: "nope") == nil)
        #expect(m.folder(named: " ") == nil)
    }

    @Test func mostUsed() {
        let (m, _) = makeModel()
        m.usage.entries = ["mail": .init(score: 3, lastUsed: m.now()), "chess": .init(score: 5, lastUsed: m.now()),
                           "gone": .init(score: 9, lastUsed: m.now())]
        m.tab = .category(AppCategory.from(raw: "public.app-category.developer-tools"))
        m.showsFrequent = false
        #expect(m.mostUsedApps(limit: 5).map(\.id) == ["chess", "mail"])
        #expect(m.mostUsedApps(limit: 1).map(\.id) == ["chess"])
        #expect(m.mostUsedApps(limit: 0).isEmpty)
    }
}
