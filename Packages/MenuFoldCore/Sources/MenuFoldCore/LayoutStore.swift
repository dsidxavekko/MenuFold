import Foundation

/// What `LayoutStore.load()` found on disk.
public enum LoadOutcome: Equatable, Sendable {
    /// A valid layout was read (possibly with dead entries dropped, see `Layout.droppingInvalidFolders`).
    case loaded
    /// No file yet: first launch, or the user reset the layout.
    case missing
    /// The file could not be used. It was moved to this URL, or — if moving failed — it is still
    /// in place and `LayoutStore.lastQuarantineFailed` is true.
    case quarantined(URL)
    /// The file could not be read (permissions, lock, I/O) or is of an unreasonably large size.
    /// A read error is NOT corruption: the file was left untouched, so the next launch can retry.
    case unreadable(cause: String)
    /// Written by a newer MenuFold with a higher schema version. It was quarantined rather than
    /// rewritten in an older schema.
    case incompatible(URL)
}

/// Loads/saves `Layout` as JSON. Atomic writes; missing file → empty layout.
/// A file that cannot be DECODED (or comes from a newer app version) is moved aside to
/// `layout.corrupt-<yyyyMMdd-HHmmss>.json`, so the next save can't destroy the user's data, and an
/// empty layout is returned; the caller gets the details from `loadWithOutcome()`.
/// A file that cannot be READ (permissions, lock, I/O) is left untouched and retried next launch.
public final class LayoutStore: @unchecked Sendable {
    public let fileURL: URL

    /// ~/Library/Application Support/MenuFold/layout.json
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MenuFold", isDirectory: true).appendingPathComponent("layout.json")
    }

    /// Larger files are not a MenuFold layout (a real one is a few KB); refuse to load them.
    public static let maxFileSize = 32 * 1024 * 1024

    /// True when a corrupt file could not be moved aside. `save` then throws `LayoutStoreError`
    /// instead of overwriting it, so the user's unreadable data is not destroyed.
    /// `@unchecked Sendable`: only the main actor touches this store (see `GridModel`), while the
    /// file I/O itself is guarded by the filesystem's atomic writes.
    public private(set) var lastQuarantineFailed = false

    /// Whether the file may be renamed to a `layout.corrupt-…` backup. Injectable for tests: moving
    /// files out of $TMPDIR may be denied under SIP, and the failure path must be testable anyway.
    var isQuarantinable: (URL) -> Bool = { _ in true }

    /// Where custom app icons are kept: an `Icons` folder next to layout.json.
    public var iconsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Icons", isDirectory: true)
    }

    public init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
    }

    // MARK: Load

    public func load() -> Layout {
        loadWithOutcome().layout
    }

    /// Like `load()`, plus what happened, so the caller can tell the user and write a fresh file.
    public func loadWithOutcome() -> (layout: Layout, outcome: LoadOutcome) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return (Layout(), .missing)
        }

        let data: Data
        do {
            // An entry that exists but cannot be opened is a read error, not corruption.
            guard !isDirectory.boolValue, access(fileURL.path, R_OK) == 0 else {
                NSLog("%@", "MenuFold: layout exists but cannot be read; leaving it untouched")
                return (Layout(), .unreadable(cause: "cannot be opened"))
            }
            data = try Data(contentsOf: fileURL)
        } catch {
            NSLog("%@", "MenuFold: could not read layout, leaving it untouched: \(error.localizedDescription)")
            return (Layout(), .unreadable(cause: error.localizedDescription))
        }
        guard data.count <= Self.maxFileSize else {
            NSLog("%@", "MenuFold: layout file is \(data.count) bytes; refusing to load it")
            return (Layout(), .unreadable(cause: "file is unreasonably large"))
        }

        let decoded: Layout
        do {
            decoded = try JSONDecoder().decode(Layout.self, from: data)
        } catch {
            NSLog("%@", "MenuFold: layout is corrupt, moving it aside: \(error)")
            return (Layout(), quarantine(.corrupt(error.localizedDescription)))
        }

        // A newer app may have added fields we would silently drop when saving: keep its file.
        guard decoded.version <= Layout.currentVersion else {
            NSLog("%@", "MenuFold: layout version \(decoded.version) is newer than \(Layout.currentVersion); moving it aside")
            return (Layout(), quarantine(.incompatible))
        }

        var layout = decoded.droppingInvalidFolders()
        layout.version = Layout.currentVersion
        return (layout, .loaded)
    }

    // MARK: Save

    public func save(_ layout: Layout) throws {
        // Only a failed quarantine blocks saving: writing over the one copy of data we could not
        // read (or move) would destroy it. Writability is left to the write itself — asking whether
        // the file "is deletable" says nothing about whether the app may write it, and would make
        // the app silently stop saving in folders where writing works fine.
        guard !lastQuarantineFailed else { throw LayoutStoreError.quarantinePending(fileURL) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = layout
        copy.version = Layout.currentVersion
        let data = try encoder.encode(copy)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Quarantine

    private enum QuarantineReason {
        case corrupt(String)
        case incompatible
    }

    /// Renames the current file to `layout.corrupt-<yyyyMMdd-HHmmss>.json` in the same directory.
    /// Returns the destination when the move succeeded, or the unchanged path (flagged in
    /// `lastQuarantineFailed`) when it did not.
    private func quarantine(_ reason: QuarantineReason) -> LoadOutcome {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent + ".corrupt-" + formatter.string(from: Date())
        var dest = dir.appendingPathComponent(stem + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        do {
            guard isQuarantinable(fileURL) else { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: fileURL, to: dest)
        } catch {
            NSLog("%@", "MenuFold: failed to move the unusable layout aside; saving is disabled until it is resolved: \(error)")
            lastQuarantineFailed = true
            return .quarantined(fileURL)
        }
        switch reason {
        case .corrupt: return .quarantined(dest)
        case .incompatible: return .incompatible(dest)
        }
    }
}

public enum LayoutStoreError: Error, LocalizedError, Equatable {
    /// A corrupt file could not be moved aside; saving would overwrite the user's data.
    case quarantinePending(URL)

    public var errorDescription: String? {
        switch self {
        case .quarantinePending(let url):
            return "The layout at \(url.path) could not be moved aside, so it was not overwritten."
        }
    }
}
