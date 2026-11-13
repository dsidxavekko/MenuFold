import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct CustomCategoryTests {
    let sample: [AppEntry] = [
        GridModelTests.app("mail", "Mail", "productivity"),
        GridModelTests.app("notes", "Notes", "productivity"),
        GridModelTests.app("xcode", "Xcode", "developer-tools"),
        GridModelTests.app("safari", "Safari"),
    ]

    func makeModel(store: LayoutStore? = nil) -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: sample), store: store)
    }

    func ids(_ items: [GridItem]) -> [String] { items.map(\.id) }

    @Test func createAssignsAppAndShowsTabFirst() {
        let m = makeModel()
        let work = m.createCategory(named: "  Робота ", assigning: "mail")
        #expect(work.isCustom)
        #expect(work.displayName == "Робота")
        #expect(m.category(of: sample[0]) == work)
        #expect(ids(m.items(tab: .category(work), query: "")) == ["app:mail"])
        // Custom tabs come right after "Все", before system categories; "Інше" stays last.
        #expect(m.availableTabs.first == .all)
        #expect(m.availableTabs[1] == .category(work))
        #expect(m.availableTabs.last == .category(.other))
    }

    @Test func batchSetCategoryIsOneUndoStep() {
        let m = makeModel()
        let work = m.createCategory(named: "Робота")
        let steps = m.undoStack.count
        m.setCategory(work, for: ["mail", "notes", "xcode"])
        #expect(ids(m.items(tab: .category(work), query: "")) == ["app:mail", "app:notes", "app:xcode"])
        #expect(m.undoStack.count == steps + 1)
        m.setCategory(nil, for: ["mail", "notes"])
        #expect(ids(m.items(tab: .category(work), query: "")) == ["app:xcode"])
        m.undo()
        #expect(ids(m.items(tab: .category(work), query: "")).count == 3)
        // A deleted custom category is refused.
        m.deleteCategory(id: work.id)
        let before = m.layout
        m.setCategory(work, for: ["safari"])
        #expect(m.layout == before)
    }

    @Test func emptyCustomCategoryStillHasATab() {
        let m = makeModel()
        let empty = m.createCategory(named: "Порожня")
        #expect(m.availableTabs.contains(.category(empty)))
        #expect(m.items(tab: .category(empty), query: "").isEmpty)
    }

    @Test func defaultAndDuplicateNamesAreNumbered() {
        let m = makeModel()
        #expect(m.createCategory().displayName == "Нова категорія")
        #expect(m.createCategory().displayName == "Нова категорія 2")
        #expect(m.createCategory(named: "нова категорія").displayName == "нова категорія 3")
    }

    @Test func renameKeepsSelectedTab() {
        let m = makeModel()
        let c = m.createCategory(named: "Old", assigning: "xcode")
        m.tab = .category(c)
        m.selectedItemID = "app:xcode"
        m.renameCategory(id: c.id, to: "  New ")
        #expect(m.selectedItemID == "app:xcode")
        #expect(m.tab == .category(AppCategory(id: c.id, displayName: "New")))
        #expect(m.category(of: sample[2]).displayName == "New")
        m.renameCategory(id: c.id, to: "   ")
        #expect(m.layout.customCategories.first?.name == "New")
        // System categories can't be renamed.
        m.renameCategory(id: "public.app-category.productivity", to: "X")
        #expect(m.category(of: sample[0]).displayName == "Продуктивність")
    }

    @Test func deleteReturnsAppsToAutomaticCategory() {
        let m = makeModel()
        let c = m.createCategory(named: "Tmp", assigning: "mail")
        m.setCategory(.other, for: "notes")
        m.tab = .category(c)
        m.deleteCategory(id: c.id)
        #expect(m.layout.customCategories.isEmpty)
        #expect(m.layout.categoryOverrides == ["notes": AppCategory.otherID])
        #expect(m.category(of: sample[0]).id == "public.app-category.productivity")
        #expect(m.tab == .all)
    }

    @Test func setCategoryRejectsDeletedCustomCategory() {
        let m = makeModel()
        let c = m.createCategory(named: "Tmp")
        m.deleteCategory(id: c.id)
        m.setCategory(c, for: "mail")
        #expect(m.layout.categoryOverrides.isEmpty)
    }

    @Test func persistsAndDropsInvalidEntriesOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let m = makeModel(store: store)
        let c = m.createCategory(named: "Робота", assigning: "mail")
        #expect(makeModel(store: store).category(of: sample[0]) == c)

        var l = m.layout
        l.customCategories += [
            CustomCategory(id: c.id, name: "Duplicate"),
            CustomCategory(id: "games", name: "No prefix"),
            CustomCategory(name: "   "),
        ]
        l.categoryOverrides["notes"] = AppCategory.customPrefix + "gone"
        try store.save(l)
        let reloaded = makeModel(store: store)
        #expect(reloaded.layout.customCategories == [CustomCategory(id: c.id, name: "Робота")])
        #expect(reloaded.layout.categoryOverrides == ["mail": c.id])
    }

    @Test func oldFileWithoutKeyLoads() throws {
        let data = Data(#"{"version":1,"folders":[],"categoryOverrides":{"mail":"other"}}"#.utf8)
        let layout = try JSONDecoder().decode(Layout.self, from: data)
        #expect(layout.customCategories.isEmpty)
        #expect(layout.categoryOverrides == ["mail": "other"])
    }
}

@MainActor
@Suite struct CategoryOrderTests {
    let sample: [AppEntry] = [
        GridModelTests.app("mail", "Mail", "productivity"),
        GridModelTests.app("xcode", "Xcode", "developer-tools"),
        GridModelTests.app("music", "Music", "music"),
        GridModelTests.app("safari", "Safari"),
    ]

    func makeModel(store: LayoutStore? = nil) -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: sample), store: store)
    }

    func names(_ m: GridModel) -> [String] {
        m.availableTabs.map { tab in
            if case .category(let c) = tab { return c.displayName } else { return "Все" }
        }
    }

    @Test func defaultOrder() {
        let m = makeModel()
        m.createCategory(named: "Робота")
        #expect(names(m) == ["Все", "Робота", "Музика", "Продуктивність", "Розробка", "Інше"])
        #expect(!m.hasCustomCategoryOrder)
    }

    @Test func setOrderPutsUnlistedAfterInDefaultOrder() {
        let m = makeModel()
        m.setCategoryOrder(["public.app-category.developer-tools", "other", "bogus", "other"])
        #expect(names(m) == ["Все", "Розробка", "Інше", "Музика", "Продуктивність"])
        #expect(m.layout.categoryOrder == ["public.app-category.developer-tools", "other"])
        // A new category the user never placed comes after the placed ones.
        m.createCategory(named: "Робота")
        #expect(names(m) == ["Все", "Розробка", "Інше", "Робота", "Музика", "Продуктивність"])
    }

    @Test func moveByOneAndBounds() {
        let m = makeModel()
        m.moveCategory(id: "other", by: -1)
        #expect(names(m) == ["Все", "Музика", "Продуктивність", "Інше", "Розробка"])
        // The first category can't move before "Все", the last can't move further right.
        m.moveCategory(id: "public.app-category.music", by: -1)
        m.moveCategory(id: "public.app-category.developer-tools", by: 1)
        #expect(names(m) == ["Все", "Музика", "Продуктивність", "Інше", "Розробка"])
        m.resetCategoryOrder()
        #expect(names(m) == ["Все", "Музика", "Продуктивність", "Розробка", "Інше"])
    }

    @Test func categoryWithoutAppsKeepsItsPlace() {
        let m = makeModel()
        m.setCategoryOrder(["public.app-category.music", "other", "public.app-category.productivity", "public.app-category.developer-tools"])
        m.hide("music")
        #expect(names(m) == ["Все", "Інше", "Продуктивність", "Розробка"])
        m.moveCategory(id: "public.app-category.developer-tools", by: -1)
        m.unhide("music")
        #expect(names(m) == ["Все", "Інше", "Розробка", "Продуктивність", "Музика"])
    }

    @Test func deletedCategoryLeavesOrderAndInvalidEntriesDropOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let m = makeModel(store: store)
        let c = m.createCategory(named: "Tmp")
        m.moveCategory(id: "other", by: -10)  // out of range: no-op
        m.setCategoryOrder(["other", c.id])
        m.deleteCategory(id: c.id)
        #expect(m.layout.categoryOrder == ["other"])

        var l = m.layout
        l.categoryOrder = ["", "other", "other", AppCategory.customPrefix + "gone", "public.app-category.music"]
        try store.save(l)
        #expect(makeModel(store: store).layout.categoryOrder == ["other", "public.app-category.music"])
    }
}
