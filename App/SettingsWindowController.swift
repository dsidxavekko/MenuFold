import AppKit
import MenuFoldCore
import SwiftUI

/// Tabs of the Settings window, in toolbar order.
enum SettingsTab: Int, CaseIterable {
    case general, categories, apps, about

    var title: String {
        switch self {
        case .general: String(localized: "Загальне")
        case .categories: String(localized: "Категорії")
        case .apps: String(localized: "Програми")
        case .about: String(localized: "Про програму")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .categories: "tag"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }

    /// Fixed content size per tab; the window resizes when the tab changes.
    var size: NSSize {
        switch self {
        case .general: NSSize(width: 520, height: Updater.isEnabled ? 680 : 530)
        case .categories: NSSize(width: 520, height: 380)
        case .apps: NSSize(width: 520, height: 460)
        case .about: NSSize(width: 520, height: CryptoWallet.visible.isEmpty ? 360 : 470 + CGFloat(CryptoWallet.visible.count) * 36)
        }
    }
}

/// The Settings window: an ordinary AppKit window with preference-style toolbar tabs.
///
/// SwiftUI's `Settings` scene cannot be opened from code any more (`showSettingsWindow:` is ignored
/// with "Please use SettingsLink"), and the Dock menu has no SwiftUI context for `openSettings`.
/// Owning the window here makes every entry point (⌘,, app menu, Dock menu) a plain method call.
@MainActor
final class SettingsWindowController {
    /// Posted whenever the Settings window becomes key: tab views are created once and cached, so
    /// their `onAppear` never fires again — views listen for this to refresh their state instead.
    static let contentDidBecomeKey = Notification.Name("menuFoldSettingsContentDidBecomeKey")

    private let model: GridModel
    private var window: NSWindow?
    private var tabs: NSTabViewController?
    private var keyObserver: NSObjectProtocol?

    init(model: GridModel) {
        self.model = model
    }

    func show(tab: SettingsTab? = nil) {
        let window = window ?? makeWindow()
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        if !window.isVisible { window.center() }
        // A Dock-menu click does not activate the app, so the window would open behind others.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let host = NSHostingController(rootView: SettingsView(model: model, tab: tab)
                .frame(width: tab.size.width, height: tab.size.height))
            host.sizingOptions = [.preferredContentSize]
            host.title = tab.title
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        // App-lifetime controller: the observer lives as long as the cached window.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NotificationCenter.default.post(name: SettingsWindowController.contentDidBecomeKey, object: nil)
            }
        }
        self.tabs = tabs
        self.window = window
        return window
    }
}
