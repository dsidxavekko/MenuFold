import AppKit
import MenuFoldCore

/// App icons, cached in memory (NSCache evicts under memory pressure).
/// A user's custom icon (`GridModel.customIconURL(for:)`) wins over the app's own one.
@MainActor
final class IconCache {
    static let shared = IconCache()

    /// Bundle ID → the user's icon file, if any. Set once by `AppDelegate`; previews leave it nil.
    /// Called from view bodies, so a change of `GridModel.layout` redraws the tiles.
    var customIconURL: ((String) -> URL?)?

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 1000
    }

    func icon(for app: AppEntry) -> NSImage {
        icon(appID: app.id, url: app.url)
    }

    func icon(appID: String, url: URL) -> NSImage {
        // Custom icon files get a new name on every change, so caching by file URL never goes stale.
        if let custom = customIconURL?(appID) {
            let key = custom as NSURL
            if let cached = cache.object(forKey: key) { return cached }
            if let image = NSImage(contentsOf: custom) {
                image.size = NSSize(width: 128, height: 128)
                cache.setObject(image, forKey: key)
                return image
            }
            // A missing or broken file falls back to the app's own icon.
        }
        return icon(for: url)
    }

    func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        // Default size is 32 pt; ask for 128 pt so the best representation is picked at 64 pt tiles.
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key)
        return image
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
