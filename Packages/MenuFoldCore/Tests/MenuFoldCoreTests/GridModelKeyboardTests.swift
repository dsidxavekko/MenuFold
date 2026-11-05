import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct GridModelKeyboardTests {
    static func app(_ id: String, _ name: String, path: String? = nil) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
                 infoCategory: "public.app-category.productivity")
    }

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    /// 9 apps a…i (names A…I), no store; clock frozen at t0.
    func makeModel(usageStore: UsageStore? = nil) -> (GridModel, StaticAppCatalog) {
        let apps = "abcdefghi".map { c in Self.app(String(c), String(c).uppercased()) }
        let cat = StaticAppCatalog(apps: apps)
        let m = GridModel(catalog: cat, store: nil, usageStore: usageStore,
                          homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
        let t = t0
        m.now = { t }
        return (m, cat)
    }

    /// Uses: c×3, a×2, b×1 (spaced past the dedupe interval).
    func seedUsage(_ m: GridModel) {
        var s = UsageStats()
        for (i, id) in ["c", "c", "c", "a", "a", "b"].enumerated() {
            s.record(id, at: t0 - Double(1000 - i * 20))
        }
        m.usage = s
    }

    @Test func frequentAppsRules() {
        let (m, cat) = makeModel()
        seedUsage(m)
        #expect(m.frequentApps.map(\.id) == ["c", "a", "b"])
        m.frequentLimit = 2
        #expect(m.frequentApps.map(\.id) == ["c", "a"])
        m.frequentLimit = 7
        m.hide("c")
        #expect(m.frequentApps.map(\.id) == ["a", "b"])
        cat.replace(cat.apps.filter { $0.id != "a" }) // uninstalled
        #expect(m.frequentApps.map(\.id) == ["b"])
        m.query = "B"
        #expect(m.frequentApps.isEmpty)
        m.query = ""
        m.tab = .category(.from(raw: "public.app-category.productivity"))
        #expect(m.frequentApps.isEmpty)
        m.tab = .all
        m.showsFrequent = false
        #expect(m.frequentApps.isEmpty)
    }

    @Test func recordUseIgnoresAppsOutsideTheCatalog() {
        let (m, _) = makeModel()
        m.recordUse(appID: "com.example.helper")
        #expect(m.usage.entries.isEmpty)
    }

    @Test func selectionClearsWhenALayoutChangeHidesTheTile() {
        let (m, _) = makeModel()
        m.selectedItemID = "app:a"
        _ = m.createFolder(dropping: "a", onto: "b")
        #expect(m.selectedItemID == nil)
    }

    @Test func recordUseDedupesAndSaves() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("usage.json")
        let store = UsageStore(fileURL: url)
        let (m, _) = makeModel(usageStore: store)
        m.recordUse(appID: "d")
        m.recordUse(appID: "d") // same instant → ignored
        #expect(m.usage.score(of: "d", at: t0) == 1)
        #expect(store.load() == m.usage)
        #expect(m.frequentApps.map(\.id) == ["d"])
        // A new model reads the saved stats.
        let (m2, _) = makeModel(usageStore: store)
        #expect(m2.usage == m.usage)
        m.clearUsage()
        #expect(m.usage.entries.isEmpty)
        #expect(store.load() == UsageStats())
    }

    @Test func selectionResets() throws {
        let (m, _) = makeModel()
        m.selectedItemID = "app:a"
        m.query = "x"
        #expect(m.selectedItemID == nil)
        m.selectedItemID = "app:a"
        m.query = "x" // unchanged → kept
        #expect(m.selectedItemID == "app:a")
        m.query = ""
        m.selectedItemID = "app:a"
        m.tab = .category(.from(raw: "public.app-category.productivity"))
        #expect(m.selectedItemID == nil)
        m.tab = .all
        let f = try #require(m.createFolder(dropping: "b", onto: "a"))
        m.selectedItemID = "app:c"
        m.openFolderID = f
        #expect(m.selectedItemID == nil)
        m.selectedItemID = "app:a"
        m.pendingTrashAppID = "a"
        m.panelDidOpen()
        #expect(m.selectedItemID == nil)
        #expect(m.pendingTrashAppID == nil)
    }

    @Test func selectionClearedWhenItemVanishes() {
        let (m, cat) = makeModel()
        m.selectedItemID = "app:d"
        m.hide("d")
        #expect(m.selectedItemID == nil)
        m.selectedItemID = "app:e"
        cat.replace(cat.apps.filter { $0.id != "e" })
        #expect(m.selectedItemID == nil)
        m.selectedItemID = "app:f"
        cat.replace(cat.apps)
        #expect(m.selectedItemID == "app:f")
    }

    @Test func moveSelectionAcrossFrequentRowAndGrid() {
        let (m, _) = makeModel()
        seedUsage(m) // frequent row: c a b
        #expect(m.navigableSections[0] == ["frequent:c", "frequent:a", "frequent:b"])
        #expect(m.navigableSections[1] == "abcdefghi".map { "app:\($0)" })
        m.moveSelection(.right, columns: 7)
        #expect(m.selectedItemID == "frequent:c")
        m.moveSelection(.right, columns: 7)
        m.moveSelection(.right, columns: 7)
        #expect(m.selectedItemID == "frequent:b")
        m.moveSelection(.right, columns: 7) // crosses into the grid
        #expect(m.selectedItemID == "app:a")
        m.moveSelection(.down, columns: 7)
        #expect(m.selectedItemID == "app:h")
        m.moveSelection(.up, columns: 7)
        m.moveSelection(.up, columns: 7) // back to the frequent row, column 0
        #expect(m.selectedItemID == "frequent:c")
        m.selectedItemID = "app:g" // column 6 → clamped to the last frequent tile
        m.moveSelection(.up, columns: 7)
        #expect(m.selectedItemID == "frequent:b")
        m.moveSelection(.down, columns: 7)
        #expect(m.selectedItemID == "app:c")
    }

    @Test func moveSelectionInsideFolder() throws {
        let (m, _) = makeModel()
        seedUsage(m)
        let f = try #require(m.createFolder(dropping: "b", onto: "a"))
        m.add("c", to: f)
        m.openFolderID = f
        #expect(m.navigableSections == [["app:a", "app:b", "app:c"]])
        m.moveSelection(.left, columns: 6)
        #expect(m.selectedItemID == "app:a")
        m.moveSelection(.right, columns: 6)
        #expect(m.selectedItemID == "app:b")
        #expect(m.selectedApp?.id == "b")
    }

    @Test func selectedAppAndActivation() throws {
        let (m, _) = makeModel()
        #expect(m.selectedApp == nil)
        #expect(!m.activateSelection())
        m.selectedItemID = "frequent:c"
        #expect(m.selectedApp?.id == "c")
        m.selectedItemID = "app:d"
        #expect(m.selectedApp?.id == "d")
        m.selectedItemID = "app:missing"
        #expect(m.selectedApp == nil)
        let f = try #require(m.createFolder(dropping: "b", onto: "a"))
        m.selectedItemID = "folder:\(f.uuidString)"
        #expect(m.selectedApp == nil)
        #expect(m.activateSelection())
        #expect(m.openFolderID == f)
    }

    @Test func canTrash() {
        let (m, _) = makeModel()
        #expect(!m.canTrash(Self.app("x", "Calculator", path: "/System/Applications/Calculator.app")))
        #expect(m.canTrash(Self.app("y", "Foo")))
    }

    @Test func trashErrorsDescribe() {
        #expect(TrashError.systemApp.errorDescription == "Системну програму не можна перемістити в Кошик.")
        #expect(TrashError.running.errorDescription == "Спершу завершіть програму.")
        #expect(TrashError.failed("boom").errorDescription == "boom")
    }

    @Test func moveToTrashRefusesSystemApp() async {
        let (m, _) = makeModel()
        await #expect(throws: TrashError.systemApp) {
            try await m.moveToTrash(Self.app("x", "Calculator", path: "/System/Applications/Calculator.app"))
        }
    }
}
