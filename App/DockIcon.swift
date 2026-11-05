import AppKit
import MenuFoldCore

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
    /// The icon of macOS's own app launcher (Apps.app, formerly Launchpad).
    case appsLauncher
    /// The system Applications folder icon, the same one the Dock's Applications stack shows.
    case applicationsFolder
    /// A picture the user chose, stored as `customImageURL`.
    case custom

    var id: String { rawValue }

    static let defaultsKey = "dockIcon"

    var title: String {
        switch self {
        case .menuFold: "MenuFold"
        case .appsLauncher: String(localized: "Лаунчер macOS")
        case .applicationsFolder: String(localized: "Папка «Програми»")
        case .custom: String(localized: "Свій")
        }
    }

    /// Icon used both for the Dock and for the preview in Settings.
    var image: NSImage {
        switch self {
        case .menuFold:
            NSImage(named: "AppIcon") ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        case .appsLauncher:
            NSWorkspace.shared.icon(forFile: Self.launcherPath)
        case .applicationsFolder:
            NSWorkspace.shared.icon(forFile: Self.applicationsPath)
        case .custom:
            Self.customImage
                ?? NSImage(systemSymbolName: "plus.square.dashed", accessibilityDescription: nil)
                ?? NSImage()
        }
    }

    /// Choices offered in Settings: the launcher only when this macOS has it.
    static var available: [DockIconStyle] {
        allCases.filter { $0 != .appsLauncher || FileManager.default.fileExists(atPath: launcherPath) }
    }

    private static var launcherPath: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.apps.launcher")?.path
            ?? "/System/Applications/Apps.app"
    }

    /// The user's own Dock icon: `DockIcon.png` next to layout.json (not in the app icons folder,
    /// whose unused files GridModel deletes).
    static var customImageURL: URL {
        LayoutStore.defaultURL.deletingLastPathComponent().appendingPathComponent("DockIcon.png")
    }

    static var hasCustomImage: Bool { FileManager.default.fileExists(atPath: customImageURL.path) }

    /// Read fresh every time (no `NSImage(named:)` cache), so a replaced file shows at once.
    private static var customImage: NSImage? {
        hasCustomImage ? NSImage(contentsOf: customImageURL) : nil
    }

    /// Stores `source` as the custom Dock icon and selects it. Returns false when the bundle icon
    /// could not be written (see `select`); throws when the file is not a usable image.
    @MainActor
    static func setCustomImage(from source: URL) throws -> Bool {
        let data = try CustomIcons.pngData(from: source)
        try FileManager.default.createDirectory(at: customImageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: customImageURL, options: .atomic)
        return select(.custom)
    }

    private static var applicationsPath: String {
        FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first?.path ?? "/Applications"
    }

    /// The saved choice; a custom one whose file is gone, or a launcher this macOS lacks, falls
    /// back to the MenuFold logo.
    static var current: DockIconStyle {
        let saved = UserDefaults.standard.string(forKey: defaultsKey).flatMap(DockIconStyle.init(rawValue:)) ?? .menuFold
        if saved == .custom && !hasCustomImage { return .menuFold }
        return available.contains(saved) ? saved : .menuFold
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
        case .appsLauncher, .applicationsFolder, .custom:
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
