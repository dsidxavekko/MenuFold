import AppKit
import MenuFoldCore
import Observation

/// App icons, cached in memory (NSCache evicts under memory pressure).
/// A user's custom icon (`GridModel.customIconURL(for:)`) wins over the app's own one.
///
/// `NSWorkspace.icon(forFile:)` is synchronous, so a tile never calls `icon(for:)` from `body`:
/// it draws `cachedIcon(for:)` or a placeholder, asks for `prefetch`, and re-renders when
/// `version` grows after a batch has been loaded.
@MainActor
@Observable
final class IconCache {
    static let shared = IconCache()

    /// Bundle ID → the user's icon file, if any. Set once by `AppDelegate`; previews leave it nil.
    /// Called from view bodies, so a change of `GridModel.layout` redraws the tiles.
    var customIconURL: ((String) -> URL?)?

    /// Grows after every loaded batch (and on `removeAll`). `cachedIcon` reads it, which is what
    /// makes a SwiftUI body that asked for an icon re-evaluate once the icon is in the cache.
    private(set) var version = 0

    /// Icons loaded between two yields. Small on purpose: the lookups are synchronous, so the main
    /// thread is handed back after each batch and a cold panel fills in progressively.
    private static let batchSize = 8

    // The cache and the queue are not view state: touching them must never invalidate a body.
    @ObservationIgnored private let cache = NSCache<NSURL, NSImage>()
    /// Apps waiting for their icon, in the order they asked for it.
    @ObservationIgnored private var pending: [AppEntry] = []
    /// Keys that are queued or already loaded by the drain loop, so `prefetch` never duplicates work.
    @ObservationIgnored private var pendingKeys: Set<NSURL> = []
    /// Keys that produced no image at all (deleted bundle, unreadable folder). Never retried.
    @ObservationIgnored private var failedKeys: Set<NSURL> = []
    @ObservationIgnored private var isPrefetching = false

    private init() {
        cache.countLimit = 1000
    }

    // MARK: - Cache only

    /// The icon if it is already in memory, otherwise nil. Never does any work, so a tile's `body`
    /// may call it. Reading `version` is deliberate: it subscribes the body to icon arrivals.
    func cachedIcon(for app: AppEntry) -> NSImage? {
        cachedIcon(appID: app.id, url: app.url)
    }

    /// See `cachedIcon(for:)`. Nil while a custom icon is still loading, so the tile shows the
    /// placeholder instead of flashing the app's own artwork first.
    func cachedIcon(appID: String, url: URL) -> NSImage? {
        // The observation dependency: bodies re-read the cache after each prefetch batch.
        _ = version
        if let custom = customIconURL?(appID) {
            return cache.object(forKey: custom as NSURL)
        }
        return cache.object(forKey: url as NSURL)
    }

    // MARK: - Synchronous

    /// Blocking. Only for places that need the image right now: menus, drag images, rows in
    /// Settings and the other cards. Tiles use `cachedIcon(for:)` plus `prefetch` instead.
    func icon(for app: AppEntry) -> NSImage {
        icon(appID: app.id, url: app.url)
    }

    func icon(appID: String, url: URL) -> NSImage {
        if let cached = cachedIcon(appID: appID, url: url) { return cached }
        return load(appID: appID, url: url)
    }

    func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        return load(for: url)
    }

    // MARK: - Prefetch

    /// Queues the icons of `apps` that are not cached yet and loads them in batches of
    /// `batchSize`, yielding the main thread in between. Cheap to call repeatedly: duplicates are
    /// dropped, so a tile can ask for itself from `.task` without a second thought.
    func prefetch(_ apps: [AppEntry]) {
        for app in apps {
            let key = key(appID: app.id, url: app.url)
            guard cache.object(forKey: key) == nil,
                  !pendingKeys.contains(key),
                  !failedKeys.contains(key) else { continue }
            pending.append(app)
            pendingKeys.insert(key)
        }
        // A running drain picks up whatever was appended to `pending` on its next iteration.
        guard !pending.isEmpty, !isPrefetching else { return }
        isPrefetching = true
        Task { await drainQueue() }
    }

    /// Queues everything the grid is about to draw: the apps of the visible tiles plus the mini
    /// icons of the visible folder tiles. Call it from the grid when its item list changes (see
    /// `GridView`); the per-tile `prefetch` calls are the fallback for lazily appearing tiles.
    func prefetchVisible(_ items: [MenuFoldCore.GridItem]) {
        var apps: [AppEntry] = []
        apps.reserveCapacity(items.count)
        for item in items {
            switch item {
            case .app(let app):
                apps.append(app)
            case .folder(_, let folderApps):
                // A folder tile draws at most nine mini icons (3 × 3); the rest are loaded tile by
                // tile if the folder is opened.
                apps.append(contentsOf: folderApps.prefix(9))
            }
        }
        prefetch(apps)
    }

    /// Loads the queue batch by batch, on the main actor. `NSWorkspace` icon lookups are not
    /// documented as thread-safe, so they stay on the main thread; the batches are small and each
    /// one is followed by a yield, which keeps input, scrolling and the reveal cascade responsive.
    private func drainQueue() async {
        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            pending.removeFirst(batch.count)
            for app in batch {
                let key = key(appID: app.id, url: app.url)
                if cache.object(forKey: key) == nil { load(appID: app.id, url: app.url) }
                // Nothing was produced for this key: do not put it back in the queue forever.
                if cache.object(forKey: key) == nil { failedKeys.insert(key) }
                pendingKeys.remove(key)
            }
            // Let SwiftUI, the run loop and pending input run before the next batch.
            await Task.yield()
            // Only now tell the views: they re-read the cache once per batch, not once per icon.
            version += 1
        }
        isPrefetching = false
    }

    // MARK: - Loading

    /// Cache key an icon for this app is stored under: the user's custom file (it gets a new name on
    /// every change, so the key never goes stale) or the bundle's own URL.
    private func key(appID: String, url: URL) -> NSURL {
        (customIconURL?(appID) ?? url) as NSURL
    }

    /// Resolves the icon the way `cachedIcon(appID:url:)` reads it: the user's file first, then the
    /// bundle's own icon, which is also cached under the custom key so that the two agree and a
    /// broken custom file cannot leave a tile stuck on the placeholder.
    @discardableResult
    private func load(appID: String, url: URL) -> NSImage {
        guard let custom = customIconURL?(appID) else { return load(for: url) }
        let key = custom as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        if let image = NSImage(contentsOf: custom) {
            image.size = NSSize(width: 128, height: 128)
            cache.setObject(image, forKey: key)
            return image
        }
        // A missing or broken file falls back to the app's own icon.
        let fallback = load(for: url)
        cache.setObject(fallback, forKey: key)
        return fallback
    }

    @discardableResult
    private func load(for url: URL) -> NSImage {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        // Default size is 32 pt; ask for 128 pt so the best representation is picked at 64 pt tiles.
        image.size = NSSize(width: 128, height: 128)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Drops everything, the queue included. Called when the views are unloaded (30 s after the
    /// panel closes), when the catalog changes, and after a layout reload.
    func removeAll() {
        cache.removeAllObjects()
        pending.removeAll()
        pendingKeys.removeAll()
        failedKeys.removeAll()
        version += 1
    }
}
