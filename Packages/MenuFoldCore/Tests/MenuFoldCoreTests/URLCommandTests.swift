import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct URLCommandTests {
    func parse(_ s: String) -> URLCommand? { URL(string: s).flatMap(URLCommand.parse) }

    func makeModel() -> GridModel {
        let apps = "abcd".map { c in
            AppEntry(id: "com.x.\(c)", name: "App \(c.uppercased())",
                     url: URL(fileURLWithPath: "/Applications/\(c).app"), infoCategory: nil)
        }
        return GridModel(catalog: StaticAppCatalog(apps: apps), store: nil,
                         homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
    }

    @Test func oldCommands() {
        #expect(parse("menufold://toggle") == .toggle)
        #expect(parse("menufold://") == .show)
        #expect(parse("menufold://search?q=hi") == .search("hi"))
        #expect(parse("menufold://profile?name=none") == .profile(name: ""))
        #expect(parse("menufold://launch?id=a.b") == .launch(URLAppRef("a.b")))
        #expect(parse("http://toggle") == nil)
        #expect(parse("menufold://bogus") == nil)
        #expect(parse("menufold://folder") == nil)
    }

    @Test func newCommands() {
        #expect(parse("menufold://pin?id=a.b") == .pin(URLAppRef("a.b")))
        #expect(parse("menufold://unpin?name=Safari") == .unpin(URLAppRef("Safari")))
        #expect(parse("menufold://hide") == .hide)
        #expect(parse("menufold://hide?id=a.b") == .hideApp(URLAppRef("a.b")))
        #expect(parse("menufold://category?id=a.b&name=none") == .category(app: URLAppRef("a.b"), name: ""))
        #expect(parse("menufold://move-to-folder?id=a&folder=Work") == .moveToFolder(app: URLAppRef("a"), folder: "Work"))
        #expect(parse("menufold://pin?id=") == nil)
        #expect(parse("menufold://copy-path") == nil)
    }

    @Test func newFolderParsing() {
        #expect(parse("menufold://new-folder?name=F&apps=a,b,a") == .newFolder(name: "F", apps: [URLAppRef("a"), URLAppRef("b")]))
        #expect(parse("menufold://new-folder?name=F&apps=a") == nil)
        #expect(parse("menufold://new-folder?apps=a,b") == nil)
        let many = (0..<80).map { "id\($0)" }.joined(separator: ",")
        if case .newFolder(_, let apps)? = parse("menufold://new-folder?name=F&apps=\(many)") {
            #expect(apps.count == 50)
        } else { Issue.record("expected newFolder") }
        let long = String(repeating: "x", count: 300)
        #expect(parse("menufold://pin?id=\(long)") == nil)
    }

    @Test func resolveByIDThenName() {
        let m = makeModel()
        #expect(m.resolveApp(URLAppRef("com.x.a"))?.id == "com.x.a")
        #expect(m.resolveApp(URLAppRef("app b"))?.id == "com.x.b")
        #expect(m.resolveApp(URLAppRef("nope")) == nil)
    }

    @Test func mutations() {
        let m = makeModel()
        #expect(m.apply(.pin(URLAppRef("App A"))))
        #expect(m.isPinned("com.x.a"))
        #expect(m.apply(.unpin(URLAppRef("com.x.a"))))
        #expect(!m.isPinned("com.x.a"))
        #expect(m.apply(.newFolder(name: "F", apps: [URLAppRef("App A"), URLAppRef("com.x.b"), URLAppRef("zzz")])))
        #expect(m.folder(named: "f")?.appIDs == ["com.x.a", "com.x.b"])
        #expect(!m.apply(.newFolder(name: "G", apps: [URLAppRef("App C"), URLAppRef("zzz")])))
        #expect(m.apply(.moveToFolder(app: URLAppRef("App C"), folder: "F")))
        #expect(m.folder(named: "F")?.appIDs.count == 3)
        #expect(m.apply(.removeFromFolder(URLAppRef("App C"))))
        #expect(m.folder(named: "F")?.appIDs.count == 2)
        #expect(!m.apply(.moveToFolder(app: URLAppRef("App D"), folder: "missing")))
        #expect(m.apply(.category(app: URLAppRef("App D"), name: "other")))
        #expect(m.apply(.category(app: URLAppRef("App D"), name: "")))
        #expect(!m.apply(.category(app: URLAppRef("App D"), name: "no-such")))
    }
}
