import Foundation

/// A size in bytes plus whether it is only a lower bound (some part could not be read, or the
/// count was cancelled), so the UI can show "≥ 1.2 GB" instead of a wrong exact number.
public struct DiskSize: Hashable, Sendable {
    public var bytes: Int64
    public var isLowerBound: Bool
    public init(bytes: Int64, isLowerBound: Bool = false) { self.bytes = bytes; self.isLowerBound = isLowerBound }

    public static let zero = DiskSize(bytes: 0)

    public static func + (a: DiskSize, b: DiskSize) -> DiskSize {
        DiskSize(bytes: a.bytes + b.bytes, isLowerBound: a.isLowerBound || b.isLowerBound)
    }

    /// "1,2 MB", or "≥ 1,2 MB" for a lower bound.
    public var formatted: String {
        let text = ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
        return isLowerBound ? "≥ " + text : text
    }
}

/// Bytes an item really takes on disk.
public enum DiskUsage {
    /// Plain byte count (see `measure`). Kept for API stability; ignores the lower-bound flag.
    public static func allocatedSize(of url: URL) -> Int64 { measure(url).bytes }

    /// Off the calling actor and cancellable: cancelling the task stops the walk and returns what
    /// was counted so far, marked as a lower bound.
    public static func size(of url: URL) async -> DiskSize {
        let task = Task.detached(priority: .userInitiated) {
            measure(url, isCancelled: { Task.isCancelled })
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private final class Flag: @unchecked Sendable { var value = false }

    /// Allocated size of a file, or the sum over everything inside a directory (an .app bundle,
    /// a container). Directories count too, symbolic links count as links (never followed, so a
    /// link to another volume does not inflate the size), and a file reachable through several hard
    /// links is counted once. Anything that cannot be read (permissions, I/O, a vanished file)
    /// makes the result a lower bound; an item that does not exist is exactly 0.
    public static func measure(_ url: URL, isCancelled: () -> Bool = { false }) -> DiskSize {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileResourceIdentifierKey,
                                      .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        let keySet = Set(keys)
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keySet)
        } catch {
            return DiskSize(bytes: 0, isLowerBound: !isMissing(error))
        }
        var seen = Set<AnyHashable>()
        var total: Int64 = 0
        var partial = false
        func add(_ v: URLResourceValues) {
            if v.isRegularFile == true, let id = v.fileResourceIdentifier as? NSObject {
                guard seen.insert(AnyHashable(id)).inserted else { return }
            }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        add(values)
        guard values.isDirectory == true, values.isSymbolicLink != true else { return DiskSize(bytes: total) }
        let failed = Flag()
        // The enumerator does not descend into symbolic links.
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, error in
                if !isMissing(error) { failed.value = true }
                return true
            }) else { return DiskSize(bytes: total, isLowerBound: true) }
        while let item = enumerator.nextObject() as? URL {
            if isCancelled() { partial = true; break }
            do {
                add(try item.resourceValues(forKeys: keySet))
            } catch {
                if !isMissing(error) { partial = true }
            }
        }
        return DiskSize(bytes: total, isLowerBound: partial || failed.value)
    }

    private static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain && (e.code == NSFileNoSuchFileError || e.code == NSFileReadNoSuchFileError)
    }
}

/// What a support file is, for the uninstaller's breakdown.
public enum LeftoverKind: String, CaseIterable, Sendable {
    /// Caches, logs, saved window state, web storage: safe to delete, rebuilt on demand.
    case caches
    case preferences
    case containers
    case other
}

/// Finds an app's support files in ~/Library for the uninstaller.
///
/// Deliberately conservative: an item is listed only when its NAME ties it to the bundle id.
/// Folders named after the app (`Application Support/Firefox`) are never matched: sibling apps
/// (Firefox Developer Edition, Nightly, …) share them, and the name says nothing about which app
/// owns the data. Trashing someone else's data is far worse than leaving a few files behind, so
/// anything ambiguous is skipped:
/// - apps whose bundle id starts with `com.apple.` get nothing (system data is shared);
/// - `<id>.<suffix>.plist`-style matches skip a suffix that is itself another installed app
///   (`com.foo.App` must not take `com.foo.App.beta`'s files);
/// - nothing is ever reached through a symbolic link that leaves ~/Library.
public struct AppLeftovers: Sendable {
    /// The user's Library folder (injectable for tests).
    public let library: URL

    public init(library: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)) {
        self.library = library
    }

    /// Support files of the app with `bundleID` at `appURL`. `otherBundleIDs`: the other installed
    /// apps, whose files must never be matched by a prefix. Sorted by path.
    /// `appURL` is not used for matching (see the type's comment); it stays for API stability.
    /// Sizes each item synchronously; UI code should prefer `findSized` (async, cancellable).
    public func find(bundleID: String, appURL: URL, otherBundleIDs: Set<String> = []) -> [Leftover] {
        locate(bundleID: bundleID, otherBundleIDs: otherBundleIDs).map { url, kind in
            let size = DiskUsage.measure(url)
            return Leftover(url: url, size: size.bytes, isLowerBound: size.isLowerBound, kind: kind)
        }
    }

    /// Same as `find`, but sizing runs off the calling actor, items in parallel, and cancelling the
    /// task returns early (sizes then are lower bounds).
    public func findSized(bundleID: String, otherBundleIDs: Set<String> = []) async -> [Leftover] {
        let items = locate(bundleID: bundleID, otherBundleIDs: otherBundleIDs)
        let sized = await withTaskGroup(of: (Int, DiskSize).self) { group -> [Int: DiskSize] in
            for (i, item) in items.enumerated() {
                group.addTask { (i, await DiskUsage.size(of: item.url)) }
            }
            var out: [Int: DiskSize] = [:]
            for await (i, size) in group { out[i] = size }
            return out
        }
        return items.enumerated().map { i, item in
            let size = sized[i] ?? DiskSize(bytes: 0, isLowerBound: true)
            return Leftover(url: item.url, size: size.bytes, isLowerBound: size.isLowerBound, kind: item.kind)
        }
    }

    /// The matching items without sizing (fast). Sorted by path.
    ///
    /// Names are compared case-insensitively (APFS is case-insensitive by default, so
    /// `Preferences/Com.Foo.App.plist` is the same file), and the URLs carry the on-disk spelling.
    public func locate(bundleID: String, otherBundleIDs: Set<String> = []) -> [(url: URL, kind: LeftoverKind)] {
        let id = bundleID
        let idl = id.lowercased()
        guard Self.isPlausibleBundleID(id), !idl.hasPrefix("com.apple.") else { return [] }
        let others = Set(otherBundleIDs.map { $0.lowercased() })
        var urls: [(URL, LeftoverKind)] = []

        /// Items of `dir` whose lowercased name is one of `exact`.
        func addExact(_ dir: String, _ kind: LeftoverKind, _ exact: [String]) {
            let wanted = Set(exact.map { $0.lowercased() })
            for name in contents(of: dir) where wanted.contains(name.lowercased()) {
                urls.append((library.appendingPathComponent("\(dir)/\(name)"), kind))
            }
        }
        // Exact names.
        addExact("Preferences", .preferences, ["\(id).plist"])
        addExact("Caches", .caches, [id])
        addExact("HTTPStorages", .caches, [id, "\(id).binarycookies"])
        addExact("Cookies", .preferences, ["\(id).binarycookies"])
        addExact("WebKit", .caches, [id])
        addExact("Saved Application State", .caches, ["\(id).savedState"])
        addExact("Containers", .containers, [id])
        addExact("Application Scripts", .containers, [id])
        addExact("Logs", .caches, [id])
        addExact("Application Support", .other, [id])

        // "<id>.<something>.plist" (helper prefs, per-host prefs, launch agents).
        for dir in ["Preferences", "Preferences/ByHost", "LaunchAgents"] {
            let kind: LeftoverKind = dir == "LaunchAgents" ? .other : .preferences
            for name in contents(of: dir) where name.lowercased().hasSuffix(".plist") {
                let stem = String(name.dropLast(".plist".count)).lowercased()
                if dir == "LaunchAgents", stem == idl { urls.append((library.appendingPathComponent("\(dir)/\(name)"), kind)); continue }
                guard stem.hasPrefix(idl + "."), !belongsToOtherApp(stem, id: idl, others: others) else { continue }
                urls.append((library.appendingPathComponent("\(dir)/\(name)"), kind))
            }
        }

        // Group containers: "<TEAMID>.<id>" or "group.<id>".
        for name in contents(of: "Group Containers") where name.lowercased().hasSuffix("." + idl) {
            let prefix = name.dropLast(id.count + 1)
            if !prefix.isEmpty, prefix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                urls.append((library.appendingPathComponent("Group Containers/\(name)"), .containers))
            }
        }

        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.0.standardizedFileURL.path.lowercased()).inserted && isSafeItem($0.0) }
            .sorted { $0.0.path < $1.0.path }
            .map { (url: $0.0.standardizedFileURL, kind: $0.1) }
    }

    // MARK: Rules

    /// Letters, digits, ".", "-", "_" and at least one dot, so a bare word ("Safari") never matches.
    static func isPlausibleBundleID(_ id: String) -> Bool {
        guard id.contains("."), !id.hasPrefix("."), !id.hasSuffix("."), !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
    }

    /// `stem` ("com.foo.App.beta.something") is, or lives under, another installed app's id.
    /// `stem` and `others` are lowercased.
    func belongsToOtherApp(_ stem: String, id: String, others: Set<String>) -> Bool {
        others.contains { other in
            other != id && other.count > id.count && (stem == other || stem.hasPrefix(other + "."))
        }
    }

    // MARK: File system

    private func contents(of relativeDir: String) -> [String] {
        let dir = library.appendingPathComponent(relativeDir, isDirectory: true)
        guard isInsideLibrary(dir) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    /// The item exists (as itself: a symlink counts, its target is not looked at) and its parent
    /// folder resolves to a place inside ~/Library, so a linked `Caches` cannot lead elsewhere.
    private func isSafeItem(_ url: URL) -> Bool {
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return false }
        return isInsideLibrary(url.deletingLastPathComponent())
    }

    private func isInsideLibrary(_ dir: URL) -> Bool {
        let root = library.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = dir.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == root || resolved.hasPrefix(root + "/")
    }
}
