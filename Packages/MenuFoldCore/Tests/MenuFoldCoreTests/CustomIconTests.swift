import AppKit
import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct CustomIconTests {
    let apps = [
        AppEntry(id: "mail", name: "Mail", url: URL(fileURLWithPath: "/System/Applications/Mail.app"), infoCategory: nil),
        AppEntry(id: "notes", name: "Notes", url: URL(fileURLWithPath: "/System/Applications/Notes.app"), infoCategory: nil),
    ]

    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// A 40×20 red PNG (not square, so aspect-fit is exercised).
    func writePNG(in dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.setColor(.red, atX: 0, y: 0)
        let url = dir.appendingPathComponent("pic.png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    func iconFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    @Test func setReplaceAndResetKeepOneFileAndPersist() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        let source = try writePNG(in: dir.appendingPathComponent("src"))

        try model.setCustomIcon(for: "mail", from: source)
        let first = try #require(model.customIconURL(for: "mail"))
        #expect(first.deletingLastPathComponent().standardizedFileURL == store.iconsDirectory.standardizedFileURL)
        let image = try #require(NSImage(contentsOf: first))
        #expect(image.representations.first?.pixelsWide == CustomIcons.pixelSize)
        #expect(image.representations.first?.pixelsHigh == CustomIcons.pixelSize)
        #expect(model.appsWithCustomIcons.map(\.id) == ["mail"])
        #expect(store.load().customIcons["mail"] == first.lastPathComponent)

        // The original can go away: the icon is a copy.
        try FileManager.default.removeItem(at: source)
        #expect(FileManager.default.fileExists(atPath: first.path))

        // Replacing gives a new file name and deletes the old file.
        let other = try writePNG(in: dir.appendingPathComponent("src2"))
        try model.setCustomIcon(for: "mail", from: other)
        let second = try #require(model.customIconURL(for: "mail"))
        #expect(second != first)
        #expect(iconFiles(store.iconsDirectory) == [second.lastPathComponent])

        model.resetCustomIcon(for: "mail")
        #expect(model.customIconURL(for: "mail") == nil)
        #expect(iconFiles(store.iconsDirectory).isEmpty)
        #expect(store.load().customIcons.isEmpty)
    }

    @Test func anyFileUsesItsFinderIcon() throws {
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        defer { try? FileManager.default.removeItem(at: model.iconsDirectory) }
        // Another app (a directory bundle) gives its own icon.
        try model.setCustomIcon(for: "notes", from: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        #expect(model.customIconURL(for: "notes").map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func badSourcesThrowAndChangeNothing() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let junk = dir.appendingPathComponent("junk.png")
        try Data("not an image".utf8).write(to: junk)
        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: nil)
        defer { try? FileManager.default.removeItem(at: model.iconsDirectory) }
        #expect(throws: CustomIconError.unreadableImage) { try model.setCustomIcon(for: "mail", from: junk) }
        #expect(throws: CustomIconError.unreadableImage) {
            try model.setCustomIcon(for: "mail", from: dir.appendingPathComponent("missing.txt"))
        }
        #expect(model.layout.customIcons.isEmpty)
    }

    @Test func loadDropsUnsafeNamesAndUnusedFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try FileManager.default.createDirectory(at: store.iconsDirectory, withIntermediateDirectories: true)
        for name in ["kept.png", "orphan.png"] {
            try Data([1]).write(to: store.iconsDirectory.appendingPathComponent(name))
        }
        try store.save(Layout(customIcons: ["mail": "kept.png", "notes": "../escape.png", "x": ".hidden.png"]))

        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(model.layout.customIcons == ["mail": "kept.png"])
        #expect(iconFiles(store.iconsDirectory) == ["kept.png"])

        model.resetLayout()
        #expect(iconFiles(store.iconsDirectory).isEmpty)
    }

    /// After a quarantine the old file still points at the icons, so they must survive.
    @Test func quarantinedLayoutKeepsIconFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try FileManager.default.createDirectory(at: store.iconsDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: store.iconsDirectory.appendingPathComponent("a.png"))
        try Data("{ not json".utf8).write(to: store.fileURL)
        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(iconFiles(store.iconsDirectory) == ["a.png"])
    }
}
