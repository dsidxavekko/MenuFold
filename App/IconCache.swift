import AppKit

/// App icons by file URL, cached in memory (NSCache evicts under memory pressure).
@MainActor
final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSURL, NSImage>()

    private init() {
        cache.countLimit = 1000
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
