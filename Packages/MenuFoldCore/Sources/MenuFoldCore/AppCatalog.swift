import Foundation

/// Source of the app list. `onChange` fires on the main actor whenever `apps` changes,
/// and always once when the first result is delivered (even if empty); `isLoaded` is true from then on.
@MainActor
public protocol AppCatalogProviding: AnyObject {
    var apps: [AppEntry] { get }
    var isLoaded: Bool { get }
    var onChange: (([AppEntry]) -> Void)? { get set }
    func start()
    func stop()
}

/// Live catalog from Spotlight (NSMetadataQuery, kMDItemContentType == com.apple.application-bundle).
/// Filters: apps nested inside other .app bundles, duplicates by bundle ID
/// (prefer /Applications, else newest), /System/Library/CoreServices except a whitelist.
@MainActor
public final class SpotlightAppCatalog: AppCatalogProviding {
    public private(set) var apps: [AppEntry] = []
    public private(set) var isLoaded = false
    public var onChange: (([AppEntry]) -> Void)?

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var debounceTask: Task<Void, Never>?
    private var generation = 0

    public init() {}

    public func start() {
        guard query == nil else { return }
        let q = NSMetadataQuery()
        q.predicate = NSPredicate(format: "%K == %@", NSMetadataItemContentTypeKey, "com.apple.application-bundle")
        q.searchScopes = [NSMetadataQueryLocalComputerScope]
        q.notificationBatchingInterval = 0.3
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(delay: 0) }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh(delay: 0.3) }
            },
        ]
        query = q
        if !q.start() {
            NSLog("MenuFold: NSMetadataQuery failed to start")
            deliver([])
        }
    }

    public func stop() {
        query?.stop()
        query = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        debounceTask?.cancel()
        debounceTask = nil
        generation += 1
    }

    private func scheduleRefresh(delay: Double) {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }
            self?.refresh()
        }
    }

    private func refresh() {
        guard let q = query else { return }
        q.disableUpdates()
        var paths: [String] = []
        paths.reserveCapacity(q.resultCount)
        for i in 0..<q.resultCount {
            if let item = q.result(at: i) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                paths.append(path)
            }
        }
        q.enableUpdates()

        generation += 1
        let gen = generation
        Task.detached(priority: .userInitiated) {
            let entries = AppFilter.filter(paths.compactMap(BundleReader.candidate(atPath:)))
            await MainActor.run { [weak self] in
                guard let self, gen == self.generation else { return }
                self.deliver(entries)
            }
        }
    }

    /// Publishes a result. The first delivery always fires `onChange` (even if empty/unchanged).
    private func deliver(_ entries: [AppEntry]) {
        guard !isLoaded || entries != apps else { return }
        apps = entries
        isLoaded = true
        onChange?(entries)
    }
}

/// Reads Info.plist values for a bundle path (no `Bundle` cache, so updates are picked up).
enum BundleReader {
    static func candidate(atPath path: String) -> AppCandidate? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if info == nil { info = Bundle(url: url)?.infoDictionary }
        let bundleID = info?["CFBundleIdentifier"] as? String
        let category = info?["LSApplicationCategoryType"] as? String
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return AppCandidate(path: path, bundleID: bundleID, name: displayName(url: url, info: info),
                            infoCategory: category, modificationDate: mod)
    }

    static func displayName(url: URL, info: [String: Any]?) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        var localized = FileManager.default.displayName(atPath: url.path)
        if localized.lowercased().hasSuffix(".app") { localized = String(localized.dropLast(4)) }
        // FileManager returns the localized name when the bundle is localized, else the file name.
        if !localized.isEmpty, localized != fileName { return localized }
        if !fileName.isEmpty { return fileName }
        if let n = info?["CFBundleDisplayName"] as? String, !n.isEmpty { return n }
        if let n = info?["CFBundleName"] as? String, !n.isEmpty { return n }
        return url.lastPathComponent
    }
}

/// Fixed list, for previews and tests.
@MainActor
public final class StaticAppCatalog: AppCatalogProviding {
    public private(set) var apps: [AppEntry]
    public private(set) var isLoaded = false
    public var onChange: (([AppEntry]) -> Void)?
    public init(apps: [AppEntry]) { self.apps = apps }
    public func start() { isLoaded = true; onChange?(apps) }
    public func stop() {}
    public func replace(_ apps: [AppEntry]) { self.apps = apps; onChange?(apps) }
}
