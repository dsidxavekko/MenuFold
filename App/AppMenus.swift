import AppKit
import MenuFoldCore

/// The menu shared by the Dock icon (`applicationDockMenu`) and the menu bar icon's right click:
/// pinned and most-used apps, the folders, then Settings / About / updates. Launching from it never
/// opens the panel.
extension AppDelegate {
    /// Most-used apps listed in the menu (after the pinned ones).
    static let menuMostUsedLimit = 7
    /// Size of the app icons in menus.
    static let menuIconSize = NSSize(width: 16, height: 16)

    /// Builds a fresh menu each time: the apps, folders and the update state change between opens.
    /// `includesQuit`: the menu bar icon's menu has no system "Quit" (the Dock adds its own).
    func makeQuickMenu(includesQuit: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Not `pinnedApps`: that follows the panel's tab/query and the "Закріплені" switch.
        let pinned = model.visiblePinnedApps
        if !pinned.isEmpty {
            for app in pinned { menu.addItem(appItem(app)) }
            menu.addItem(.separator())
        }

        let pinnedIDs = Set(pinned.map(\.id))
        let frequent = model.mostUsedApps(limit: Self.menuMostUsedLimit + pinned.count)
            .filter { !pinnedIDs.contains($0.id) }
            .prefix(Self.menuMostUsedLimit)
        if !frequent.isEmpty {
            for app in frequent { menu.addItem(appItem(app)) }
            menu.addItem(.separator())
        }

        let folders = model.visibleFolders
        if !folders.isEmpty {
            let foldersItem = NSMenuItem(title: String(localized: "Папки"), action: nil, keyEquivalent: "")
            foldersItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            let foldersMenu = NSMenu()
            foldersMenu.autoenablesItems = false
            for folder in folders { foldersMenu.addItem(folderItem(folder)) }
            foldersItem.submenu = foldersMenu
            menu.addItem(foldersItem)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: String(localized: "Налаштування…"), action: #selector(menuOpenSettings(_:)), keyEquivalent: "")
        settings.target = self
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settings)
        let about = NSMenuItem(title: String(localized: "Про MenuFold"), action: #selector(menuOpenAbout(_:)), keyEquivalent: "")
        about.target = self
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)
        if Updater.shared.isEnabled {
            menu.addItem(updateItem())
        }
        if includesQuit {
            menu.addItem(.separator())
            let quit = NSMenuItem(title: String(localized: "Завершити MenuFold"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            quit.target = NSApp
            menu.addItem(quit)
        }
        return menu
    }

    /// "Перевірити оновлення…", or — once Sparkle found one — "Встановити оновлення 1.2…" with an
    /// accent-coloured symbol. Both open Sparkle's window, which offers the found update.
    private func updateItem() -> NSMenuItem {
        let item: NSMenuItem
        if let version = Updater.shared.availableUpdateVersion {
            item = NSMenuItem(title: String(localized: "Встановити оновлення \(version)…"),
                              action: #selector(menuCheckForUpdates(_:)), keyEquivalent: "")
            let config = NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor])
            let image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = false
            item.image = image
        } else {
            item = NSMenuItem(title: String(localized: "Перевірити оновлення…"),
                              action: #selector(menuCheckForUpdates(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        }
        item.target = self
        return item
    }

    private func appItem(_ app: AppEntry) -> NSMenuItem {
        let item = NSMenuItem(title: app.name, action: #selector(menuLaunchApp(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = app
        item.image = menuIcon(for: app)
        return item
    }

    private func folderItem(_ folder: Folder) -> NSMenuItem {
        let item = NSMenuItem(title: folder.name, action: nil, keyEquivalent: "")
        item.image = folderMenuIcon(folder)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for app in model.apps(in: folder) { submenu.addItem(appItem(app)) }
        submenu.addItem(.separator())
        let openAll = NSMenuItem(title: String(localized: "Відкрити всі"), action: #selector(menuLaunchFolder(_:)), keyEquivalent: "")
        openAll.target = self
        openAll.representedObject = folder
        openAll.image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil)
        submenu.addItem(openAll)
        item.submenu = submenu
        return item
    }

    /// The folder's icon for a menu: its emoji drawn as an image, or its SF Symbol in the folder
    /// colour (falling back to a plain folder).
    private func folderMenuIcon(_ folder: Folder) -> NSImage? {
        let symbol = folder.symbol ?? "folder.fill"
        if let emoji = FolderSymbols.emoji(in: symbol) {
            return Self.emojiImage(emoji, size: Self.menuIconSize)
        }
        let config = NSImage.SymbolConfiguration(paletteColors: [folder.color.nsColor])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
        image?.isTemplate = false
        return image
    }

    /// An emoji rendered into an image of `size` (menus take only images, and
    /// `NSImage(systemSymbolName:)` knows nothing about emoji). Drawn on demand, so it stays sharp
    /// on any display scale.
    static func emojiImage(_ emoji: String, size: NSSize) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: rect.height * 0.8)
            let text = NSAttributedString(string: emoji, attributes: [.font: font])
            let bounds = text.size()
            text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// A 16 pt copy: the cached image is shared with the grid (128 pt), so it must not be resized.
    private func menuIcon(for app: AppEntry) -> NSImage? {
        let image = IconCache.shared.icon(for: app).copy() as? NSImage
        image?.size = Self.menuIconSize
        return image
    }

    // MARK: Actions

    /// Launches and activates the app, without opening the panel. Not `GridModel.launch`: in
    /// keep-open mode that launches in the background, which a menu pick must not do.
    @objc func menuLaunchApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? AppEntry else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config) { [weak self] _, error in
            guard let error else { return }
            let message = error.localizedDescription
            NSLog("%@", "MenuFold: failed to launch \(app.url.path) from the menu: \(message)")
            Task { @MainActor in self?.presentLaunchFailure(app: app, message: message) }
        }
        model.markSeen(app.id)
    }

    @objc func menuLaunchFolder(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? Folder else { return }
        model.launchAll(in: folder)
    }

    @objc func menuOpenSettings(_ sender: Any?) {
        showSettings()
    }

    @objc func menuOpenAbout(_ sender: Any?) {
        showSettings(tab: .about)
    }

    @objc func menuCheckForUpdates(_ sender: Any?) {
        Updater.shared.checkForUpdates()
    }
}
