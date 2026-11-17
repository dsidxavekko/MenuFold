import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct DiskUsageTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("menufold-disk-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func hardLinksAreCountedOnce() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a")
        try Data(repeating: 7, count: 200_000).write(to: a)
        let single = DiskUsage.measure(dir).bytes
        try FileManager.default.linkItem(at: a, to: dir.appendingPathComponent("b"))
        try FileManager.default.linkItem(at: a, to: dir.appendingPathComponent("c"))
        let linked = DiskUsage.measure(dir)
        #expect(linked.bytes == single)
        #expect(!linked.isLowerBound)
    }

    @Test func missingItemIsExactZero() {
        let size = DiskUsage.measure(tempDir().appendingPathComponent("nope"))
        #expect(size == .zero)
    }

    @Test func unreadableSubfolderMakesLowerBound() throws {
        let dir = tempDir()
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 50_000).write(to: locked.appendingPathComponent("x"))
        try Data(repeating: 1, count: 20_000).write(to: dir.appendingPathComponent("y"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        guard getuid() != 0 else { return }
        let size = DiskUsage.measure(dir)
        #expect(size.isLowerBound)
        #expect(size.bytes >= 20_000)
        #expect(size.formatted.hasPrefix("≥ "))
    }

    @Test func symlinkIsNotFollowed() throws {
        let dir = tempDir(), outside = tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: outside) }
        try Data(repeating: 1, count: 500_000).write(to: outside.appendingPathComponent("big"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(DiskUsage.measure(dir).bytes < 100_000)
    }

    @Test func cancellationGivesLowerBound() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<5 { try Data(repeating: 1, count: 5000).write(to: dir.appendingPathComponent("f\(i)")) }
        let size = DiskUsage.measure(dir, isCancelled: { true })
        #expect(size.isLowerBound)
    }

    @Test func asyncSizeMatchesSync() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 1, count: 30_000).write(to: dir.appendingPathComponent("f"))
        let a = await DiskUsage.size(of: dir)
        #expect(a == DiskUsage.measure(dir))
    }
}

@Suite struct LeftoverRulesTests {
    let id = "com.example.Editor"
    func lib() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("menufold-lo-\(UUID().uuidString)", isDirectory: true)
        let lib = root.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: lib, withIntermediateDirectories: true)
        return (root, lib)
    }
    func write(_ lib: URL, _ rel: String, _ size: Int = 10) throws {
        let url = lib.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: size).write(to: url)
    }
    func rels(_ found: [(url: URL, kind: LeftoverKind)], _ lib: URL) -> Set<String> {
        Set(found.map { $0.url.path.replacingOccurrences(of: lib.standardizedFileURL.path + "/", with: "") })
    }

    @Test func cachesDotSuffixIsNotMatched() throws {
        let (root, lib) = try lib()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(lib, "Caches/\(id)/a.db")
        try write(lib, "Caches/\(id).ShipIt/b")       // not an exact name: not matched
        try write(lib, "Caches/\(id)X/c")
        let found = AppLeftovers(library: lib).locate(bundleID: id)
        #expect(rels(found, lib) == ["Caches/\(id)"])
        #expect(found.first?.kind == .caches)
    }

    @Test func matchesAreCaseInsensitive() throws {
        let (root, lib) = try lib()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(lib, "Preferences/COM.example.editor.plist")
        try write(lib, "Preferences/COM.EXAMPLE.EDITOR.helper.plist")
        try write(lib, "Preferences/com.example.editor.beta.plist")
        try write(lib, "Group Containers/ABCDE12345.COM.example.EDITOR/x")
        let found = AppLeftovers(library: lib).locate(bundleID: id, otherBundleIDs: ["Com.Example.Editor.Beta"])
        let names = rels(found, lib)
        #expect(names.contains("Preferences/COM.example.editor.plist"))
        #expect(names.contains("Preferences/COM.EXAMPLE.EDITOR.helper.plist"))
        #expect(names.contains("Group Containers/ABCDE12345.COM.example.EDITOR"))
        #expect(!names.contains("Preferences/com.example.editor.beta.plist"))
    }

    @Test func symlinkedLibraryFolderLeadsNowhere() throws {
        let (root, lib) = try lib()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("Group Containers"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lib.appendingPathComponent("Containers"), withDestinationURL: outside)
        #expect(AppLeftovers(library: lib).locate(bundleID: id).isEmpty)
    }

    @Test func groupContainersNeedAPlainTeamPrefix() throws {
        let (root, lib) = try lib()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(lib, "Group Containers/ABCDE12345.\(id)/x")
        try write(lib, "Group Containers/group.\(id)/x")
        try write(lib, "Group Containers/other.team.\(id)/x")
        let found = AppLeftovers(library: lib).locate(bundleID: id)
        #expect(rels(found, lib) == ["Group Containers/ABCDE12345.\(id)", "Group Containers/group.\(id)"])
        #expect(found.allSatisfy { $0.kind == .containers })
    }

    @Test func belongsToOtherAppRule() {
        let finder = AppLeftovers(library: URL(fileURLWithPath: "/tmp"))
        let id = "com.foo.app"
        let others: Set<String> = ["com.foo.app.beta"]
        #expect(finder.belongsToOtherApp("com.foo.app.beta", id: id, others: others))
        #expect(finder.belongsToOtherApp("com.foo.app.beta.helper", id: id, others: others))
        #expect(!finder.belongsToOtherApp("com.foo.app.helper", id: id, others: others))
        #expect(!finder.belongsToOtherApp("com.foo.app.betamax", id: id, others: others))
    }

    @Test func unreadableFolderIsSkippedNotFatal() throws {
        let (root, lib) = try lib()
        let prefs = lib.appendingPathComponent("Preferences")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: prefs.path)
            try? FileManager.default.removeItem(at: root)
        }
        try write(lib, "Preferences/\(id).plist")
        try write(lib, "Caches/\(id)/a", 100)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: prefs.path)
        guard getuid() != 0 else { return }
        let found = AppLeftovers(library: lib).locate(bundleID: id)
        #expect(rels(found, lib) == ["Caches/\(id)"])
    }

    @Test func breakdownGroupsAndSizesAsync() async throws {
        let (root, lib) = try lib()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(lib, "Preferences/\(id).plist", 100)
        try write(lib, "Caches/\(id)/a", 40_000)
        try write(lib, "Containers/\(id)/b", 40_000)
        try write(lib, "Application Support/\(id)/c", 40_000)
        let found = await AppLeftovers(library: lib).findSized(bundleID: id)
        let groups = found.grouped()
        #expect(groups.map(\.kind) == [.caches, .preferences, .containers, .other])
        #expect(found.totalSize.bytes >= 120_000)
        #expect(!found.totalSize.isLowerBound)
        #expect(groups[0].size.bytes >= 40_000)
    }
}
