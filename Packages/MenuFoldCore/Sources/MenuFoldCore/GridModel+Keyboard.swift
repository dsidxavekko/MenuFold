import AppKit
import Foundation

/// Error from `GridModel.moveToTrash(_:)`.
public enum TrashError: Error, Equatable, LocalizedError {
    /// A system app (under /System) can't be moved to the Trash.
    case systemApp
    /// The app is running; quit it first.
    case running
    /// The system refused (permissions, App Store app, …), with its message.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .systemApp: return L("Системну програму не можна перемістити в Кошик.")
        case .running: return L("Спершу завершіть програму.")
        case .failed(let message): return message
        }
    }
}

// MARK: - "Часті" row

extension GridModel {
    /// Selection id of a tile in the "Часті" row: "frequent:<bundle ID>".
    public static func frequentSelectionID(_ appID: String) -> String { "frequent:" + appID }

    /// Up to `frequentLimit` visible, installed apps with the highest usage score, highest first.
    /// Empty when `showsFrequent` is off, the query is not empty, or the tab is not `.all`.
    /// Apps shown in the "Закріплені" row are left out (the next ones fill their places), so one
    /// app never appears twice above the grid.
    public var frequentApps: [AppEntry] {
        guard showsFrequent, frequentLimit > 0, tab == .all,
              query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let pinnedShown = Set(pinnedApps.map(\.id))
        let byID = Dictionary(installedVisibleApps.filter { !pinnedShown.contains($0.id) }.map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return usage.top(frequentLimit, among: Set(byID.keys), at: now()).compactMap { byID[$0] }
    }

    /// Records a use of the app (launched from MenuFold, or anywhere else) and saves the stats.
    /// Only apps in the catalog count, so helpers and agents launched elsewhere don't pile up.
    public func recordUse(appID: String) {
        guard apps.contains(where: { $0.id == appID }) else { return }
        noteLaunched(appID: appID)
        guard usage.record(appID, at: now()) else { return }
        saveUsage()
    }

    /// Forgets all usage (Settings) and saves.
    public func clearUsage() {
        guard !usage.entries.isEmpty else { return }
        usage = UsageStats()
        saveUsage()
        clearSelectionIfGone()
    }
}

// MARK: - Keyboard selection

extension GridModel {
    /// Selection ids in navigation order, per section. Folder open → one section: its apps
    /// ("app:…"). Otherwise → [the "Закріплені" row ids, the "Часті" row ids, `visibleItems` ids,
    /// the System Settings results ("pane:…", search only)].
    public var navigableSections: [[String]] {
        if let id = openFolderID, let folder = folder(id: id) {
            return [apps(in: folder).map { "app:" + $0.id }]
        }
        return [pinnedApps.map { Self.pinnedSelectionID($0.id) },
                frequentApps.map { Self.frequentSelectionID($0.id) },
                visibleItems.map(\.id),
                settingsPaneResults.map { Self.paneSelectionID($0.id) }]
    }

    /// Selection id of a tile in the "Закріплені" row: "pinned:<bundle ID>".
    public static func pinnedSelectionID(_ appID: String) -> String { "pinned:" + appID }
    /// Selection id of a System Settings result: "pane:<pane id>".
    public static func paneSelectionID(_ paneID: String) -> String { "pane:" + paneID }

    /// Moves `selectedItemID` with the arrow keys (see `GridNavigation.move`). `columns` is the
    /// column count of the grid being shown (7 for the panel, 6 inside a folder).
    public func moveSelection(_ direction: MoveDirection, columns: Int) {
        let sections = navigableSections
        let flat = sections.flatMap { $0 }
        let current = selectedItemID.flatMap { flat.firstIndex(of: $0) }
        guard let target = GridNavigation.move(from: current, sections: sections.map(\.count),
                                               columns: columns, direction: direction),
              flat.indices.contains(target) else { return }
        selectedItemID = flat[target]
    }

    /// The app under the selection (a "Часті" tile, an app tile, or an app inside the open folder);
    /// nil for a folder or no selection.
    public var selectedApp: AppEntry? {
        guard let id = selectedItemID else { return nil }
        let appID: String
        if id.hasPrefix("frequent:") {
            appID = String(id.dropFirst("frequent:".count))
        } else if id.hasPrefix("pinned:") {
            appID = String(id.dropFirst("pinned:".count))
        } else if id.hasPrefix("app:") {
            appID = String(id.dropFirst("app:".count))
        } else {
            return nil
        }
        return installedVisibleApps.first { $0.id == appID }
    }

    /// Enter: launches the selected app, opens the selected folder or System Settings pane.
    /// False when nothing is selected.
    @discardableResult
    public func activateSelection() -> Bool {
        if let app = selectedApp {
            launch(app)
            return true
        }
        if let id = selectedItemID, id.hasPrefix("folder:"),
           let uuid = UUID(uuidString: String(id.dropFirst("folder:".count))), folder(id: uuid) != nil {
            openFolderID = uuid
            return true
        }
        if let id = selectedItemID, id.hasPrefix("pane:"),
           let pane = settingsPaneResults.first(where: { Self.paneSelectionID($0.id) == id }) {
            openSettingsPane(pane)
            return true
        }
        return false
    }
}

// MARK: - Trash

extension GridModel {
    /// False for system apps (anything under /System) — the menu item and ⌘⌫ are not offered.
    public func canTrash(_ app: AppEntry) -> Bool {
        !app.url.standardizedFileURL.path.hasPrefix("/System/")
    }

    /// Moves the app bundle to the Trash with `NSWorkspace.recycle`. The layout is not changed: the
    /// catalog drops the app on its next scan, and folders keep its id as for any uninstall.
    /// Throws `TrashError.running` when the app is running (checked via NSRunningApplication).
    public func moveToTrash(_ app: AppEntry) async throws {
        guard canTrash(app) else { throw TrashError.systemApp }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty else {
            throw TrashError.running
        }
        isTrashing = true
        defer { isTrashing = false }
        do {
            _ = try await NSWorkspace.shared.recycle([app.url])
        } catch {
            throw TrashError.failed(error.localizedDescription)
        }
    }
}

// MARK: - Helpers

extension GridModel {
    /// Installed apps that are not hidden.
    fileprivate var installedVisibleApps: [AppEntry] {
        apps.filter { !layout.hidden.contains($0.id) }
    }

    fileprivate func saveUsage() {
        guard let usageStore else { return }
        do { try usageStore.save(usage) } catch {
            NSLog("%@", "MenuFold: failed to save usage stats: \(error.localizedDescription)")
        }
    }
}
