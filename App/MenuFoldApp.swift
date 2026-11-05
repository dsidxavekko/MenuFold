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

    override init() {
        let model = GridModel(catalog: SpotlightAppCatalog(), store: LayoutStore())
        self.model = model
        self.panel = PanelController(model: model)
        super.init()
        model.onLaunched = { [weak self] in self?.panel.hide(reason: .appLaunched) }
        model.onLaunchFailed = { [weak self] app, message in self?.showLaunchFailure(app: app, message: message) }
        observeApps()
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The usual way to launch MenuFold is a click on its Dock icon, so show the panel right away.
        // (Placement falls back to screen center if the mouse is not near the Dock.)
        // A login-item launch must not pop the panel up at every login.
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

    /// Right-click on the Dock icon: Settings and About, since the panel itself has no settings button.
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
        return menu
    }

    /// Drops cached icons whenever the app list changes (an app updated in place may have a new icon).
    /// `withObservationTracking` fires once, so it is re-armed after each change.
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
