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

    /// UserDefaults key of the "Часті" row switch (Settings writes it together with the model).
    static let showsFrequentKey = "showsFrequent"
    /// UserDefaults key of the "Запущені" tab switch.
    static let showsRunningTabKey = "showsRunningTab"

    override init() {
        let model = GridModel(catalog: SpotlightAppCatalog(), store: LayoutStore(), usageStore: UsageStore())
        model.frequentLimit = GridMetrics.columns
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
        // The usual way to launch MenuFold is a click on its Dock icon, so show the panel right away.
        // (Placement falls back to screen center if the mouse is not near the Dock.)
        // A login-item launch must not pop the panel up at every login.
        // Running straight from the mounted DMG: offer to copy MenuFold into /Applications first.
        // The offer either quits this instance after opening the copy, or — if opening failed —
        // shows the alert and this instance opens its panel as usual.
        if InstallLocation.offerMoveIfNeeded(onOpenFailed: { [weak self] in self?.panel.show() }) { return }
        if !launchedAsLoginItem { panel.show() }
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

    func showSettings(tab: SettingsTab? = nil) {
        settings.show(tab: tab)
    }

    @objc private func openSettings(_ sender: Any?) {
        showSettings()
    }

    @objc private func openAbout(_ sender: Any?) {
        showSettings(tab: .about)
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }

    /// Right-click on the Dock icon: Settings, About and the update check, since the panel itself has no settings button.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let settings = NSMenuItem(title: String(localized: "Налаштування…"), action: #selector(openSettings(_:)), keyEquivalent: "")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        let about = NSMenuItem(title: String(localized: "Про MenuFold"), action: #selector(openAbout(_:)), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(settings)
        menu.addItem(about)
        if Updater.shared.isEnabled {
            let update = NSMenuItem(title: String(localized: "Перевірити оновлення…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            menu.addItem(update)
        }
        return menu
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
