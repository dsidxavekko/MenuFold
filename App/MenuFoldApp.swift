import AppKit
import MenuFoldCore
import SwiftUI

@main
struct MenuFoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(model: appDelegate.model)
        }
        // The Settings scene exists but is otherwise reachable only through the standard ⌘, item of
        // the app menu. This puts an explicit, always-present item there so the window (login item,
        // hidden apps, reset) can be found from the menu bar like in any Mac app.
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand()
            }
        }
    }
}

/// Menu command that opens the Settings scene (⌘,). The action is `showSettingsWindow:` sent with a
/// nil target, which lands on SwiftUI's own settings handler. It replaces SwiftUI's whole
/// `appSettings` group so exactly one such item exists; `AppDelegate.installSettingsMenuItem`
/// then retitles that item into Ukrainian once the menu bar is built.
private struct SettingsMenuCommand: View {
    var body: some View {
        Button("Налаштування…") {
            SettingsMenuCommand.open()
        }
        .keyboardShortcut(",", modifiers: .command)
    }

    /// Opens Settings, or brings an already open Settings window to the front.
    static func open() {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == settingsWindowID }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // `sendAction` returns false when nothing handles it (no settings window yet on some macOS
        // versions); the ObjC spelling of the same selector is the fallback.
        let sent = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        if !sent { NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) }
    }

    /// Identifier SwiftUI gives the Settings window (stable across macOS releases).
    private static let settingsWindowID = "com_apple_SwiftUI_Settings_window"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: GridModel
    let panel: PanelController
    private var launchedAsLoginItem = false

    override init() {
        let model = GridModel(catalog: SpotlightAppCatalog(), store: LayoutStore())
        self.model = model
        self.panel = PanelController(model: model)
        super.init()
        model.onLaunched = { [weak self] in self?.panel.hide(reason: .appLaunched) }
        observeApps()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch Apple event is only current during launch, so read it here.
        launchedAsLoginItem = Self.isLoginItemLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSettingsMenuItem()
        // The usual way to launch MenuFold is a click on its Dock icon, so show the panel right away.
        // (Placement falls back to screen center if the mouse is not near the Dock.)
        // A login-item launch must not pop the panel up at every login.
        if !launchedAsLoginItem { panel.show() }
    }

    /// True when the current "open application" Apple event says we were launched as a login item.
    private static func isLoginItemLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let prop = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))
        else { return false }
        return prop.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    // MARK: Меню

    /// Replaces SwiftUI's standard "Settings…" item with an explicit Ukrainian one, so the app menu
    /// literally shows "Налаштування…" (⌘,). The `Settings` scene keeps its own machinery; only the
    /// menu item's title, image and target are ours. If the item is missing the standard one stays,
    /// so a menu-shape change in a future macOS degrades to the old behaviour instead of no item.
    private func installSettingsMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.action == Selector(("showSettingsWindow:")) || $0.action == Selector(("showPreferencesWindow:")) })
        else { return }
        // An explicit target + implemented action keeps the item enabled without menu validation.
        // The key equivalent is only claimed when nothing else already uses ⌘,: a duplicate would be a
        // silent conflict (AppKit would just pick one of the two at random).
        let commaTaken = appMenu.items.contains { $0.keyEquivalent == "," }
        let item = NSMenuItem(title: "Налаштування…", action: #selector(openSettings(_:)), keyEquivalent: commaTaken ? "" : ",")
        item.keyEquivalentModifierMask = [.command]
        item.target = self
        item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        appMenu.removeItem(at: index)
        appMenu.insertItem(item, at: index)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsMenuCommand.open()
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
