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
    /// Saving refuses to overwrite such a file (or quarantines it first once it became readable
    /// again), so the data cannot be destroyed by a save.
    case unreadable(cause: String)
    /// Written by a newer MenuFold with a higher schema version. It was quarantined rather than
    /// rewritten in an older schema.
    case incompatible(URL)
}

/// Loads/saves `Layout` as JSON. Atomic writes; missing file → empty layout.
/// A file that cannot be DECODED (or comes from a newer app version) is moved aside to
/// `layout.corrupt-<yyyyMMdd-HHmmss>.json`, so the next save can't destroy the user's data, and an
/// empty layout is returned; the caller gets the details from `loadWithOutcome()`.
/// A file that cannot be READ (permissions, lock, I/O) is left untouched and retried next launch;
/// saving refuses to overwrite such a file (or quarantines it first once it became readable again),
/// so the data cannot be destroyed by a save.
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

    /// True when `loadWithOutcome()` left a file in place that it could not read (see
    /// `LoadOutcome.unreadable`, except the oversized-file case: a readable junk file may be
    /// overwritten freely). `save` then refuses to overwrite it, or quarantines it first if it
    /// became readable again.
    public private(set) var hasUnreadFileInPlace = false

    /// Whether the file may be renamed to a `layout.corrupt-…` backup. Injectable for tests: moving
    /// files out of $TMPDIR may be denied under SIP, and the failure path must be testable anyway.
    var isQuarantinable: (URL) -> Bool = { _ in true }

    /// Where custom app icons are kept: an `Icons` folder next to layout.json.
    public var iconsDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Icons", isDirectory: true)
    }

    /// True when the layout lives in a folder the user chose (usually synced between Macs, e.g.
    /// iCloud Drive). Set by the app before handing the store to `GridModel`: a shared folder must
    /// never get destructive housekeeping (fresh empty layout after a quarantine, icon cleanup),
    /// because another Mac may still be using that data.
    public var isShared = false

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
            hasUnreadFileInPlace = false
            return (Layout(), .missing)
        }

        let data: Data
        do {
            // An entry that exists but cannot be opened is a read error, not corruption.
            guard !isDirectory.boolValue, access(fileURL.path, R_OK) == 0 else {
                NSLog("%@", "MenuFold: layout exists but cannot be read; leaving it untouched")
                hasUnreadFileInPlace = true
                return (Layout(), .unreadable(cause: "cannot be opened"))
            }
            // Size first: a huge (or sparse) file must not be pulled into memory just to be refused.
            if let size = Self.fileSize(at: fileURL), size > Self.maxFileSize {
                NSLog("%@", "MenuFold: layout file is \(size) bytes; refusing to load it")
                hasUnreadFileInPlace = false
                return (Layout(), .unreadable(cause: "file is unreasonably large"))
            }
            data = try Data(contentsOf: fileURL)
        } catch {
            NSLog("%@", "MenuFold: could not read layout, leaving it untouched: \(error.localizedDescription)")
            hasUnreadFileInPlace = true
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

        let layout = decoded.migrated().droppingInvalidFolders()
        hasUnreadFileInPlace = false
        return (layout, .loaded)
    }

    /// Decodes and validates layout data exactly like `loadWithOutcome()` does for layout.json, but
    /// without touching any file: for backups, imports and sync reloads. A newer schema is rejected
    /// (`LayoutDataError.newerVersion`) rather than silently losing its new fields.
    /// Size of the file in bytes without reading it, nil when unknown.
    static func fileSize(at url: URL) -> Int? {
        // Not `URL.resourceValues`: it caches per URL instance and would report a stale size.
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// Reads a file only if it is at most `limit` bytes (checked BEFORE reading); a larger file
    /// throws `LayoutDataError.damaged`.
    static func readLimited(_ url: URL, limit: Int = maxFileSize) throws -> Data {
        if let size = fileSize(at: url), size > limit { throw LayoutDataError.damaged }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw LayoutDataError.damaged }
        return data
    }

    static func decodeValidated(_ data: Data) throws -> Layout {
        guard data.count <= maxFileSize else { throw LayoutDataError.damaged }
        let decoded: Layout
        do {
            decoded = try JSONDecoder().decode(Layout.self, from: data)
        } catch {
            throw LayoutDataError.damaged
        }
        return try validated(decoded)
    }

    /// The validation step of `decodeValidated` for an already decoded layout (an export file
    /// embeds one): rejects newer versions, drops invalid entries, normalizes the version.
    static func validated(_ decoded: Layout) throws -> Layout {
        guard decoded.version <= Layout.currentVersion else { throw LayoutDataError.newerVersion }
        return decoded.migrated().droppingInvalidFolders()
    }

    // MARK: Save

    public func save(_ layout: Layout) throws {
        // A failed quarantine blocks saving: writing over the one copy of data we could not move
        // aside would destroy it. Writability is left to the write itself — asking whether the file
        // "is deletable" says nothing about whether the app may write it, and would make the app
        // silently stop saving in folders where writing works fine.
        // Retried on every save: the cause (a lock, permissions) may be gone by now.
        if lastQuarantineFailed {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = quarantine(.corrupt("retry"))
            } else {
                lastQuarantineFailed = false
            }
            guard !lastQuarantineFailed else { throw LayoutStoreError.quarantinePending(fileURL) }
        }
        // A file we could not read must never be overwritten: the atomic write below is a
        // rename-over, which succeeds whenever the directory is writable and would destroy the
        // only copy of the data. Refuse while it stays unreadable; if it became readable again
        // before the first save, move it aside first (the data is kept as a `layout.corrupt-…`
        // backup, same as a corrupt file).
        if hasUnreadFileInPlace, FileManager.default.fileExists(atPath: fileURL.path) {
            guard access(fileURL.path, R_OK) == 0 else {
                throw LayoutStoreError.unreadablePending(fileURL)
            }
            _ = quarantine(.unreadable)
            guard !lastQuarantineFailed else { throw LayoutStoreError.quarantinePending(fileURL) }
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = layout
        copy.version = Layout.currentVersion
        let data = try encoder.encode(copy)
        rotateBackups()
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Backups (layout.bak)

    /// How often the previous file is copied to `layout.bak`; the first save of a session always does.
    var backupInterval: TimeInterval = 600
    private var lastBackupRotation: Date?

    private var backupURL: URL { fileURL.deletingPathExtension().appendingPathExtension("bak") }
    private var olderBackupURL: URL { fileURL.deletingPathExtension().appendingPathExtension("bak2") }

    /// Keeps the two most recent previous states (`layout.bak`, `layout.bak2`) of a valid file.
    /// Skipped for a shared folder (another Mac may be using it) and for a file that does not decode
    /// (it must never replace a good backup). Best effort: a failure never blocks the save.
    private func rotateBackups() {
        guard !isShared else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        if let last = lastBackupRotation, Date().timeIntervalSince(last) < backupInterval { return }
        guard let data = try? Self.readLimited(fileURL), (try? Self.decodeValidated(data)) != nil else { return }
        do {
            if fm.fileExists(atPath: backupURL.path) {
                try? fm.removeItem(at: olderBackupURL)
                try fm.moveItem(at: backupURL, to: olderBackupURL)
            }
            try data.write(to: backupURL, options: .atomic)
            lastBackupRotation = Date()
        } catch {
            NSLog("%@", "MenuFold: could not rotate the layout backup: \(error)")
        }
    }

    /// Newest `layout.corrupt-…` files kept; older ones are deleted after a new quarantine.
    static let maxCorruptBackups = 5

    private func pruneCorruptBackups(keeping keep: URL) {
        guard !isShared else { return }
        let dir = fileURL.deletingLastPathComponent()
        let prefix = fileURL.deletingPathExtension().lastPathComponent + ".corrupt-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        // Files from a newer app version (version > currentVersion) are the user's only copy of
        // data this build cannot read: never delete them, and do not count them.
        struct VersionOnly: Decodable { var version: Int? }
        let corrupt = names.filter { name in
            guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
            if let data = try? Self.readLimited(dir.appendingPathComponent(name)),
               let version = try? JSONDecoder().decode(VersionOnly.self, from: data).version,
               version > Layout.currentVersion { return false }
            return true
        }.sorted()
        guard corrupt.count > Self.maxCorruptBackups else { return }
        for name in corrupt.dropLast(Self.maxCorruptBackups) where name != keep.lastPathComponent {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Quarantine

    private enum QuarantineReason {
        case corrupt(String)
        case incompatible
        case unreadable
    }

    /// Renames the current file to `layout.corrupt-<yyyyMMdd-HHmmss>.json` in the same directory.
    /// Returns the destination when the move succeeded, or the unchanged path (flagged in
    /// `lastQuarantineFailed`) when it did not.
    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private func quarantine(_ reason: QuarantineReason) -> LoadOutcome {
        let formatter = Self.stampFormatter
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
        // The file is gone from its original path, so nothing unread can be overwritten there.
        hasUnreadFileInPlace = false
        lastQuarantineFailed = false
        pruneCorruptBackups(keeping: dest)
        switch reason {
        case .corrupt, .unreadable: return .quarantined(dest)
        case .incompatible: return .incompatible(dest)
        }
    }
}

/// Why a backup or an exported layout file could not be used.
public enum LayoutDataError: Error, LocalizedError, Equatable {
    /// Not a file written by "Експортувати розкладку".
    case notMenuFoldFile
    /// Written by a newer MenuFold (higher schema or file-format version).
    case newerVersion
    /// Not valid JSON, or a key holds a value of the wrong shape.
    case damaged

    public var errorDescription: String? {
        switch self {
        case .notMenuFoldFile: return L("Це не файл розкладки MenuFold.")
        case .newerVersion: return L("Файл створено новішою версією MenuFold. Оновіть програму й спробуйте ще раз.")
        case .damaged: return L("Файл розкладки пошкоджено.")
        }
    }
}

public enum LayoutStoreError: Error, LocalizedError, Equatable {
    /// A corrupt file could not be moved aside; saving would overwrite the user's data.
    case quarantinePending(URL)

    /// A file that could not be read is still in place; saving would overwrite it (see `save`).
    case unreadablePending(URL)

    public var errorDescription: String? {
        switch self {
        case .quarantinePending(let url):
            return "The layout at \(url.path) could not be moved aside, so it was not overwritten."
        case .unreadablePending(let url):
            return "The layout at \(url.path) could not be read, so it was not overwritten. Fix its permissions and restart MenuFold."
        }
    }
}
