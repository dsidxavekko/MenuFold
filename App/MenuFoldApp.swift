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
    }
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
