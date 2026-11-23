import Foundation
import Testing
@testable import MenuFoldCore

/// A file for the tests below: the path decides the id and the parent, everything else is optional.
private func fileItem(_ path: String, name: String = "", modified: Date? = nil, size: Int64? = nil,
                      directory: Bool = false) -> FileItem {
    FileItem(url: URL(fileURLWithPath: path, isDirectory: directory), name: name,
             modified: modified, size: size)
}

// MARK: - Item

@Suite("FileItem")
struct FileItemTests {
    @Test func idAndPathParts() {
        let item = fileItem("/Users/tester/Documents/report.pdf",
                            modified: Date(timeIntervalSince1970: 1_700_000_000), size: 2_048)
        // The id is the path, so the panel can keep its selection across queries.
        #expect(item.id == "/Users/tester/Documents/report.pdf")
        #expect(item.parentPath == "/Users/tester/Documents")
        #expect(item.size == 2_048)
        #expect(item.modified == Date(timeIntervalSince1970: 1_700_000_000))
        // The name falls back to the path component when a provider could not read one.
        #expect(item.name == "report.pdf")
    }

    @Test func hiddenNamesAndAppBundles() {
        #expect(fileItem("/Users/tester/.zshrc").isHiddenName)
        #expect(!fileItem("/Users/tester/notes.md").isHiddenName)
        #expect(fileItem("/Applications/Safari.app").isAppBundle)
        #expect(!fileItem("/Users/tester/notes.app.txt").isAppBundle)
        #expect(fileItem("/Users/tester/Notes").isAppBundle == false)
    }

    @Test func displayPathShortensHome() {
        let home = FileItem.homePath
        #expect(!home.isEmpty)
        #expect(fileItem(home).displayPath == "~")
        #expect(fileItem(home + "/Documents/notes.md").displayPath == "~/Documents/notes.md")
        // Anything outside the home folder keeps its absolute path.
        #expect(fileItem("/Applications/Notes.app").displayPath == "/Applications/Notes.app")
        // A sibling whose name merely starts with the home path is not inside it.
        #expect(fileItem(home + "-backup/notes.md").displayPath == home + "-backup/notes.md")
    }
}

// MARK: - Query parsing

@Suite("FileSearchQuery")
struct FileSearchQueryTests {
    @Test func tildePrefix() {
        let parsed = FileSearchQuery.parse("~invoice")
        #expect(parsed.scope == .filesOnly)
        #expect(parsed.text == "invoice")
    }

    @Test func prefixAfterSpaces() {
        let parsed = FileSearchQuery.parse("   ~  звіт  ")
        #expect(parsed.scope == .filesOnly)
        #expect(parsed.text == "звіт")
    }

    @Test func wordPrefix() {
        let parsed = FileSearchQuery.parse("file:report")
        #expect(parsed.scope == .filesOnly)
        #expect(parsed.text == "report")
        // Typed either case, and with spaces around it, like the tilde form.
        #expect(FileSearchQuery.parse("  FILE:  договір").text == "договір")
        #expect(FileSearchQuery.parse("  File:  договір").scope == .filesOnly)
    }

    @Test func barePrefixKeepsScope() {
        // Nothing to match yet, but the panel can still keep offering files.
        #expect(FileSearchQuery.parse("~").scope == .filesOnly)
        #expect(FileSearchQuery.parse("~").text == "")
        #expect(FileSearchQuery.parse("   ~   ").text == "")
        #expect(FileSearchQuery.parse("file:").scope == .filesOnly)
        #expect(FileSearchQuery.parse("file:").text == "")
        #expect(FileSearchQuery.parse("   ").scope == .everything)
        #expect(FileSearchQuery.parse("   ").text == "")
        #expect(FileSearchQuery.parse("").text == "")
    }

    @Test func withoutPrefix() {
        let parsed = FileSearchQuery.parse("  Safari ")
        #expect(parsed.scope == .everything)
        #expect(parsed.text == "Safari")
        // The colon is what makes the prefix a prefix: these stay ordinary queries.
        #expect(FileSearchQuery.parse("filezilla").scope == .everything)
        #expect(FileSearchQuery.parse("filezilla").text == "filezilla")
        #expect(FileSearchQuery.parse("файл").scope == .everything)
        // Only a leading prefix counts.
        #expect(FileSearchQuery.parse("a~b").scope == .everything)
        #expect(FileSearchQuery.parse("a~b").text == "a~b")
    }
}

// MARK: - Ranking

@Suite("FileSearch")
struct FileSearchTests {
    @Test func exactBeatsPrefixBeatsContains() {
        let items = [
            fileItem("/Users/tester/Foonotesbar.txt"),
            fileItem("/Users/tester/Notes-2024.txt"),
            fileItem("/Users/tester/Notes.md"),
            fileItem("/Users/tester/Notes"),
        ]
        let ranked = FileSearch.rank(items, query: "notes", limit: 8)
        // Exact name, then the name typed without its extension, then the plain prefix, then a match
        // buried inside a word.
        #expect(ranked.map(\.name) == ["Notes", "Notes.md", "Notes-2024.txt", "Foonotesbar.txt"])
    }

    @Test func exactStemStaysInsideItsTier() {
        // A boosted prefix ("Notes.md") must never outrank an exact name ("Notes"), however fresh it is.
        let fresh = Date(timeIntervalSince1970: 2_000_000_000)
        let items = [fileItem("/Users/tester/Notes.md", modified: fresh),
                     fileItem("/Users/tester/Notes", modified: Date(timeIntervalSince1970: 1_000))]
        #expect(FileSearch.rank(items, query: "notes", limit: 8).map(\.name) == ["Notes", "Notes.md"])
    }

    @Test func caseAndDiacriticsAreIgnored() {
        let items = [fileItem("/Users/tester/Кошторис.xlsx"), fileItem("/Users/tester/Café.txt")]
        #expect(FileSearch.rank(items, query: "КОШТОРИС", limit: 8).map(\.name) == ["Кошторис.xlsx"])
        #expect(FileSearch.rank(items, query: "cafe", limit: 8).map(\.name) == ["Café.txt"])
    }

    @Test func limitTrimsResults() {
        let many = (1...30).map { fileItem("/Users/tester/report-\($0).txt") }
        #expect(FileSearch.rank(many, query: "report", limit: 3).count == 3)
        #expect(FileSearch.rank(many, query: "report", limit: 0).isEmpty)
        #expect(FileSearch.rank(many, query: "report", limit: -5).isEmpty)
        // Whatever a caller asks for, `maxLimit` is the ceiling.
        #expect(FileSearch.rank(many, query: "report", limit: 100).count == FileSearch.maxLimit)
        #expect(FileSearch.defaultLimit < FileSearch.maxLimit)
    }

    @Test func emptyQueryGivesNothing() {
        let items = [fileItem("/Users/tester/notes.md")]
        #expect(FileSearch.rank(items, query: "", limit: 8).isEmpty)
        #expect(FileSearch.rank(items, query: "   ", limit: 8).isEmpty)
        #expect(FileSearch.rank([], query: "notes", limit: 8).isEmpty)
        // A query that matches nothing.
        #expect(FileSearch.rank(items, query: "xz", limit: 8).isEmpty)
    }

    @Test func tiesGoToFresherThenNameThenPath() {
        let old = Date(timeIntervalSince1970: 1_000)
        let fresh = Date(timeIntervalSince1970: 2_000)
        let a = fileItem("/Users/tester/a/report.pdf", modified: old)
        let b = fileItem("/Users/tester/b/report.pdf", modified: fresh)
        let c = fileItem("/Users/tester/c/report.pdf", modified: fresh)
        let expected = ["/Users/tester/b/report.pdf", "/Users/tester/c/report.pdf",
                        "/Users/tester/a/report.pdf"]
        #expect(FileSearch.rank([a, b, c], query: "report", limit: 8).map(\.id) == expected)
        // Same scores, same dates: the path decides, whatever order the provider used.
        #expect(FileSearch.rank([c, a, b], query: "report", limit: 8).map(\.id) == expected)
        #expect(FileSearch.rank([b, c, a], query: "report", limit: 8).map(\.id) == expected)
    }

    @Test func equalScoresSortByName() {
        let items = [fileItem("/Users/tester/Notes"), fileItem("/Users/tester/Nectar")]
        #expect(FileSearch.rank(items, query: "n", limit: 8).map(\.name) == ["Nectar", "Notes"])
    }

    @Test func missingDateLosesFreshnessTies() {
        let dated = fileItem("/Users/tester/b/plan.pdf", modified: Date(timeIntervalSince1970: 1))
        let undated = fileItem("/Users/tester/a/plan.pdf")
        #expect(FileSearch.rank([undated, dated], query: "plan", limit: 8).map(\.id)
                == ["/Users/tester/b/plan.pdf", "/Users/tester/a/plan.pdf"])
    }
}

// MARK: - Filter

@Suite("FileSearchFilter")
struct FileSearchFilterTests {
    @Test func hiddenFilesAreRejected() {
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/.zshrc")))
        #expect(FileSearch.isCandidate(fileItem("/Users/tester/notes.md")))
    }

    @Test func appsAndFoldersAreRejected() {
        #expect(!FileSearch.isCandidate(fileItem("/Applications/Safari.app")))
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/Documents", directory: true)))
        // A helper inside a bundle is part of an app, not a document.
        #expect(!FileSearch.isCandidate(fileItem("/Applications/Safari.app/Contents/Resources/icon.png")))
        #expect(FileSearch.isCandidate(fileItem("/Users/tester/Documents/photo.png")))
    }

    @Test func appFoldersAndCachesAreRejected() {
        let home = FileItem.homePath
        #expect(!home.isEmpty)
        #expect(!FileSearch.isCandidate(fileItem(home + "/Library/Preferences/com.example.plist")))
        #expect(!FileSearch.isCandidate(fileItem(home + "/Library/Developer/Xcode/DerivedData/x.txt")))
        #expect(!FileSearch.isCandidate(fileItem(home + "/Applications/helper.txt")))
        #expect(!FileSearch.isCandidate(fileItem(home + "/.Trash/old.txt")))
        #expect(!FileSearch.isCandidate(fileItem("/Library/Developer/CommandLineTools/README.md")))
        #expect(!FileSearch.isCandidate(fileItem("/.Trashes/501/old.txt")))
        // The user's own documents still get through.
        #expect(FileSearch.isCandidate(fileItem(home + "/Documents/notes.md")))
        #expect(FileSearch.isCandidate(fileItem(home + "/Desktop/scan.pdf")))
    }

    @Test func buildAndVCSFoldersAreRejected() {
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/project/.git/config")))
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/app/node_modules/left-pad/index.js")))
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/app/.build/debug/tool")))
        #expect(FileSearch.isCandidate(fileItem("/Users/tester/app/Sources/main.swift")))
    }

    @Test func dotSegmentsCannotWalkIntoExcludedFolders() {
        let home = FileItem.homePath
        #expect(!home.isEmpty)
        // Lexical normalization: ".." must not hide where the file really lives.
        #expect(!FileSearch.isCandidate(fileItem(home + "/Library/../Library/Caches/x.txt")))
        #expect(!FileSearch.isCandidate(fileItem("/Users/tester/project/.git/../.git/HEAD")))
    }
}
