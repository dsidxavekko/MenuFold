import Foundation
import MenuFoldCore

/// Watches layout.json for changes made by someone else — another Mac through a synced data folder
/// (iCloud Drive, Dropbox), or a user editing the file — and calls `onChange` debounced.
///
/// The watch is on the *file*: `LayoutStore` (and sync clients) replace it atomically by renaming a
/// temporary file over it, which leaves a descriptor pointing at the old, unlinked inode. So a
/// delete/rename event re-arms the watch on the new file (retrying while it does not exist yet), and
/// counts as a change too. While the file is missing, the parent folder is watched instead, so the
/// first write that creates it is noticed.
///
/// MenuFold's own saves are noticed as well; `GridModel.reloadLayoutFromDisk()` is a no-op when the
/// file holds the layout already in memory, so that costs one read. Writes are also skipped while the
/// file's modification date and size are unchanged since the last delivered change.
final class LayoutFileWatcher: @unchecked Sendable {
    private let fileURL: URL
    private let debounce: TimeInterval
    private let onChange: @MainActor () -> Void
    private let queue = DispatchQueue(label: "MenuFold.LayoutFileWatcher")

    // All state below is touched only on `queue`.
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var lastSignature: Signature?
    private var stopped = false

    private struct Signature: Equatable {
        let modified: Date?
        let size: Int?
        let inode: Int?
    }

    init(fileURL: URL, debounce: TimeInterval = 0.5, onChange: @escaping @MainActor () -> Void) {
        self.fileURL = fileURL
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    func start() {
        queue.async { [self] in
            stopped = false
            lastSignature = signature()
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            pending?.cancel()
            pending = nil
            source?.cancel()
            source = nil
        }
    }

    /// Opens the file (or, when it is missing, its folder) for event-only access and watches it.
    private func arm() {
        source?.cancel()
        source = nil
        guard !stopped else { return }
        let fileFD = open(fileURL.path, O_EVTONLY)
        let watchingFile = fileFD >= 0
        let fd = watchingFile ? fileFD : open(fileURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else {
            // Not even the folder is there (a sync folder not mounted yet): try again later.
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.arm() }
            return
        }
        let mask: DispatchSource.FileSystemEvent = watchingFile
            ? [.write, .extend, .delete, .rename, .revoke, .attrib]
            : [.write]
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if !watchingFile || events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                // The inode we hold is gone (atomic replace) or we watched the folder: re-arm on
                // whatever is at the path now. A short delay lets the rename finish.
                self.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
            }
            self.scheduleChange()
        }
        source.setCancelHandler { close(fd) }
        self.source = source
        source.resume()
    }

    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            let now = self.signature()
            guard now != self.lastSignature else { return }
            self.lastSignature = now
            // A missing file is not a change to apply (it is mid-replace, or was deleted on purpose).
            guard now.inode != nil else { return }
            let onChange = self.onChange
            Task { @MainActor in onChange() }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    private func signature() -> Signature {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return Signature(modified: attrs?[.modificationDate] as? Date,
                         size: (attrs?[.size] as? NSNumber)?.intValue,
                         inode: (attrs?[.systemFileNumber] as? NSNumber)?.intValue)
    }
}

/// Watches several files (history.json and usage.json of a shared data folder) and calls `onChange`
/// when any of them changes. One `LayoutFileWatcher` per file.
final class SharedStatsWatcher: @unchecked Sendable {
    private let watchers: [LayoutFileWatcher]

    init(fileURLs: [URL], debounce: TimeInterval = 1, onChange: @escaping @MainActor () -> Void) {
        watchers = fileURLs.map { LayoutFileWatcher(fileURL: $0, debounce: debounce, onChange: onChange) }
    }

    func start() { watchers.forEach { $0.start() } }
    func stop() { watchers.forEach { $0.stop() } }
}

/// Where history.json and usage.json live and how they are opened.
///
/// Without a shared data folder: the default support folder, exactly as before. With one: the
/// files sit next to layout.json, history merges with what other Macs wrote (`AppHistoryStore.isShared`)
/// and usage keeps one part per Mac (`UsageStore.deviceID`). The first time, the Mac's existing local
/// files are copied there when the shared ones do not exist yet, so nothing starts from zero.
enum SharedStatsFiles {
    struct Result {
        let usage: UsageStore
        let history: AppHistoryStore
        /// The two files to watch (empty when not shared).
        let watchedURLs: [URL]
    }

    private static let deviceKey = "statsDeviceID"

    static func make(supportDir: URL, dataDir: URL, isShared: Bool) -> Result {
        let localHistory = supportDir.appendingPathComponent("history.json")
        let localUsage = supportDir.appendingPathComponent("usage.json")
        guard isShared else {
            return Result(usage: UsageStore(fileURL: localUsage), history: AppHistoryStore(fileURL: localHistory), watchedURLs: [])
        }
        let history = dataDir.appendingPathComponent("history.json")
        let usage = dataDir.appendingPathComponent("usage.json")
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        for (from, to) in [(localHistory, history), (localUsage, usage)]
        where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
            try? fm.copyItem(at: from, to: to)
        }
        let defaults = UserDefaults.standard
        let device = defaults.string(forKey: deviceKey) ?? {
            let id = UUID().uuidString
            defaults.set(id, forKey: deviceKey)
            return id
        }()
        let historyStore = AppHistoryStore(fileURL: history)
        historyStore.isShared = true
        return Result(usage: UsageStore(fileURL: usage, deviceID: device), history: historyStore,
                      watchedURLs: [history, usage])
    }
}
