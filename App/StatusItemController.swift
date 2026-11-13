import AppKit

/// The optional menu bar icon (`AppPreferences.showsMenuBarIcon`): a left click toggles the panel,
/// a right (or ⌃-) click shows the same menu as the Dock icon. Created and removed live when the
/// preference changes.
@MainActor
final class StatusItemController: NSObject {
    private var item: NSStatusItem?
    private let onToggle: () -> Void
    private let makeMenu: () -> NSMenu
    private var observer: NSObjectProtocol?

    static let symbolName = "square.grid.3x3.fill"

    init(onToggle: @escaping () -> Void, makeMenu: @escaping () -> NSMenu) {
        self.onToggle = onToggle
        self.makeMenu = makeMenu
        super.init()
        apply()
        observer = NotificationCenter.default.addObserver(
            forName: .menuFoldPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func apply() {
        let wanted = AppPreferences.shared.showsMenuBarIcon
        if wanted, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let image = NSImage(systemSymbolName: Self.symbolName, accessibilityDescription: "MenuFold")
                image?.isTemplate = true
                button.image = image
                button.target = self
                button.action = #selector(clicked(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                button.toolTip = "MenuFold"
            }
            self.item = item
        } else if !wanted, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu, let item {
            // `menu` is attached only for this click (a permanently attached menu would also take
            // the left click away from the toggle); `performClick` shows it in the standard place.
            item.menu = makeMenu()
            sender.performClick(nil)
            item.menu = nil
        } else {
            onToggle()
        }
    }
}
