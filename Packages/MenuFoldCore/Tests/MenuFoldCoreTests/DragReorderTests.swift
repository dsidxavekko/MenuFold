import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct DragReorderTests {
    func makeModel() -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: ArrangeTests.sample), store: nil)
    }

    @Test func movePinnedBeforeAndAfter() {
        let m = makeModel()
        ["mail", "notes", "chess", "safari"].forEach(m.pin)
        m.movePinned("safari", before: "mail")
        #expect(m.layout.pinned == ["safari", "mail", "notes", "chess"])
        m.movePinned("safari", after: "notes")
        #expect(m.layout.pinned == ["mail", "notes", "safari", "chess"])
        m.movePinned("mail", after: "mail") // onto itself: nothing
        #expect(m.layout.pinned == ["mail", "notes", "safari", "chess"])
    }

    @Test func movePinnedPinsUnpinnedApp() {
        let m = makeModel()
        ["mail", "notes"].forEach(m.pin)
        m.movePinned("xcode", before: "notes")
        #expect(m.layout.pinned == ["mail", "xcode", "notes"])
        m.movePinned("cafe", before: "chess") // target not pinned: ignored
        #expect(m.layout.pinned == ["mail", "xcode", "notes"])
    }

    @Test func movePinnedKeepsInvisibleSlots() {
        let m = makeModel()
        ["mail", "ghost", "notes", "chess"].forEach(m.pin)
        m.movePinned("chess", before: "mail")
        #expect(m.layout.pinned == ["chess", "ghost", "mail", "notes"])
    }

    @Test func folderTakesPartInManualOrder() throws {
        let m = makeModel()
        let fid = try #require(m.createFolder(dropping: "notes", onto: "mail"))
        let folderItem = "folder:\(fid.uuidString)"
        m.moveItem(folderItem, relativeTo: "app:xcode", after: true)
        let ids = m.items(tab: .all, query: "").map(\.id)
        let f = try #require(ids.firstIndex(of: folderItem))
        let x = try #require(ids.firstIndex(of: "app:xcode"))
        #expect(f == x + 1)
        // An app moved next to the folder keeps the folder where it is.
        m.moveItem("app:safari", relativeTo: folderItem, after: false)
        let after = m.items(tab: .all, query: "").map(\.id)
        let fi = try #require(after.firstIndex(of: folderItem))
        #expect(after[fi - 1] == "app:safari")
    }
}
