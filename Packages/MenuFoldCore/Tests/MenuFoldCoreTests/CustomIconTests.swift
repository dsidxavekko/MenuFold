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

        // Replacing gives a new file name; the old file stays for undo.
        let other = try writePNG(in: dir.appendingPathComponent("src2"))
        try model.setCustomIcon(for: "mail", from: other)
        let second = try #require(model.customIconURL(for: "mail"))
        #expect(second != first)
        #expect(Set(iconFiles(store.iconsDirectory)) == [first.lastPathComponent, second.lastPathComponent])

        model.resetCustomIcon(for: "mail")
        #expect(model.customIconURL(for: "mail") == nil)
        #expect(iconFiles(store.iconsDirectory).count == 2)
        #expect(store.load().customIcons.isEmpty)
        // Undo finds the file again.
        model.undo()
        #expect(model.customIconURL(for: "mail") == second)

        // The next launch removes what nothing uses (files aged past the one-minute grace).
        for name in iconFiles(store.iconsDirectory) { age(store.iconsDirectory.appendingPathComponent(name)) }
        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(iconFiles(store.iconsDirectory) == [second.lastPathComponent])
    }

    func age(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)], ofItemAtPath: url.path)
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
        let kept = UUID().uuidString + ".png", orphan = UUID().uuidString + ".png"
        for name in [kept, orphan, "foreign.png", "notes.txt"] {
            let url = store.iconsDirectory.appendingPathComponent(name)
            try Data([1]).write(to: url)
            // The prune keeps files written less than a minute ago (another MenuFold instance may
            // have just written an icon this process has not read): age the fixtures past it.
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120)],
                                                  ofItemAtPath: url.path)
        }
        try store.save(Layout(customIcons: ["mail": kept, "notes": "../escape.png", "x": ".hidden.png"]))

        let model = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(model.layout.customIcons == ["mail": kept])
        // Only MenuFold's own `<UUID>.png` names are ever deleted: foreign files survive.
        #expect(Set(iconFiles(store.iconsDirectory)) == [kept, "foreign.png", "notes.txt"])

        // A reset deletes nothing (undo may map the file again).
        model.resetLayout()
        #expect(Set(iconFiles(store.iconsDirectory)) == [kept, "foreign.png", "notes.txt"])
    }

    /// In a shared (synced) folder the cleanup never runs: another Mac's icon may arrive before
    /// the layout.json that uses it.
    @Test func sharedFolderSkipsIconCleanup() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        store.isShared = true
        try FileManager.default.createDirectory(at: store.iconsDirectory, withIntermediateDirectories: true)
        let orphan = UUID().uuidString + ".png"
        try Data([1]).write(to: store.iconsDirectory.appendingPathComponent(orphan))
        age(store.iconsDirectory.appendingPathComponent(orphan))
        try store.save(Layout(hidden: ["x"]))
        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(iconFiles(store.iconsDirectory) == [orphan])
    }

    @Test func ownIconFileNames() {
        #expect(GridModel.isOwnIconFileName(UUID().uuidString + ".png"))
        #expect(!GridModel.isOwnIconFileName(UUID().uuidString + ".jpg"))
        #expect(!GridModel.isOwnIconFileName("kept.png"))
        #expect(!GridModel.isOwnIconFileName(".png"))
    }

    /// An unused icon file written less than a minute ago survives the prune: another MenuFold
    /// instance (two copies can run at once) may have just written an icon for a layout this
    /// process has not read, and deleting it would lose that icon.
    @Test func freshUnusedIconFilesAreKept() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try FileManager.default.createDirectory(at: store.iconsDirectory, withIntermediateDirectories: true)
        let fresh = UUID().uuidString + ".png", used = UUID().uuidString + ".png"
        try Data([1]).write(to: store.iconsDirectory.appendingPathComponent(fresh))
        try Data([1]).write(to: store.iconsDirectory.appendingPathComponent(used))
        try store.save(Layout(customIcons: ["mail": used]))

        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(Set(iconFiles(store.iconsDirectory)) == [fresh, used])
    }

    /// After a quarantine the old file still points at the icons, so they must survive.
    @Test func quarantinedLayoutKeepsIconFiles() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LayoutStore(fileURL: dir.appendingPathComponent("layout.json"))
        try FileManager.default.createDirectory(at: store.iconsDirectory, withIntermediateDirectories: true)
        let a = UUID().uuidString + ".png"
        try Data([1]).write(to: store.iconsDirectory.appendingPathComponent(a))
        age(store.iconsDirectory.appendingPathComponent(a))
        try Data("{ not json".utf8).write(to: store.fileURL)
        _ = GridModel(catalog: StaticAppCatalog(apps: apps), store: store)
        #expect(iconFiles(store.iconsDirectory) == [a])
    }
}
