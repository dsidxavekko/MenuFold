import AppKit
import Foundation

/// A dated copy of layout.json in the backups folder.
public struct LayoutBackup: Identifiable, Hashable, Sendable {
    public let url: URL
    public let date: Date
    public var id: URL { url }
    public init(url: URL, date: Date) { self.url = url; self.date = date }
}

/// A support file of an app found for the uninstaller (preferences, caches, containers, …).
public struct Leftover: Identifiable, Hashable, Sendable {
    public let url: URL
    /// Bytes on disk (0 when unknown).
    public let size: Int64
    public var id: URL { url }
    public init(url: URL, size: Int64) { self.url = url; self.size = size }
}

extension GridModel {
    // MARK: History (new apps, recent, unused)

    /// Called after every catalog delivery: records first-seen dates of new apps and saves.
    /// The very first delivery ever (empty history) stamps every app with `.distantPast`: apps that
    /// were installed before MenuFold are not "new". Entries of removed apps are kept, so a
    /// reinstalled app is not new again. An empty delivery (Spotlight failed) changes nothing.
    ///
    /// While history.json exists but cannot be read (`historyUnreadable`) it is read again first;
    /// if it still fails nothing is stamped: treating it as a first run would save an almost empty
    /// history over the user's file, and stamping `now()` would mark every app new.
    func noteCatalogApps() {
        guard !apps.isEmpty, retryHistoryIfUnreadable() else { return }
        var h = history
        let firstRun = h.firstSeen.isEmpty
        let date = firstRun ? Date.distantPast : now()
        for app in apps where h.firstSeen[app.id] == nil {
            h.firstSeen[app.id] = date
        }
        // A "seen" mark only matters while the app could be new.
        let cutoff = now().addingTimeInterval(-AppHistory.newAppInterval)
        h.seen = h.seen.filter { (h.firstSeen[$0] ?? .distantPast) > cutoff }
        saveHistory(h)
    }

    /// Called by `recordUse` for each real launch: stores the last-launch date and saves.
    func noteLaunched(appID: String) {
        var h = history
        h.lastLaunched[appID] = now()
        saveHistory(h)
    }

    /// The user opened the app from MenuFold: it is no longer "new".
    public func markSeen(_ appID: String) {
        guard isNew(appID) else { return }
        var h = history
        h.seen.insert(appID)
        saveHistory(h)
    }

    /// True for an app first seen in the last 7 days and not launched since.
    public func isNew(_ appID: String) -> Bool {
        guard let first = history.firstSeen[appID],
              now().timeIntervalSince(first) < AppHistory.newAppInterval,
              !history.seen.contains(appID) else { return false }
        if let launched = history.lastLaunched[appID], launched >= first { return false }
        return true
    }

    /// Latest known use: MenuFold's history or Spotlight's `lastUsedDate`, whichever is newer.
    public func lastUsed(_ app: AppEntry) -> Date? {
        switch (history.lastLaunched[app.id], app.lastUsedDate) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// Visible apps not used for `interval` (or never), least recently used first. System apps
    /// (under /System) are left out: they cannot be trashed.
    /// An app that first appeared within `interval` is left out too, even if never opened: it was
    /// only just installed, so "not used" says nothing about it yet.
    public func unusedApps(olderThan interval: TimeInterval) -> [AppEntry] {
        let cutoff = now().addingTimeInterval(-interval)
        let candidates = visibleApps.compactMap { app -> (AppEntry, Date?)? in
            guard canTrash(app) else { return nil }
            let used = lastUsed(app)
            if let used, used >= cutoff { return nil }
            if used == nil, let first = history.firstSeen[app.id], first > cutoff { return nil }
            return (app, used)
        }
        return candidates.sorted { lhs, rhs in
            let l = lhs.1 ?? .distantPast, r = rhs.1 ?? .distantPast
            if lhs.1 == nil, rhs.1 != nil { return true }
            if lhs.1 != nil, rhs.1 == nil { return false }
            if l != r { return l < r }
            let n = lhs.0.name.localizedStandardCompare(rhs.0.name)
            return n == .orderedSame ? lhs.0.id < rhs.0.id : n == .orderedAscending
        }.map(\.0)
    }

    /// Keeps `h` in memory and saves it, unless history.json is still unreadable: then the file is
    /// left alone (the in-memory changes are merged in once it can be read, see
    /// `retryHistoryIfUnreadable`).
    private func saveHistory(_ h: AppHistory) {
        guard h != history else { return }
        history = h
        guard let historyStore, retryHistoryIfUnreadable() else { return }
        do { try historyStore.save(history) } catch {
            NSLog("%@", "MenuFold: failed to save app history: \(error.localizedDescription)")
        }
    }

    /// True when history.json may be written: it was readable (or missing) at load, or it can be
    /// read now. A successful late read merges the file into the in-memory history: the file's
    /// first-seen dates win (they are older), the later launch date wins, `seen` is united.
    private func retryHistoryIfUnreadable() -> Bool {
        guard historyUnreadable else { return true }
        guard let historyStore else { historyUnreadable = false; return true }
        let disk = historyStore.load()
        guard !historyStore.lastLoadUnreadable else { return false }
        historyUnreadable = false
        var merged = disk
        for (id, date) in history.firstSeen where merged.firstSeen[id] == nil { merged.firstSeen[id] = date }
        merged.lastLaunched.merge(history.lastLaunched) { max($0, $1) }
        merged.seen.formUnion(history.seen)
        history = merged
        return true
    }

    // MARK: Backups

    /// How many daily backups are kept.
    static let backupLimit = 7

    /// `<layout dir>/Backups`, nil without a store.
    var backupsDirectory: URL? {
        layoutStore?.fileURL.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true)
    }

    private static func backupDayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyyMMdd"
        return f
    }

    /// Called once at launch after a successful load: keeps one dated copy per day, the last 7.
    /// The copy is of the file as loaded (before this session changes anything), so a day's backup
    /// is the state the user started that day with. Without a layout file there is nothing to keep.
    func makeLaunchBackup() {
        guard let store = layoutStore, let dir = backupsDirectory,
              FileManager.default.fileExists(atPath: store.fileURL.path) else { return }
        let dest = dir.appendingPathComponent("layout-\(Self.backupDayFormatter().string(from: now())).json")
        do {
            if !FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: store.fileURL, to: dest)
            }
        } catch {
            NSLog("%@", "MenuFold: could not back up the layout: \(error.localizedDescription)")
            return
        }
        for old in backups.dropFirst(Self.backupLimit) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    /// Saved backups, newest first (empty without a store).
    public var backups: [LayoutBackup] {
        guard let dir = backupsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        let formatter = Self.backupDayFormatter()
        return files.compactMap { name -> LayoutBackup? in
            guard name.hasPrefix("layout-"), name.hasSuffix(".json") else { return nil }
            let day = name.dropFirst("layout-".count).dropLast(".json".count)
            guard day.count == 8, let date = formatter.date(from: String(day)) else { return nil }
            return LayoutBackup(url: dir.appendingPathComponent(name), date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Replaces the layout with a backup (validated like layout.json). Undoable.
    /// The current custom icons are kept: a backup's icon file names may point at files that were
    /// deleted since, while the current ones are known to exist.
    public func restore(_ backup: LayoutBackup) throws {
        let data: Data
        do { data = try Data(contentsOf: backup.url) } catch { throw LayoutDataError.damaged }
        var restored = try LayoutStore.decodeValidated(data)
        restored.customIcons = layout.customIcons
        try replaceLayout(with: restored)
    }

    // MARK: Export / import

    /// Writes the layout and the custom icon files into one JSON file.
    public func exportLayout(to url: URL) throws {
        let data = try LayoutTransfer.make(layout: layout, iconsDirectory: iconsDirectory).encoded()
        try data.write(to: url, options: .atomic)
    }

    /// Reads a file written by `exportLayout`, validates it like layout.json and replaces the
    /// current layout (custom icons are copied into the icons folder). Undoable.
    /// The previous icon files are left on disk, so undo can map them again (see `restore` in
    /// GridModel+Arrange.swift); the next launch's cleanup removes the ones nothing uses.
    public func importLayout(from url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw LayoutDataError.notMenuFoldFile }
        let transfer = try LayoutTransfer.decode(data)
        var written: [URL] = []
        do {
            let imported = try transfer.installIcons(into: iconsDirectory, written: &written)
            try replaceLayout(with: imported)
        } catch {
            // A failed save keeps the new layout in memory (see `commitPersisting`), which still
            // needs the icons; only roll them back when the layout did not change.
            if Set(layout.customIcons.values).isDisjoint(with: written.map(\.lastPathComponent)) {
                written.forEach { try? FileManager.default.removeItem(at: $0) }
            }
            throw error
        }
    }

    /// Commits a whole new layout (undoable) and closes UI state that pointed into the old one.
    private func replaceLayout(with newLayout: Layout) throws {
        renamingFolderID = nil
        renamingCategoryID = nil
        try commitPersisting(newLayout)
        closeOpenFolderIfGone()
        validateTab()
        clearSelectionIfGone()
    }

    // MARK: Sync

    /// layout.json changed on disk behind MenuFold's back (another Mac through a synced folder):
    /// re-read it and apply it if it is valid and different.
    ///
    /// The file is read here rather than with `LayoutStore.loadWithOutcome()`, because that would
    /// quarantine a file caught half-written by the sync client: only a file that would load as
    /// `.loaded` (decodes, not from a newer version) is applied; anything else is ignored (the next
    /// notification brings the finished one) and never moved aside.
    ///
    /// Nothing is written back (`applyLayoutWithoutSaving`): a save here would echo the change to the
    /// other Macs and could overwrite a newer file that arrived meanwhile. Undo and redo are
    /// cleared, because undoing across a sync would push the stale layout back out.
    public func reloadLayoutFromDisk() {
        guard let store = layoutStore,
              let data = try? Data(contentsOf: store.fileURL),
              let reloaded = try? LayoutStore.decodeValidated(data) else { return }
        applyLayoutWithoutSaving(reloaded)
    }

    // MARK: Uninstaller

    /// Support files of the app in ~/Library (only those that unmistakably belong to its bundle id).
    /// See `AppLeftovers` for the rules.
    public func leftovers(for app: AppEntry) -> [Leftover] {
        guard canTrash(app) else { return [] }
        let others = Set(apps.map(\.id)).subtracting([app.id])
        return AppLeftovers().find(bundleID: app.id, appURL: app.url, otherBundleIDs: others)
    }

    /// `moveToTrash(_:)` plus the given leftover files (each must come from `leftovers(for:)`).
    /// The app goes first: if it cannot be trashed (running, refused), its data stays. Each leftover
    /// is checked again against a fresh `leftovers(for:)`, so no caller can trash an arbitrary URL.
    /// Leftovers that fail are collected into one `TrashError.failed`.
    public func moveToTrash(_ app: AppEntry, leftovers urls: [URL]) async throws {
        try await moveToTrash(app)
        guard !urls.isEmpty else { return }
        // Re-checked off the main actor: the lookup sizes every folder it finds.
        let others = Set(apps.map(\.id)).subtracting([app.id])
        let id = app.id, appURL = app.url
        let fresh = await Task.detached(priority: .userInitiated) {
            AppLeftovers().find(bundleID: id, appURL: appURL, otherBundleIDs: others)
        }.value
        let allowed = Set(fresh.map { $0.url.standardizedFileURL.path })
        let toTrash = urls.filter { allowed.contains($0.standardizedFileURL.path) }
        guard !toTrash.isEmpty else { return }
        isTrashing = true
        defer { isTrashing = false }
        var failures: [String] = []
        for url in toTrash {
            do {
                _ = try await NSWorkspace.shared.recycle([url])
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty { throw TrashError.failed(failures.joined(separator: "\n")) }
    }
}
