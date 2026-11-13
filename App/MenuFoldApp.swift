import AppKit
import MenuFoldCore
import SwiftUI

@main
struct MenuFoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // SwiftUI needs at least one scene. Settings is an AppKit window owned by the delegate
        // (`SettingsWindowController`), because the SwiftUI Settings scene cannot be opened from code.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("Про MenuFold") { appDelegate.showSettings(tab: .about) }
                if Updater.shared.isEnabled {
                    Button("Перевірити оновлення…") { Updater.shared.checkForUpdates() }
                }
            }
            CommandGroup(replacing: .appSettings) {
                Button("Налаштування…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: GridModel
    let panel: PanelController
    private lazy var settings = SettingsWindowController(model: model)
    private var launchedAsLoginItem = false
    private var launchObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var statusItem: StatusItemController?
    private var layoutWatcher: LayoutFileWatcher?
    /// When this process started; see `isJustLaunched`.
    let launchDate = Date()
    /// Set once `applicationDidFinishLaunching` ran.
    private(set) var didFinishLaunching = false
    /// A `menufold://` URL or a Shortcuts action was handled before launch finished: it decided
    /// what the panel shows, so the default launch-time `show()` must not override it.
    var handledCommandDuringLaunch = false

    /// A Shortcuts action or URL that launched MenuFold arrives right after launch, while the launch
    /// itself has already shown the panel; a "toggle" then must show, not hide.
    static let justLaunchedInterval: TimeInterval = 2

    /// UserDefaults key of the "Часті" row switch (Settings writes it together with the model).
    static let showsFrequentKey = "showsFrequent"
    /// UserDefaults key of the "Запущені" tab switch.
    static let showsRunningTabKey = "showsRunningTab"

    override init() {
        // layout.json and Icons/ may live in a user-chosen (synced) folder; usage and history are
        // per-Mac data and always stay in the default support folder.
        let supportDir = LayoutStore.defaultURL.deletingLastPathComponent()
        let store = LayoutStore(fileURL: AppPreferences.shared.layoutFileURL)
        // A user-chosen folder may be synced with other Macs, which changes how the store treats
        // files it did not write itself (see `LayoutStore.isShared`).
        store.isShared = AppPreferences.shared.dataDirectory != nil
        let model = GridModel(
            catalog: SpotlightAppCatalog(),
            store: store,
            usageStore: UsageStore(),
            historyStore: AppHistoryStore(fileURL: supportDir.appendingPathComponent("history.json"))
        )
        Self.applyPreferences(to: model)
        model.showsFrequent = UserDefaults.standard.object(forKey: Self.showsFrequentKey) as? Bool ?? true
        model.showsRunningTab = UserDefaults.standard.object(forKey: Self.showsRunningTabKey) as? Bool ?? true
        let running = RunningAppsMonitor.shared
        model.runningAppIDs = running.bundleIDs
        running.onChange = { [weak model] ids in model?.runningAppIDs = ids }
        self.model = model
        self.panel = PanelController(model: model)
        super.init()
        IconCache.shared.customIconURL = { [weak model] id in model?.customIconURL(for: id) }
        model.onLaunched = { [weak self] in self?.panel.hide(reason: .appLaunched) }
        model.onLaunchFailed = { [weak self] app, message in self?.showLaunchFailure(app: app, message: message) }
        observeApps()
        observeLaunches()
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .menuFoldPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.applyPreferences(to: self.model)
            }
        }
    }

    /// Copies the model switches from `AppPreferences` (at launch and after every change in Settings).
    private static func applyPreferences(to model: GridModel) {
        let prefs = AppPreferences.shared
        model.keepsPanelOpenAfterLaunch = prefs.keepsPanelOpenAfterLaunch
        model.rememberLastTab = prefs.rememberLastTab
        model.showsRecentTab = prefs.showsRecentTab
        model.showsPinned = prefs.showsPinned
        // The "Часті" row fills one grid row.
        model.frequentLimit = GridMetrics.columns
    }

    /// Hotkey, menu bar icon and the layout file watch; after launch, so nothing fires before the
    /// panel exists in its final state.
    private func startIntegrations() {
        let hotKeys = HotKeyManager.shared
        hotKeys.onPress = { [weak self] in self?.panel.toggle(bypassingDockGuard: true) }
        hotKeys.start()
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.panel.toggle(bypassingDockGuard: true) },
            makeMenu: { [weak self] in self?.makeQuickMenu(includesQuit: true) ?? NSMenu() }
        )
        // Another Mac (synced data folder) or a hand edit changed layout.json: pick it up live.
        let watcher = LayoutFileWatcher(fileURL: AppPreferences.shared.layoutFileURL) { [weak self] in
            self?.model.reloadLayoutFromDisk()
        }
        watcher.start()
        layoutWatcher = watcher
    }

    /// Any app launch (Dock, Spotlight, Finder, MenuFold itself) counts towards the "Часті" row.
    /// A launch from MenuFold is reported here too; `UsageStats` ignores the duplicate.
    private func observeLaunches() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.model.recordUse(appID: id) }
        }
    }

    /// The panel is already gone when a launch fails, so without this the click would do nothing
    /// visible. The alert takes key status, which also closes the panel if it was reopened meanwhile.
    func presentLaunchFailure(app: AppEntry, message: String) {
        showLaunchFailure(app: app, message: message)
    }

    private func showLaunchFailure(app: AppEntry, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Не вдалося відкрити «\(app.name)»")
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch Apple event is only current during launch, so read it here.
        launchedAsLoginItem = Self.isLoginItemLaunch()
        // As early as possible, so the Dock does not flash the bundle icon first.
        DockIconStyle.applyCurrent()
        // Starts Sparkle's scheduled checks (release builds only).
        _ = Updater.shared
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIntegrations()
        // The usual way to launch MenuFold is a click on its Dock icon, so show the panel right away.
        // (Placement falls back to screen center if the mouse is not near the Dock.)
        // A login-item launch must not pop the panel up at every login.
        // Running straight from the mounted DMG: offer to copy MenuFold into /Applications first.
        // The offer either quits this instance after opening the copy, or — if opening failed —
        // shows the alert and this instance opens its panel as usual.
        if InstallLocation.offerMoveIfNeeded(onOpenFailed: { [weak self] in self?.panel.show() }) { return }
        didFinishLaunching = true
        if !launchedAsLoginItem, !handledCommandDuringLaunch { panel.show() }
        #if DEBUG
        // `open MenuFold.app --args -openSettings about` opens Settings on a tab, for checking it
        // without clicking through the Dock menu.
        if let name = UserDefaults.standard.string(forKey: "openSettings") {
            let tab = SettingsTab.allCases.first { "\($0)" == name } ?? .general
            showSettings(tab: tab)
        }
        #endif
    }

    /// True when the current "open application" Apple event says we were launched as a login item.
    private static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: Меню

    /// Starts a new copy of MenuFold and quits this one (after the data folder changed).
    /// The global hotkey and the file watch are released first, so the new copy can take them.
    func relaunch() {
        HotKeyManager.shared.stop()
        layoutWatcher?.stop()
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    NSLog("%@", "MenuFold: relaunch failed: \(error.localizedDescription)")
                    HotKeyManager.shared.start()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// `menufold://…` URLs (see `URLCommandHandler`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { URLCommandHandler.handle(url, delegate: self) }
    }

    func showSettings(tab: SettingsTab? = nil) {
        settings.show(tab: tab)
    }

    /// Right-click on the Dock icon: pinned and most-used apps, folders, then Settings, About and
    /// updates, since the panel itself has no settings button. See `makeQuickMenu` (AppMenus.swift).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        makeQuickMenu(includesQuit: false)
    }

    /// Drops cached icons whenever the catalog delivers: an app updated in place keeps its bundle id
    /// and name, so its list may be unchanged while the icon is new. The cache is an NSCache, so a
    /// flush costs only a re-read on the next display.
    private func observeApps() {
        withObservationTracking {
            _ = model.apps
        } onChange: { [weak self] in
            Task { @MainActor in
                IconCache.shared.removeAll()
                self?.observeApps()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.toggle()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
