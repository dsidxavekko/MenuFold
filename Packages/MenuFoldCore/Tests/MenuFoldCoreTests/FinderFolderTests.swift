import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct FinderFolderKeyTests {
    let home = "/Users/me"
    func key(_ p: String) -> String? { FinderFolders.key(forAppPath: p, homeDirectory: home) }

    @Test func nestedUsesTopLevelSubfolder() {
        #expect(key("/Applications/Робота/X.app") == "/Applications/Робота")
        #expect(key("/Applications/Робота/Dev/X.app") == "/Applications/Робота")
    }

    @Test func topLevelAppsHaveNoFolder() {
        #expect(key("/Applications/Safari.app") == nil)
        #expect(key("/Users/me/Applications/Foo.app") == nil)
        #expect(key("/System/Applications/Mail.app") == nil)
        #expect(key("/Applications") == nil)
        #expect(key("/Applications/Foo.app/Contents/Helper.app") == nil) // bundle, not a folder
        #expect(key("/opt/Tools/X.app") == nil)
        #expect(key("/System/Applications/Other/X.app") == nil) // only Utilities under /System
    }

    @Test func utilities() {
        #expect(key("/System/Applications/Utilities/Terminal.app") == "/System/Applications/Utilities")
        #expect(key("/System/Applications/Utilities/Sub/X.app") == "/System/Applications/Utilities")
    }

    @Test func homeApplications() {
        #expect(key("/Users/me/Applications/Chrome Apps/Docs.app") == "/Users/me/Applications/Chrome Apps")
        #expect(FinderFolders.key(forAppPath: "/Users/me/Applications/A/X.app", homeDirectory: "/Users/me/") == "/Users/me/Applications/A")
        #expect(key("/Users/other/Applications/A/X.app") == nil)
    }

    @Test func dataVolumeNormalized() {
        #expect(key("/System/Volumes/Data/Applications/Робота/X.app") == "/Applications/Робота")
        #expect(key("/System/Volumes/Data/Users/me/Applications/A/X.app") == "/Users/me/Applications/A")
        #expect(key("/System/Volumes/Data/Applications/X.app") == nil)
    }

    @Test func stableID() {
        let a = FinderFolders.folderID(forPath: "/Applications/Робота")
        #expect(a == FinderFolders.folderID(forPath: "/Applications/Робота"))
        #expect(a != FinderFolders.folderID(forPath: "/Applications/Ігри"))
    }

    /// A path with ".." must never produce a folder key such as "/Applications/..": that key is
    /// persisted in finderStyles/ignoredFinderFolders and shows up as a nonsense tile.
    @Test func dotSegmentsAreStandardizedOrRejected() {
        #expect(key("/Applications/../../tmp/Evil.app") == nil)
        #expect(key("/Applications/Робота/../Ігри/X.app") == "/Applications/Ігри")
        #expect(key("/Applications/./Робота/./X.app") == "/Applications/Робота")
        // Lexically resolved, then judged against the roots: this one really lands in ~/Applications.
        #expect(FinderFolders.key(forAppPath: "/Users/me/Applications/Dev/../../Applications/A/X.app",
                                  homeDirectory: home) == "/Users/me/Applications/A")
        // "/Applications/../.." pops /Applications and then cannot pop "/", so it escapes the root.
        #expect(FinderFolders.standardized("/Applications/../../Users/me/Applications/A/X.app") == nil)
        #expect(FinderFolders.standardized("/Applications/../etc") == "/etc")
        #expect(key("/Applications/../etc/X.app") == nil) // /etc is not an applications root
        #expect(FinderFolders.standardized("/..") == nil)
        #expect(FinderFolders.standardized("relative/X.app") == nil)
        #expect(FinderFolders.standardized("/") == "/")
    }

    @Test func rootHomeStillFindsApplications() {
        // "/" and "" are the same: no ~/Applications root, /Applications still works.
        for rootHome in ["/", ""] {
            #expect(FinderFolders.key(forAppPath: "/Applications/A/X.app", homeDirectory: rootHome) == "/Applications/A")
            #expect(FinderFolders.key(forAppPath: "/Applications/A/X.app", homeDirectory: "/") == "/Applications/A")
        }
        #expect(FinderFolders.key(forAppPath: "/Applications/A/X.app", homeDirectory: "/Users/me/") == "/Applications/A")
    }

    /// The key is what gets persisted, so a path that the grid shows must derive the same key
    /// whichever way the catalog spells "/System/Volumes/Data/…".
    @Test func dataVolumePathYieldsCanonicalKey() {
        #expect(key("/System/Volumes/Data/Applications/Робота/Dev/X.app") == "/Applications/Робота")
        #expect(key("/System/Volumes/Data/System/Applications/Utilities/Terminal.app") == "/System/Applications/Utilities")
    }
}

@MainActor
@Suite struct FinderFolderModelTests {
    static func app(_ id: String, _ name: String, _ path: String) -> AppEntry {
        AppEntry(id: id, name: name, url: URL(fileURLWithPath: path, isDirectory: true), infoCategory: nil)
    }

    static let work = "/Applications/Робота"
    static let utils = "/System/Applications/Utilities"
    let sample: [AppEntry] = [
        app("slack", "Slack", "/Applications/Робота/Slack.app"),
        app("zoom", "Zoom", "/Applications/Робота/Video/Zoom.app"),
        app("term", "Terminal", "/System/Applications/Utilities/Terminal.app"),
        app("mail", "Mail", "/System/Applications/Mail.app"),
        app("safari", "Safari", "/Applications/Safari.app"),
    ]

    func makeModel(store: LayoutStore? = nil, apps: [AppEntry]? = nil) -> (GridModel, StaticAppCatalog) {
        let cat = StaticAppCatalog(apps: apps ?? sample)
        let names = [Self.work: "Робота", Self.utils: "Утиліти", "/Applications/Gone": "Gone"]
        let m = GridModel(catalog: cat, store: store, homeDirectory: "/Users/me",
                          finderNameResolver: { names[$0] ?? ($0 as NSString).lastPathComponent })
        return (m, cat)
    }

    func titles(_ m: GridModel) -> [String] { m.items(tab: .all, query: "").map(\.title) }
    var workID: UUID { FinderFolders.folderID(forPath: Self.work) }
    var utilsID: UUID { FinderFolders.folderID(forPath: Self.utils) }

    @Test func synthesizedInAll() throws {
        let (m, _) = makeModel()
        #expect(titles(m) == ["Mail", "Safari", "Утиліти", "Робота"].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        let f = try #require(m.folder(id: workID))
        #expect(f.isFinder && f.finderPath == Self.work && f.name == "Робота")
        #expect(m.apps(in: f).map(\.id) == ["slack", "zoom"])
        #expect(m.folderContaining(appID: "zoom")?.id == workID)
        #expect(m.folderContaining(appID: "term")?.id == utilsID)
        #expect(m.folderContaining(appID: "mail") == nil)
        // Single-app Finder folder stays; category tabs and search stay flat.
        #expect(m.apps(in: m.folder(id: utilsID)!).count == 1)
        #expect(m.items(tab: .all, query: "zo").map(\.title) == ["Zoom"])
        #expect(m.items(tab: .category(.other), query: "").count == sample.count)
        #expect(m.layout == Layout()) // nothing persisted just by showing
    }

    @Test func stableIDAcrossRefresh() {
        let (m, cat) = makeModel()
        m.openFolderID = workID
        cat.replace(sample.filter { $0.id != "slack" })
        #expect(m.openFolderID == workID)
        #expect(m.folder(id: workID)?.appIDs == ["zoom"])
        cat.replace(sample.filter { $0.id != "slack" && $0.id != "zoom" })
        #expect(m.openFolderID == nil)
        #expect(m.folder(id: workID) == nil)
    }

    @Test func manualWins() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "term", onto: "mail"))
        #expect(m.folder(id: id)?.appIDs == ["mail", "term"])
        #expect(m.folderContaining(appID: "term")?.id == id)
        #expect(m.folder(id: utilsID) == nil) // no apps left → not synthesized
        #expect(!titles(m).contains("Утиліти"))
        m.removeFromFolder("term") // manual folder dissolves (≤1), term returns to Finder folder
        #expect(m.folderContaining(appID: "term")?.id == utilsID)
        #expect(m.layout.finderExclusions.isEmpty)
    }

    @Test func createFolderOntoFinderApp() throws {
        let (m, _) = makeModel()
        let id = try #require(m.createFolder(dropping: "safari", onto: "slack"))
        #expect(id != workID)
        #expect(m.renamingFolderID == id)
        let f = try #require(m.folder(id: id))
        #expect(!f.isFinder && f.appIDs == ["slack", "safari"])
        #expect(m.folder(id: workID)?.appIDs == ["zoom"])
        // Target in a manual folder → join it.
        #expect(m.createFolder(dropping: "mail", onto: "slack") == id)
        // Adding to a Finder folder moves it there in MenuFold only (leaves the manual folder).
        m.add("mail", to: workID)
        #expect(m.folderContaining(appID: "mail")?.id == workID)
        #expect(m.folder(id: id)?.appIDs == ["slack", "safari"])
    }

    @Test func dropIntoFinderFolderIsVirtual() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let (m, _) = makeModel(store: store)
        // Top-level app → Finder folder.
        m.add("safari", to: workID)
        #expect(m.layout.finderAdditions == ["safari": Self.work])
        #expect(Set(try #require(m.folder(id: workID)).appIDs) == ["slack", "zoom", "safari"])
        // App from another Finder folder → moves between Finder folders.
        m.add("term", to: workID)
        #expect(m.folderContaining(appID: "term")?.id == workID)
        #expect(m.folder(id: utilsID) == nil)
        // Persisted.
        let (m2, _) = makeModel(store: store)
        #expect(m2.folderContaining(appID: "safari")?.id == workID)
        // Pulling out: a dropped-in top-level app returns to the top level without an exclusion…
        m.removeFromFolder("safari")
        #expect(m.folderContaining(appID: "safari") == nil)
        #expect(!m.layout.finderExclusions.contains("safari"))
        // …while an app that lives in another Finder folder on disk gets excluded instead of falling back.
        m.removeFromFolder("term")
        #expect(m.folderContaining(appID: "term") == nil)
        #expect(m.layout.finderExclusions.contains("term"))
        // Dropping an excluded app back in works.
        m.add("term", to: workID)
        #expect(m.folderContaining(appID: "term")?.id == workID)
        #expect(!m.layout.finderExclusions.contains("term"))
    }

    @Test func exclusionsViaRemoveFromFolder() {
        let (m, _) = makeModel()
        m.openFolderID = utilsID
        m.removeFromFolder("term")
        #expect(m.layout.finderExclusions == ["term"])
        #expect(m.folderContaining(appID: "term") == nil)
        #expect(titles(m).contains("Terminal"))
        #expect(m.openFolderID == nil)
        m.removeFromFolder("slack")
        #expect(m.folder(id: workID)?.appIDs == ["zoom"])
        m.removeFromFolder("mail") // not in any folder → no-op
        #expect(m.layout.finderExclusions == ["slack", "term"])
    }

    @Test func dissolveAndRestore() {
        let (m, _) = makeModel()
        m.openFolderID = workID
        m.dissolve(folder: workID)
        #expect(m.layout.ignoredFinderFolders == [Self.work])
        #expect(m.folder(id: workID) == nil)
        #expect(m.openFolderID == nil)
        #expect(titles(m).contains("Slack") && titles(m).contains("Zoom"))
        m.dissolve(folder: utilsID)
        #expect(m.ignoredFinderFolders == [FinderFolderRef(id: Self.work, name: "Робота"), FinderFolderRef(id: Self.utils, name: "Утиліти")])
        m.restoreFinderFolder(path: Self.work)
        #expect(m.folder(id: workID)?.appIDs == ["slack", "zoom"])
        #expect(m.ignoredFinderFolders.map(\.id) == [Self.utils])
    }

    @Test func ignoredNamesResolvedWithoutApps() {
        let (m, _) = makeModel(apps: [])
        m.restoreFinderFolder(path: "/nope") // no-op
        var l = Layout()
        l.ignoredFinderFolders = ["/Applications/Gone"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try? store.save(l)
        let (m2, _) = makeModel(store: store, apps: [])
        #expect(m2.ignoredFinderFolders == [FinderFolderRef(id: "/Applications/Gone", name: "Gone")])
        #expect(m.ignoredFinderFolders.isEmpty)
    }

    /// A junk path in the layout (hand-edited, or written by an older build from a ".." path) is
    /// dropped on load, so it can never become a folder tile.
    @Test func junkFinderPathsAreDroppedOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        var l = Layout()
        l.finderStyles = [Self.work: FinderFolderStyle(color: .green), "/Applications/..": FinderFolderStyle(color: .red)]
        l.ignoredFinderFolders = [Self.utils, "/Applications/.."]
        l.finderAdditions = ["safari": Self.work, "junk": "relative/path"]
        try store.save(l)
        let (m, _) = makeModel(store: store)
        #expect(m.layout.finderStyles.keys.sorted() == [Self.work])
        #expect(m.layout.ignoredFinderFolders == [Self.utils])
        #expect(m.layout.finderAdditions == ["safari": Self.work])
        #expect(m.ignoredFinderFolders.map(\.id) == [Self.utils])
        #expect(m.folderContaining(appID: "safari")?.id == workID)
    }

    @Test func renameIsNoOpAndStylePersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let (m, _) = makeModel(store: store)
        m.rename(folder: workID, to: "Інше")
        #expect(m.folder(id: workID)?.name == "Робота")
        m.setStyle(folder: workID, color: .purple, symbol: "briefcase")
        #expect(m.layout.finderStyles[Self.work] == FinderFolderStyle(color: .purple, symbol: "briefcase"))
        #expect(m.layout.folders.isEmpty)
        m.removeFromFolder("zoom")
        m.dissolve(folder: utilsID)

        let (m2, _) = makeModel(store: store)
        let f = try #require(m2.folder(id: workID))
        #expect(f.color == .purple && f.symbol == "briefcase")
        #expect(f.appIDs == ["slack"])
        #expect(m2.folder(id: utilsID) == nil)

        m2.resetLayout()
        #expect(store.load() == Layout())
        #expect(m2.folder(id: workID)?.color == .gray)
        #expect(m2.folder(id: utilsID) != nil)
    }

    @Test func previewHasUtilitiesFinderFolder() throws {
        let m = GridModel.preview
        let f = try #require(m.folder(id: FinderFolders.folderID(forPath: Self.utils)))
        #expect(f.isFinder)
        #expect(f.name == FileManager.default.displayName(atPath: Self.utils))
        #expect(m.items(tab: .all, query: "").contains { $0.id == "folder:\(f.id.uuidString)" })
    }
}
