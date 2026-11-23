import AppKit
import MenuFoldCore
import UniformTypeIdentifiers

/// "Експортувати діагностику…": one JSON file the user can attach to a bug report.
///
/// MenuFold is installed outside the App Store and is not notarized, so there is no crash reporting
/// and no telemetry to fall back on: without a file like this "the panel is empty" or "all my
/// folders are gone" cannot be checked at all.
///
/// The report is made of aggregates only — counts, switches, enum case names — so it is safe to
/// publish in a public issue: no app names, no bundle IDs, no paths of the user's own, no clipboard
/// contents, no layout.json contents.
@MainActor
enum DiagnosticsExport {

    // MARK: Entry points

    /// The report as pretty-printed JSON. `now` is injectable so the format can be checked in tests.
    static func makeReport(model: GridModel, now: Date = Date()) -> String {
        String(decoding: reportData(model: model, now: now), as: UTF8.self)
    }

    /// Asks where to save the report and writes it there. Returns the written file, or nil when the
    /// user cancelled or the write failed (the alert is shown here: a menu pick has nowhere else to
    /// report an error).
    @discardableResult
    static func write(model: GridModel) -> URL? {
        let now = Date()
        let panel = NSSavePanel()
        panel.title = String(localized: "Експортувати діагностику")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = fileName(for: now)
        panel.canCreateDirectories = true
        // The menu is opened from the Dock or the menu bar while another app is frontmost, and the
        // save panel of a background app would come up behind it.
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            // The report is built after the panel closes: the user may have left it open for a
            // while, and the state at saving time is the one worth reporting. Atomic, so a report
            // that failed halfway is never sent as an attachment.
            try reportData(model: model, now: now).write(to: url, options: .atomic)
        } catch {
            presentSaveFailure(error)
            return nil
        }
        return url
    }

    // MARK: Report

    private static func reportData(model: GridModel, now: Date) -> Data {
        let object: [String: Any] = [
            "generatedAt": isoDate(now),
            "app": appInfo(),
            "system": systemInfo(),
            "preferences": preferencesInfo(model),
            "catalog": catalogInfo(model),
            "layout": layoutInfo(model),
            "counters": countersInfo(model),
        ]
        // Sorted keys keep two reports of the same state diffable.
        let data = try? JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Every value above is JSON-safe, so this is a guard against a future edit that adds an
        // unsupported type: the file then still says why it holds nothing.
        return data ?? Data(#"{"reportFailed":true}"#.utf8)
    }

    private static func appInfo() -> [String: Any] {
        let info = Bundle.main.infoDictionary
        return [
            "version": info?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": info?["CFBundleVersion"] as? String ?? "unknown",
        ]
    }

    /// What the report is read against: an older macOS or a stale Intel build explains behaviour no
    /// amount of layout state does. Accessibility flags are here because MenuFold draws differently
    /// under them, and because "the animation is missing" is usually the system switch, not a bug.
    private static func systemInfo() -> [String: Any] {
        let version = systemVersion()
        let workspace = NSWorkspace.shared
        return [
            "macOSVersion": version.product,
            "macOSBuild": version.build,
            "architecture": architecture,
            "displays": NSScreen.screens.count,
            "systemLanguage": Locale.preferredLanguages.first ?? "unknown",
            // The language MenuFold itself runs in: the catalog falls back to English, so this can
            // differ from the system one.
            "appLanguage": Bundle.main.preferredLocalizations.first ?? "unknown",
            "region": Locale.current.region?.identifier ?? "unknown",
            "appearance": NSApp?.effectiveAppearance.name.rawValue ?? "unknown",
            "reduceMotion": workspace.accessibilityDisplayShouldReduceMotion,
            "increaseContrast": workspace.accessibilityDisplayShouldIncreaseContrast,
            "reduceTransparency": workspace.accessibilityDisplayShouldReduceTransparency,
            "differentiateWithoutColor": workspace.accessibilityDisplayShouldDifferentiateWithoutColor,
        ]
    }

    /// Only the switches that change what the panel shows or how it reacts: a report about odd
    /// behaviour is very often explained by one of them being in an unexpected state.
    private static func preferencesInfo(_ model: GridModel) -> [String: Any] {
        let prefs = AppPreferences.shared
        return [
            "columns": prefs.columns,
            "rows": prefs.rows,
            "effectiveColumns": prefs.effectiveColumns,
            "effectiveRows": prefs.effectiveRows,
            // A grid smaller than the chosen one means the screen was too small for it.
            "gridReducedToFitScreen": prefs.effectiveColumns != prefs.columns || prefs.effectiveRows != prefs.rows,
            // These two live in UserDefaults and are mirrored by the model, so the model is read.
            "showsFrequent": model.showsFrequent,
            "showsRunningTab": model.showsRunningTab,
            "showsRecentTab": prefs.showsRecentTab,
            "showsClipboardTab": prefs.showsClipboardTab,
            "showsPinned": prefs.showsPinned,
            "showsFolderCounts": prefs.showsFolderCounts,
            "showsNewAppDots": prefs.showsNewAppDots,
            "showsMenuBarIcon": prefs.showsMenuBarIcon,
            "keepsPanelOpenAfterLaunch": prefs.keepsPanelOpenAfterLaunch,
            "rememberLastTab": prefs.rememberLastTab,
            "usesGestures": prefs.usesGestures,
            "forcesReduceMotion": prefs.forcesReduceMotion,
            "forcesIncreaseContrast": prefs.forcesIncreaseContrast,
            "checksForAppUpdates": prefs.checksForAppUpdates,
            "panelScreenPolicy": prefs.panelScreenPolicy.rawValue,
            // A shortcut that another app took is a common report; the combination itself is not
            // private and the key code says whether the recording went wrong.
            "hotKey": prefs.hotKey?.displayString ?? "none",
            // The folder itself is a path of the user's, so only which kind it is.
            "dataDirectory": prefs.dataDirectory == nil ? "(типово)" : "(своя тека)",
        ]
    }

    private static func catalogInfo(_ model: GridModel) -> [String: Any] {
        return [
            // False means the Spotlight scan has not delivered yet: an empty grid then is expected.
            "isLoaded": model.isLoaded,
            "apps": model.apps.count,
            "visibleApps": model.visibleApps.count,
            "hiddenApps": model.layout.hidden.count,
            "manualFolders": model.layout.folders.count,
            // Synthesized from the folders on disk, so only the ones with visible apps are here.
            "finderFolders": model.visibleFolders.filter(\.isFinder).count,
            "ignoredFinderFolders": model.layout.ignoredFinderFolders.count,
            "customCategories": model.layout.customCategories.count,
            "categoryOverrides": model.layout.categoryOverrides.count,
            "smartRules": model.layout.smartRules.count,
            "profiles": model.layout.profiles.count,
            "customIcons": model.layout.customIcons.count,
        ]
    }

    /// The layout file as this session found it. Both the raw outcome and the derived `LayoutHealth`
    /// are reported: the health also covers a quarantine that failed, which is invisible otherwise.
    private static func layoutInfo(_ model: GridModel) -> [String: Any] {
        var result: [String: Any] = [
            "loadOutcome": outcomeName(model.layoutOutcome),
            "health": healthName(LayoutHealth.current(model: model)),
            "quarantineFailedInPlace": model.quarantineFailedInPlace,
            "version": model.layout.version,
            "currentVersion": Layout.currentVersion,
            // Daily copies: none means the launch backup could not be made (permissions, a read-only
            // synced folder), which a missing-folder report should be read against.
            "backups": model.backups.count,
        ]
        if let newest = model.backups.first { result["newestBackup"] = isoDate(newest.date) }
        // Absent on a first launch (no file yet), which is not an error by itself.
        if let url = model.layoutFileURL, let size = fileSize(of: url) { result["fileSizeBytes"] = size }
        return result
    }

    private static func countersInfo(_ model: GridModel) -> [String: Any] {
        return [
            // Kept for uninstalled apps, and the row is hidden on most tabs, so stored and shown
            // differ; each number explains a different report.
            "pinnedStored": model.layout.pinned.count,
            "pinnedShown": model.visiblePinnedApps.count,
            // The row as the panel would draw it on "Все" right now (empty on another tab).
            "frequent": model.frequentApps.count,
            "frequentLimit": model.frequentLimit,
            "usageTracked": model.usage.entries.count,
            "running": model.runningAppIDs.count,
            // The history itself is never part of the report, only its size: it holds secrets.
            "clipboard": [
                "enabled": model.showsClipboardTab,
                "entries": model.clipboard.entries.count,
                "pinned": model.clipboard.entries.filter(\.isPinned).count,
                "limit": model.clipboard.limit,
            ],
        ]
    }

    // MARK: Values

    /// `LoadOutcome`'s case only: the URL it carries is a path of the user's.
    private static func outcomeName(_ outcome: LoadOutcome) -> String {
        switch outcome {
        case .loaded: return "loaded"
        case .missing: return "missing"
        case .quarantined: return "quarantined"
        case .incompatible: return "incompatible"
        case .unreadable: return "unreadable"
        }
    }

    private static func healthName(_ health: LayoutHealth) -> String {
        switch health {
        case .ok: return "ok"
        case .quarantined: return "quarantined"
        case .quarantineFailedInPlace: return "quarantineFailedInPlace"
        case .unreadable: return "unreadable"
        case .incompatible: return "incompatible"
        }
    }

    /// The architecture this copy runs as: a stale Intel build started on Apple silicon draws and
    /// behaves differently, so the report has to tell them apart.
    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Version and build of macOS. `ProcessInfo.operatingSystemVersionString` is meant for display
    /// ("Version 26.0 (Build 25A354)"), so the build comes from the plist that holds it as data.
    private static func systemVersion() -> (product: String, build: String) {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        if let data = try? Data(contentsOf: url),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
           let product = plist["ProductVersion"] as? String {
            return (product, plist["ProductBuildVersion"] as? String ?? "unknown")
        }
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)", "unknown")
    }

    private static func fileSize(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// UTC, so a report from another time zone still lines up with the file's name.
    private static func isoDate(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// "MenuFold-діагностика-2026-05-01.json": the local date, so the report of the day the bug
    /// happened can be found in a folder of several.
    private static func fileName(for date: Date) -> String {
        "MenuFold-діагностика-\(dayFormatter.string(from: date)).json"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    // MARK: Failure

    /// Same shape as the launch-failure alert: the menu pick is already over, so an alert is the only
    /// place where the user learns that nothing was written.
    private static func presentSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Не вдалося зберегти діагностику: \(error.localizedDescription)")
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
