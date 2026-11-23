import Foundation
import Testing
@testable import MenuFoldCore

/// A file a fake provider reports: the path is everything the model reads (id, name, parent), and no
/// test touches the disk, so the rows never depend on what the machine happens to contain.
private func fileItem(_ path: String) -> FileItem {
    let url = URL(fileURLWithPath: path)
    return FileItem(url: url, name: url.lastPathComponent)
}

/// Stands in for `SpotlightFileSearchProvider`: answers per query text, records every ask, and hands
/// back everything it was given (a provider that ignores `limit`, so the model's own cap is tested).
private actor FakeFileSearch: FileSearching {
    private(set) var asked: [String] = []
    private var answers: [String: [FileItem]]

    init(_ answers: [String: [FileItem]] = [:]) {
        self.answers = answers
    }

    func searchFiles(matching term: String, limit: Int) async -> [FileItem] {
        asked.append(term)
        return answers[term] ?? []
    }
}

@MainActor
@Suite struct FileSearchModelTests {
    static func app(_ id: String, _ name: String) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"),
                 infoCategory: "public.app-category.productivity")
    }

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    /// Two apps, the files switch on, a fake provider and no debounce, so a query's search can be
    /// awaited instead of waited for.
    func makeModel(provider: FileSearching? = nil) -> GridModel {
        let apps = [Self.app("com.example.notes", "Notes"), Self.app("com.example.zvit", "Звіт")]
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil,
                              homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
        let now = t0
        model.now = { now }
        model.searchesFiles = true
        model.fileSearchProvider = provider
        model.fileSearchDelay = .zero
        return model
    }

    /// Waits for the search the last query started (nil when it started none).
    func finishSearch(_ model: GridModel) async {
        await model.fileSearchTask?.value
    }

    @Test func filesPrefixHidesAppsAndPanes() async {
        let provider = FakeFileSearch(["звіт": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.query = "~звіт"
        await finishSearch(model)
        // The prefix means files instead of the grid, not files in addition to it.
        #expect(model.visibleItems.isEmpty)
        #expect(model.settingsPaneResults.isEmpty)
        #expect(model.matchingTabs.isEmpty)
        #expect(model.calculatorResult == nil)
        #expect(model.fileResults.map(\.name) == ["Звіт.pdf"])
        let asked = await provider.asked
        #expect(asked == ["звіт"])
    }

    @Test func readablePrefixMeansTheSame() async {
        let provider = FakeFileSearch(["договір": [fileItem("/Users/tester/Documents/договір.docx")]])
        let model = makeModel(provider: provider)
        model.query = "file:договір"
        await finishSearch(model)
        #expect(model.visibleItems.isEmpty)
        #expect(model.fileResults.map(\.name) == ["договір.docx"])
    }

    @Test func plainQueryNeedsThreeCharactersAndTheSwitch() async {
        let provider = FakeFileSearch(["зві": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.query = "зв"
        await finishSearch(model)
        var asked = await provider.asked
        #expect(asked.isEmpty)
        #expect(model.fileResults.isEmpty)

        // A plain query long enough to ask: the files join the app results.
        model.query = "зві"
        await finishSearch(model)
        asked = await provider.asked
        #expect(asked == ["зві"])
        #expect(model.fileResults.count == 1)
        #expect(model.visibleItems.isEmpty || model.fileResults.count == 1)

        // Off: the rows go at once and nothing is asked any more, prefix included.
        model.searchesFiles = false
        #expect(model.fileResults.isEmpty)
        model.query = "~звіт"
        await finishSearch(model)
        asked = await provider.asked
        #expect(asked == ["зві"])
        #expect(model.fileResults.isEmpty)
    }

    @Test func barePrefixAsksNothing() async {
        let provider = FakeFileSearch(["": [fileItem("/Users/tester/Documents/a.txt")]])
        let model = makeModel(provider: provider)
        model.query = "~"
        await finishSearch(model)
        let asked = await provider.asked
        #expect(asked.isEmpty)
        #expect(model.fileResults.isEmpty)
        model.query = "file:"
        await finishSearch(model)
        #expect(model.fileResults.isEmpty)
    }

    @Test func atMostEightRows() async {
        let many = (0..<12).map { fileItem("/Users/tester/Documents/звіт-\($0).pdf") }
        let provider = FakeFileSearch(["звіт": many])
        let model = makeModel(provider: provider)
        model.query = "~звіт"
        await finishSearch(model)
        // The fake ignores the limit it is given; the model caps the section itself.
        #expect(FileSearch.defaultLimit == 8)
        #expect(model.fileResults.count == FileSearch.defaultLimit)
    }

    @Test func staleAnswerDoesNotWin() async {
        let provider = FakeFileSearch([
            "aaa": [fileItem("/Users/tester/Documents/aaa.txt")],
            "bbb": [fileItem("/Users/tester/Documents/bbb.txt")],
        ])
        let model = makeModel(provider: provider)
        model.query = "~aaa"
        await finishSearch(model)
        let oldGeneration = model.fileSearchGeneration
        #expect(model.fileResults.map(\.name) == ["aaa.txt"])

        model.query = "~bbb"
        await finishSearch(model)
        #expect(model.fileResults.map(\.name) == ["bbb.txt"])

        // The answer for the old text lands late: it must not replace the newer rows.
        model.applyFileResults([fileItem("/Users/tester/Documents/aaa.txt")], for: "aaa",
                               generation: oldGeneration)
        #expect(model.fileResults.map(\.name) == ["bbb.txt"])
    }

    @Test func repeatedSearchKeepsItsRows() async {
        let provider = FakeFileSearch(["звіт": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.query = "~звіт"
        await finishSearch(model)
        #expect(model.fileResults.count == 1)
        // A re-plan for the same text (the provider was attached again) keeps the rows on screen
        // while the new query runs, so the section never blinks between two identical searches.
        model.fileSearchProvider = provider
        #expect(model.fileResults.count == 1)
        await finishSearch(model)
        #expect(model.fileResults.count == 1)
    }

    @Test func otherRowsClearOnANewText() async {
        let provider = FakeFileSearch(["звіт": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.query = "~звіт"
        await finishSearch(model)
        #expect(model.fileResults.count == 1)
        model.query = "~зві"
        // New text: the old rows are gone immediately, not after the answer arrives.
        #expect(model.fileResults.isEmpty)
        await finishSearch(model)
    }

    @Test func clipboardTabSearchesNoFiles() async {
        let provider = FakeFileSearch(["звіт": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.showsClipboardTab = true
        model.tab = .clipboard
        model.query = "звіт"
        await finishSearch(model)
        model.query = "~звіт"
        await finishSearch(model)
        let asked = await provider.asked
        #expect(asked.isEmpty)
        #expect(model.fileResults.isEmpty)
    }

    @Test func filesComeAfterThePanes() async {
        let provider = FakeFileSearch(["звіт": [fileItem("/Users/tester/Documents/Звіт.pdf")]])
        let model = makeModel(provider: provider)
        model.query = "~звіт"
        await finishSearch(model)
        let sections = model.navigableSections
        #expect(sections.last == ["file:/Users/tester/Documents/Звіт.pdf"])
        // The pane section sits right above it, empty for a files-only query.
        #expect(sections[sections.count - 2] == [])
    }

    @Test func selectionOpensTheFile() async throws {
        // A path that does not exist: opening it is a no-op for the system, and the test only needs
        // the model's own bookkeeping (a real file would let the machine open an app instead).
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("menufold-file-\(UUID().uuidString).txt").path
        let item = FileItem(url: URL(fileURLWithPath: path), name: "звіт.txt")
        let provider = FakeFileSearch(["звіт": [item]])
        let model = makeModel(provider: provider)
        var launches = 0
        model.onLaunched = { launches += 1 }
        model.query = "~звіт"
        await finishSearch(model)
        let result = try #require(model.fileResults.first)
        #expect(result.id == path)
        #expect(GridModel.fileSelectionID(result.id) == GridModel.fileSelectionID(path))

        model.selectedItemID = GridModel.fileSelectionID(result.id)
        #expect(model.selectedFile?.url == result.url)
        #expect(model.activateSelection())
        // The panel closes after opening a file, unless the user keeps it open.
        #expect(launches == 1)

        model.keepsPanelOpenAfterLaunch = true
        #expect(model.activateSelection())
        #expect(launches == 1)

        // A stale selection id (the file is gone from the rows) activates nothing.
        model.selectedItemID = GridModel.fileSelectionID("/Users/tester/Documents/gone.txt")
        #expect(model.selectedFile == nil)
        #expect(!model.activateSelection())
    }
}
