import AppKit

/// Which icon MenuFold shows in the Dock (and in Finder).
///
/// The choice is applied twice: at runtime (`NSApp.applicationIconImage`, so the running Dock tile
/// changes at once) and as a custom icon on the .app bundle itself (`NSWorkspace.setIcon`, the same
/// as Finder's "Get Info → paste icon"), so the Dock keeps it while MenuFold is closed. The bundle
/// write can be refused by macOS App Management; `select` reports that so Settings can say so.
/// An app update replaces the bundle and drops the custom icon, so launch puts it back.
enum DockIconStyle: String, CaseIterable, Identifiable {
    /// MenuFold's own logo (the bundle icon).
    case menuFold
    /// The system Applications folder icon, the same one the Dock's Applications stack shows.
    case applicationsFolder

    var id: String { rawValue }

    static let defaultsKey = "dockIcon"

    var title: String {
        switch self {
        case .menuFold: "MenuFold"
        case .applicationsFolder: "Папка «Програми»"
        }
    }

    /// Icon used both for the Dock and for the preview in Settings.
    var image: NSImage {
        switch self {
        case .menuFold:
            NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        case .applicationsFolder:
            NSWorkspace.shared.icon(forFile: Self.applicationsPath)
        }
    }

    private static var applicationsPath: String {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?.path ?? "/Applications"
    }

    static var current: DockIconStyle {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(DockIconStyle.init(rawValue:)) ?? .menuFold
    }

    /// Saves the choice and applies it right away. Returns false when the icon could not be written
    /// into the app bundle (it then changes only while MenuFold is running).
    @MainActor
    @discardableResult
    static func select(_ style: DockIconStyle) -> Bool {
        UserDefaults.standard.set(style.rawValue, forKey: defaultsKey)
        applyCurrent()
        return writeBundleIcon(style)
    }

    /// Applies the saved choice to the running Dock tile, and re-writes the bundle icon if an update
    /// removed it.
    @MainActor
    static func applyCurrent() {
        let style = current
        switch style {
        case .menuFold:
            NSApp.applicationIconImage = nil
        case .applicationsFolder:
            NSApp.applicationIconImage = style.dockImage
        }
        if style != .menuFold && !bundleHasCustomIcon {
            writeBundleIcon(style)
        }
    }

    private var dockImage: NSImage {
        let image = self.image
        image.size = NSSize(width: 512, height: 512)
        return image
    }

    /// Finder keeps a custom icon in an `Icon\r` file at the bundle root.
    private static var bundleHasCustomIcon: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundlePath + "/Icon\r")
    }

    @MainActor
    @discardableResult
    private static func writeBundleIcon(_ style: DockIconStyle) -> Bool {
        let path = Bundle.main.bundlePath
        // nil removes the custom icon, which brings back the bundle's own MenuFold logo.
        let image: NSImage? = style == .menuFold ? nil : style.dockImage
        if image == nil && !bundleHasCustomIcon { return true }
        return NSWorkspace.shared.setIcon(image, forFile: path, options: [])
    }
}
