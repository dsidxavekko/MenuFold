import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct UndoPersistenceTests {
    static let sample = [
        AppEntry(id: "a", name: "A", url: URL(fileURLWithPath: "/Applications/A.app")),
        AppEntry(id: "b", name: "B", url: URL(fileURLWithPath: "/Applications/B.app")),
    ]

    func tempStore(shared: Bool = false) -> LayoutStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MFUndo-\(UUID().uuidString)", isDirectory: true)
        let s = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        s.isShared = shared
        return s
    }

    func model(_ store: LayoutStore) -> GridModel {
        GridModel(catalog: StaticAppCatalog(apps: Self.sample), store: store)
    }

    @Test func undoSurvivesRelaunch() throws {
        let store = tempStore()
        let m = model(store)
        let id = try #require(m.createFolder(dropping: "a", onto: "b"))
        m.rename(folder: id, to: "Робота")
        #expect(FileManager.default.fileExists(atPath: store.fileURL.deletingLastPathComponent().appendingPathComponent("undo.json").path))

        let m2 = model(store)
        #expect(m2.canUndo)
        m2.undo()
        #expect(m2.folder(id: id)?.name == "Нова папка")
        m2.undo()
        #expect(m2.layout.folders.isEmpty)
    }

    @Test func keepsOnlyTenSteps() throws {
        let store = tempStore()
        let m = model(store)
        let id = try #require(m.createFolder(dropping: "a", onto: "b"))
        for i in 0..<15 { m.rename(folder: id, to: "N\(i)") }
        let m2 = model(store)
        #expect(m2.undoStack.count == UndoPersistence.limit)
    }

    @Test func staleHistoryIsIgnored() throws {
        let store = tempStore()
        let m = model(store)
        _ = m.createFolder(dropping: "a", onto: "b")
        // layout.json changes behind the history's back.
        var other = store.load()
        other.folders.removeAll()
        try store.save(other)
        #expect(!model(store).canUndo)
    }

    @Test func sharedFolderNeverPersists() throws {
        let store = tempStore(shared: true)
        let m = model(store)
        _ = m.createFolder(dropping: "a", onto: "b")
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.deletingLastPathComponent().appendingPathComponent("undo.json").path))
        #expect(!model(store).canUndo)
    }

    @Test func emojiFolderSymbol() throws {
        let m = model(tempStore())
        let id = try #require(m.createFolder(dropping: "a", onto: "b"))
        #expect(m.setFolderEmoji(folder: id, to: "🔥"))
        #expect(m.folder(id: id)?.symbol == "emoji:🔥")
        #expect(!m.setFolderEmoji(folder: id, to: "ab"))
        #expect(m.folder(id: id)?.symbol == "emoji:🔥")
    }
}
