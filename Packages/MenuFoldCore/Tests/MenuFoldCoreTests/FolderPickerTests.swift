import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct FolderPickerTests {
    func makeModel() -> GridModel {
        let apps = "abcd".map { c in
            AppEntry(id: String(c), name: "App \(String(c).uppercased())",
                     url: URL(fileURLWithPath: "/Applications/\(String(c).uppercased()).app"), infoCategory: nil)
        }
        return GridModel(catalog: StaticAppCatalog(apps: apps), store: nil,
                         homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
    }

    @Test func createsFolderLikeDrop() {
        let m = makeModel()
        #expect(m.beginFolderPicker(for: "a"))
        #expect(m.folderPickerSourceID == "a")
        let id = m.completeFolderPicker(with: "c")
        #expect(id != nil)
        #expect(m.folderPickerSourceID == nil)
        #expect(m.layout.folders.first?.appIDs == ["a", "c"])
    }

    @Test func refusedOutsideAllTab() {
        let m = makeModel()
        m.query = "app"
        #expect(!m.beginFolderPicker(for: "a"))
        m.query = ""
        #expect(!m.beginFolderPicker(for: "zzz"))
        #expect(m.folderPickerSourceID == nil)
    }

    @Test func candidatesExcludeSourceAndFilter() {
        let m = makeModel()
        #expect(m.folderPickerCandidates().isEmpty)
        m.beginFolderPicker(for: "a")
        #expect(m.folderPickerCandidates().map(\.id) == ["b", "c", "d"])
        #expect(m.folderPickerCandidates(search: "app c").map(\.id) == ["c"])
        #expect(m.folderPickerCandidates(search: "app a").isEmpty)
        m.cancelFolderPicker()
        #expect(m.folderPickerSourceID == nil)
    }
}
