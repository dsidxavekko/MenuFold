import Foundation
import Testing
@testable import MenuFoldCore

private struct StubChecker: AppUpdateChecker {
    var result: [String: AvailableUpdate]
    func checkUpdates(for apps: [AppUpdateCandidate]) async -> [String: AvailableUpdate] { result }
}

@Suite struct AppUpdateParsingTests {
    @Test func versionComparison() {
        #expect(AppUpdateParsing.isNewer("1.10", than: "1.9"))
        #expect(!AppUpdateParsing.isNewer("1.0", than: "1.0.0"))
        #expect(AppUpdateParsing.isNewer("2.0", than: "2.0b3"))
        #expect(!AppUpdateParsing.isNewer("2.0rc1", than: "2.0"))
        #expect(AppUpdateParsing.isNewer("1.0.1", than: "1.0"))
        #expect(AppUpdateParsing.compare("12345", "12346") == .orderedAscending)
        #expect(AppUpdateParsing.compare("1.2.3", "1.2.3") == .orderedSame)
    }

    @Test func brewJSON() {
        let json = #"{"formulae":[],"casks":[{"name":"firefox","installed_versions":["130.0"],"current_version":"131.0"},{"name":"bad name; rm","installed_versions":"1","current_version":"2"},{"name":"foo","installed_versions":"1","current_version":"2"}]}"#
        let r = AppUpdateParsing.parseBrewOutdated(Data(json.utf8))
        #expect(r.map(\.token) == ["firefox", "foo"])
        #expect(r[0].installed == "130.0" && r[0].current == "131.0")
        #expect(r[1].installed == "1")
        #expect(AppUpdateParsing.parseBrewOutdated(Data("nope".utf8)).isEmpty)
    }

    @Test func iTunesJSON() {
        let json = #"{"resultCount":1,"results":[{"trackId":123,"version":"4.5.6"}]}"#
        #expect(AppUpdateParsing.parseITunesLookup(Data(json.utf8)) == .init(version: "4.5.6", trackID: 123))
        #expect(AppUpdateParsing.parseITunesLookup(Data(#"{"resultCount":0,"results":[]}"#.utf8)) == nil)
    }

    @Test func appcast() {
        let xml = """
        <?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
        <item><title>2.0</title><enclosure url="https://x/a.zip" sparkle:version="200" sparkle:shortVersionString="2.0"/></item>
        <item><sparkle:version>300</sparkle:version><sparkle:shortVersionString>3.0</sparkle:shortVersionString>
          <sparkle:minimumSystemVersion>99.0</sparkle:minimumSystemVersion></item>
        <item><enclosure url="https://x/b.zip" sparkle:version="150" sparkle:shortVersionString="1.5"/></item>
        </channel></rss>
        """
        let items = AppUpdateParsing.parseAppcast(Data(xml.utf8))
        #expect(items.count == 3)
        let best = AppUpdateParsing.newestAppcastItem(items, osVersion: "26.0")
        #expect(best?.version == "200" && best?.shortVersion == "2.0")
        #expect(AppUpdateParsing.newestAppcastItem(items, osVersion: "100.0")?.version == "300")
        #expect(AppUpdateParsing.parseAppcast(Data("garbage".utf8)).isEmpty)
    }

    @Test func brewCommandOnlyForSafeTokens() {
        let ok = AvailableUpdate(appID: "a", kind: .homebrew, newVersion: "2", caskToken: "visual-studio-code")
        #expect(ok.brewCommand == "brew upgrade --cask visual-studio-code")
        let bad = AvailableUpdate(appID: "a", kind: .homebrew, newVersion: "2", caskToken: "x; ls")
        #expect(bad.brewCommand == nil)
        #expect(AvailableUpdate(appID: "a", kind: .sparkle, newVersion: "2", caskToken: "x").brewCommand == nil)
    }

    @Test func caskTokenScan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("caskroom-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("firefox/131.0/Firefox.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        #expect(BundleReader.homebrewCaskTokens(roots: [root.path]) == ["Firefox.app": "firefox"])
    }
}

@MainActor
@Suite struct GridModelUpdatesTests {
    func makeModel() -> GridModel {
        let apps = ["a", "b", "c"].map { AppEntry(id: $0, name: "App \($0)", url: URL(fileURLWithPath: "/Applications/\($0).app")) }
        return GridModel(catalog: StaticAppCatalog(apps: apps), store: nil,
                         homeDirectory: "/nonexistent-home", finderNameResolver: { $0 })
    }

    @Test func refreshPublishesAndSearchListsThem() async {
        let m = makeModel()
        let update = AvailableUpdate(appID: "b", kind: .sparkle, newVersion: "2")
        let stale = AvailableUpdate(appID: "gone", kind: .sparkle, newVersion: "2")
        await m.refreshAvailableUpdates(using: StubChecker(result: ["b": update, "gone": stale]))
        #expect(m.hasUpdate("b") && !m.hasUpdate("a") && !m.hasUpdate("gone"))
        #expect(m.items(tab: .all, query: "updates").map(\.id) == ["app:b"])
        #expect(m.items(tab: .all, query: "Оновлення").map(\.id) == ["app:b"])
        m.clearAvailableUpdates()
        #expect(!m.hasUpdate("b"))
    }
}
