import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct KeyActionsTests {
    func makeModel() -> GridModel {
        let apps = "abcdefghi".map { c in
            AppEntry(id: String(c), name: String(c).uppercased(),
                     url: URL(fileURLWithPath: "/Applications/\(String(c).uppercased()).app"), infoCategory: nil)
        }
        return GridModel(catalog: StaticAppCatalog(apps: apps), store: nil,
                         homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
    }

    @Test func togglePin() {
        let m = makeModel()
        m.selectedItemID = "app:b"
        #expect(m.togglePinOnSelection())
        #expect(m.isPinned("b"))
        #expect(m.togglePinOnSelection())
        #expect(!m.isPinned("b"))
        m.selectedItemID = nil
        #expect(!m.togglePinOnSelection())
    }

    @Test func moveTileInMainGrid() {
        let m = makeModel()
        m.selectedItemID = "app:a"
        #expect(m.moveSelectedTile(.right, columns: 7))
        #expect(m.visibleItems.map(\.id).prefix(3) == ["app:b", "app:a", "app:c"])
        #expect(m.selectedItemID == "app:a")
        #expect(m.moveSelectedTile(.down, columns: 7))
        #expect(m.visibleItems.map(\.id).last == "app:a")
        #expect(!m.moveSelectedTile(.down, columns: 7))
        #expect(m.moveSelectedTile(.left, columns: 7))
    }

    @Test func moveRefusedOutsideMainGrid() {
        let m = makeModel()
        m.selectedItemID = "app:a"
        m.query = "a"
        m.selectedItemID = "app:a"
        #expect(!m.moveSelectedTile(.right, columns: 7))
        m.query = ""
        m.selectedItemID = "app:a"
        #expect(!m.moveSelectedTile(.left, columns: 7))
    }

    @Test func movePinnedRow() {
        let m = makeModel()
        m.pin("a"); m.pin("b")
        m.selectedItemID = "pinned:a"
        #expect(m.moveSelectedTile(.right, columns: 7))
        #expect(m.layout.pinned == ["b", "a"])
        #expect(!m.moveSelectedTile(.right, columns: 7))
        #expect(!m.moveSelectedTile(.down, columns: 7))
    }

    @Test func infoCard() {
        let m = makeModel()
        m.selectedItemID = "app:c"
        #expect(m.showInfoForSelection())
        #expect(m.infoAppID == "c")
        m.panelDidOpen()
        #expect(m.infoAppID == nil)
    }

    @Test func readsBundleInfoAndSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("AppInfo-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/_MASReceipt"),
                                                withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleShortVersionString": "1.2", "CFBundleVersion": "34"]
        plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        try Data(count: 5000).write(to: app.appendingPathComponent("Contents/blob"))
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = AppEntry(id: "x.foo", name: "Foo", url: app, infoCategory: nil)
        let info = AppInfo.read(app: entry, firstSeen: .distantPast, lastLaunched: Date(timeIntervalSince1970: 5),
                                launchCount: 3)
        #expect(info.version == "1.2")
        #expect(info.build == "34")
        #expect(info.source == .appStore)
        #expect((info.sizeBytes ?? 0) >= 5000)
        #expect(info.firstSeen == nil)
        #expect(info.launchCount == 3)
        #expect(info.installedDate != nil)
        let system = AppEntry(id: "s", name: "S", url: URL(fileURLWithPath: "/System/Applications/Foo.app"), infoCategory: nil)
        #expect(AppInfo.detectSource(of: system) == .system)
    }

    @Test func launchCountPersistsInHistory() throws {
        var h = AppHistory(launchCounts: ["a": 2])
        let data = try JSONEncoder().encode(h)
        h = try JSONDecoder().decode(AppHistory.self, from: data)
        #expect(h.launchCounts["a"] == 2)
        let old = try JSONDecoder().decode(AppHistory.self, from: Data("{}".utf8))
        #expect(old.launchCounts.isEmpty)
    }
}
