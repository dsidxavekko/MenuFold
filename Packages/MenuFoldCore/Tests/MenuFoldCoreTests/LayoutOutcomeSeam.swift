import Foundation
import Testing
@testable import MenuFoldCore

/// `GridModel` must report what `LayoutStore` found, and write a fresh file after a quarantine.
@MainActor
@Suite struct LayoutOutcomeSeamTests {
    func tempStore(_ contents: String?) throws -> (LayoutStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("layout.json")
        if let contents { try Data(contents.utf8).write(to: url) }
        return (LayoutStore(fileURL: url), dir)
    }

    @Test func missingFileReportsMissing() throws {
        let (store, dir) = try tempStore(nil)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        #expect(model.layoutOutcome == .missing)
        #expect(!model.quarantineFailedInPlace)
    }

    @Test func validFileReportsLoaded() throws {
        let (store, dir) = try tempStore(#"{"version":1,"hidden":["a"]}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        #expect(model.layoutOutcome == .loaded)
        #expect(model.layout.hidden == ["a"])
    }

    /// A corrupt file is quarantined AND a fresh valid layout is written, so quitting right away
    /// doesn't leave the user with no layout file at all.
    @Test func quarantinedFileIsReportedAndReplacedByAValidOne() throws {
        let (store, dir) = try tempStore("{ not json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        guard case .quarantined(let backup) = model.layoutOutcome else {
            Issue.record("expected .quarantined, got \(model.layoutOutcome)")
            return
        }
        #expect(backup.lastPathComponent.hasPrefix("layout.corrupt-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json") // original kept
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path)) // fresh file written
        #expect(store.load() == Layout()) // and it is valid
    }

    /// A newer file is quarantined (not rewritten), reported, and a fresh file is left for the next run.
    @Test func incompatibleFileIsReported() throws {
        let (store, dir) = try tempStore(#"{"version":999}"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = GridModel(catalog: StaticAppCatalog(apps: []), store: store)
        guard case .incompatible = model.layoutOutcome else {
            Issue.record("expected .incompatible, got \(model.layoutOutcome)")
            return
        }
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8).contains("\"version\" : 1"))
    }
}
