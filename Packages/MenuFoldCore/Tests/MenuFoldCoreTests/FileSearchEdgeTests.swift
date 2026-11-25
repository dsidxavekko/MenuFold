import Foundation
import Testing
@testable import MenuFoldCore

private func file(_ path: String, modified: Date? = nil) -> FileItem {
    let url = URL(fileURLWithPath: path)
    return FileItem(url: url, name: url.lastPathComponent, modified: modified)
}

/// Provider whose answer per term is released by the test, so a slow answer can land after a newer query.
private actor GatedProvider: FileSearching {
    private(set) var asked: [(term: String, limit: Int)] = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var answers: [String: [FileItem]]
    private var held: Set<String>

    init(answers: [String: [FileItem]], hold: Set<String> = []) {
        self.answers = answers
        self.held = hold
    }

    func searchFiles(matching term: String, limit: Int) async -> [FileItem] {
        asked.append((term, limit))
        if held.contains(term) {
            await withCheckedContinuation { gates[term] = $0 }
        }
        return answers[term] ?? []
    }

    func release(_ term: String) {
        held.remove(term)
        gates.removeValue(forKey: term)?.resume()
    }

    var terms: [String] { asked.map(\.term) }
    var limits: [Int] { asked.map(\.limit) }
}

@MainActor
@Suite struct FileSearchEdgeTests {
    func makeModel(_ provider: FileSearching?, delay: Duration = .zero) -> GridModel {
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: nil,
                              homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
        model.searchesFiles = true
        model.fileSearchProvider = provider
        model.fileSearchDelay = delay
        return model
    }

    @Test func emptyAnswerGivesNoRowsAndStopsSpinner() async {
        let model = makeModel(GatedProvider(answers: [:]))
        model.query = "~nothing"
        #expect(model.isSearchingFiles)
        await model.fileSearchTask?.value
        #expect(model.fileResults.isEmpty)
        #expect(!model.isSearchingFiles)
    }

    @Test func slowProviderTimingOutWithNothingIsHarmless() async {
        // A provider that timed out answers [] late; rows stay empty, the model stays usable.
        struct Slow: FileSearching {
            func searchFiles(matching term: String, limit: Int) async -> [FileItem] {
                try? await Task.sleep(for: .milliseconds(30))
                return []
            }
        }
        let model = makeModel(Slow())
        model.query = "~report"
        await model.fileSearchTask?.value
        #expect(model.fileResults.isEmpty)
        #expect(!model.isSearchingFiles)
    }

    @Test func lateAnswerOfOlderQueryIsDropped() async {
        let provider = GatedProvider(answers: [
            "aaa": [file("/Users/t/Documents/aaa.txt")],
            "bbb": [file("/Users/t/Documents/bbb.txt")],
        ], hold: ["aaa"])
        let model = makeModel(provider)
        model.query = "~aaa"
        let first = model.fileSearchTask
        await Task.yield(); await Task.yield()
        model.query = "~bbb"
        await model.fileSearchTask?.value
        #expect(model.fileResults.map(\.name) == ["bbb.txt"])
        await provider.release("aaa")
        await first?.value
        #expect(model.fileResults.map(\.name) == ["bbb.txt"])
        #expect(!model.isSearchingFiles)
    }

    @Test func fastTypingCostsOneQuery() async {
        let provider = GatedProvider(answers: ["report": [file("/Users/t/Documents/report.pdf")]])
        let model = makeModel(provider, delay: .milliseconds(80))
        for q in ["~r", "~re", "~rep", "~repo", "~repor", "~report"] { model.query = q }
        await model.fileSearchTask?.value
        #expect(await provider.terms == ["report"])
        #expect(model.fileResults.count == 1)
    }

    @Test func switchOffAsksNothingEvenWithPrefix() async {
        let provider = GatedProvider(answers: ["report": [file("/Users/t/Documents/report.pdf")]])
        let model = makeModel(provider)
        model.searchesFiles = false
        for q in ["~report", "file:report", "report"] {
            model.query = q
            await model.fileSearchTask?.value
        }
        #expect(await provider.terms.isEmpty)
        #expect(model.fileResults.isEmpty)
    }

    @Test func providerIgnoringLimitAndFilterIsClamped() async {
        var items = (0..<40).map { file("/Users/t/Documents/doc-\($0).txt") }
        items.append(file("/Users/t/.hidden/doc-x.txt"))
        items.append(file("/Users/t/Library/doc-y.txt"))
        let model = makeModel(GatedProvider(answers: ["doc": items]))
        model.query = "file:doc"
        await model.fileSearchTask?.value
        #expect(model.fileResults.count == FileSearch.defaultLimit)
        #expect(model.fileResults.allSatisfy { !$0.url.path.contains("/Library/") && !$0.url.path.contains("/.hidden/") })
    }

    @Test func kindFilterAppliesToAnswer() async {
        let provider = GatedProvider(answers: [
            "report": [file("/Users/t/Documents/report.pdf"), file("/Users/t/Documents/report.docx"),
                       file("/Users/t/Documents/report.PDF")],
        ])
        let model = makeModel(provider)
        model.query = "~kind:pdf report"
        await model.fileSearchTask?.value
        #expect(await provider.terms == ["report"])
        #expect(await provider.limits == [FileSearch.maxLimit])
        #expect(Set(model.fileResults.map(\.name)) == ["report.pdf", "report.PDF"])
    }

    @Test func kindOnlyAsksNothing() async {
        let provider = GatedProvider(answers: [:])
        let model = makeModel(provider)
        model.query = "~kind:pdf"
        await model.fileSearchTask?.value
        #expect(await provider.terms.isEmpty)
    }
}

@Suite struct FileSearchEdgeRankTests {
    @Test func limitIsClamped() {
        let items = (0..<50).map { file("/Users/t/Documents/a-\($0).txt") }
        #expect(FileSearch.rank(items, query: "a", limit: 1000).count == FileSearch.maxLimit)
        #expect(FileSearch.rank(items, query: "a", limit: 0).isEmpty)
        #expect(FileSearch.rank(items, query: "a", limit: -5).isEmpty)
        #expect(FileSearch.rank([], query: "a").isEmpty)
        #expect(FileSearch.rank(items, query: "   ").isEmpty)
    }

    @Test func prefixScopes() {
        #expect(FileSearchQuery.parse("~a").scope == .filesOnly)
        #expect(FileSearchQuery.parse("FILE:a").scope == .filesOnly)
        #expect(FileSearchQuery.parse("filezilla").scope == .everything)
        #expect(FileSearchQuery.parse("a~b").scope == .everything)
    }

    @Test func kindParsing() {
        let a = FileSearchQuery.parseDetailed("~kind:pdf report")
        #expect(a.kind == .pdf && a.text == "report" && a.scope == .filesOnly)
        let b = FileSearchQuery.parseDetailed("file:KIND:Image  sunset beach")
        #expect(b.kind == .image && b.text == "sunset beach")
        let c = FileSearchQuery.parseDetailed("~kind:pdf")
        #expect(c.kind == .pdf && c.text.isEmpty)
        // Unknown kind stays text; no prefix means no kind filter.
        let d = FileSearchQuery.parseDetailed("~kind:foo report")
        #expect(d.kind == nil && d.text == "kind:foo report")
        let e = FileSearchQuery.parseDetailed("kind:pdf report")
        #expect(e.scope == .everything && e.kind == nil && e.text == "kind:pdf report")
        // parse keeps its old shape and drops the kind token.
        #expect(FileSearchQuery.parse("~kind:pdf report").text == "report")
    }

    @Test func everyKindHasExtensionsAndNamesRoundTrip() {
        for kind in FileKind.allCases {
            #expect(!kind.extensions.isEmpty)
            #expect(FileKind(name: kind.rawValue.uppercased()) == kind)
        }
        #expect(FileKind(name: "nope") == nil)
        #expect(FileKind.pdf.matches(URL(fileURLWithPath: "/a/B.PDF")))
        #expect(!FileKind.pdf.matches(URL(fileURLWithPath: "/a/pdf")))
    }

    @Test func rankFiltersByKind() {
        let items = [file("/Users/t/a/sunset.png"), file("/Users/t/a/sunset.txt"), file("/Users/t/a/sunset.mov")]
        #expect(FileSearch.rank(items, query: "sunset", kind: .image).map(\.name) == ["sunset.png"])
        #expect(FileSearch.rank(items, query: "sunset", kind: .archive).isEmpty)
        #expect(FileSearch.rank(items, query: "sunset").count == 3)
    }
}
