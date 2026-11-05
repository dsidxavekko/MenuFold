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
            NSLog("%@", "MenuFold: NSMetadataQuery failed to start")
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
            let languages = BundleReader.systemLanguages()
            let entries = AppFilter.filter(paths.compactMap { BundleReader.candidate(atPath: $0, languages: languages) })
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
/// A path that is not a real bundle, or has no `CFBundleIdentifier`, is not an app: it yields nil,
/// so helpers and malformed bundles never reach the grid.
enum BundleReader {
    /// `languages`: the user's language list (see `systemLanguages()`); app names are localized
    /// for it, not for MenuFold's own UI language.
    static func candidate(atPath path: String, languages: [String] = systemLanguages()) -> AppCandidate? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // Fast path: the raw plist, when it is readable. A directory whose plist is missing or
        // empty is not a bundle, so do not pay for `Bundle(url:)` on it.
        var info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if info?.isEmpty ?? true { info = Bundle(url: url)?.infoDictionary }
        guard let bundleID = trimmed(info?["CFBundleIdentifier"] as? String), !bundleID.isEmpty else { return nil }
        let category = trimmed(info?["LSApplicationCategoryType"] as? String)
        // Filtering and Finder folders work on the real path; `path` is already standardized by the
        // caller, so resolving symlinks here cannot make it disagree with the display path.
        let resolved = url.resolvingSymlinksInPath().path
        let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let plain = displayName(url: url, info: info)
        let localized = localizedName(url: url, info: info, languages: languages)
        return AppCandidate(path: resolved.isEmpty ? path : resolved, bundleID: bundleID, name: localized ?? plain,
                            alternateName: localized == nil || localized == plain ? nil : plain,
                            infoCategory: category, modificationDate: mod)
    }

    /// The system-wide language list (System Settings → Language & Region). Read from the global
    /// domain, so a per-app language picked for MenuFold changes its UI but not the app names.
    static func systemLanguages() -> [String] {
        let global = CFPreferencesCopyAppValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication) as? [String]
        if let global, !global.isEmpty { return global }
        return Locale.preferredLanguages
    }

    private static let localizedNameKeys = ["CFBundleDisplayName-macos", "CFBundleDisplayName", "CFBundleName"]

    /// The bundle's name in the best of `languages` it is localized for, read from
    /// `InfoPlist.loctable` (newer Apple apps) or `<lang>.lproj/InfoPlist.strings`. nil when the best
    /// match is the bundle's development language (its Info.plist already holds that name) or the
    /// localization has no name, so the caller falls back to `displayName(url:info:)`.
    static func localizedName(url: URL, info: [String: Any]?, languages: [String]) -> String? {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        let development = trimmed(info?["CFBundleDevelopmentRegion"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "en"

        if let table = NSDictionary(contentsOf: resources.appendingPathComponent("InfoPlist.loctable")) as? [String: Any] {
            return pick(from: Array(table.keys), development: development, languages: languages) {
                table[$0] as? [String: Any]
            }
        }
        let lprojs = ((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasSuffix(".lproj") && $0 != "Base.lproj" }
            .map { String($0.dropLast(".lproj".count)) }
        guard !lprojs.isEmpty else { return nil }
        return pick(from: lprojs, development: development, languages: languages) {
            strings(at: resources.appendingPathComponent("\($0).lproj/InfoPlist.strings"))
        }
    }

    private static func pick(from localizations: [String], development: String, languages: [String],
                             table: (String) -> [String: Any]?) -> String? {
        // The development language counts as available: its names live in Info.plist itself.
        var available = localizations
        if !available.contains(development) { available.append(development) }
        guard let best = Bundle.preferredLocalizations(from: available, forPreferences: languages).first,
              best != development, let names = table(best) else { return nil }
        for key in localizedNameKeys {
            if let name = trimmed(names[key] as? String), !name.isEmpty { return name }
        }
        return nil
    }

    /// A `.strings` file in binary/XML plist or the classic `"key" = "value";` format (UTF-8 or
    /// UTF-16). `PropertyListSerialization` returns nil on a malformed file; do not use
    /// `propertyListFromStringsFileFormat()`, which raises an Objective-C exception that crashes.
    private static func strings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// `CFBundleDisplayName`, then `CFBundleName`, then the (localized) file name — the order
    /// Launchpad and System Settings use, so every list shows the same name for a bundle.
    static func displayName(url: URL, info: [String: Any]?) -> String {
        for key in ["CFBundleDisplayName", "CFBundleName"] {
            if let name = trimmed(info?[key] as? String), !name.isEmpty { return name }
        }
        var localized = FileManager.default.displayName(atPath: url.path)
        if localized.lowercased().hasSuffix(".app") { localized = String(localized.dropLast(4)) }
        if !localized.isEmpty { return localized }
        let fileName = url.deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? url.lastPathComponent : fileName
    }

    /// Trims whitespace and invisible format marks (WhatsApp's name starts with U+200E).
    private static func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: Self.trimSet)
    }

    private static let trimSet: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.insert(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}")
        return set
    }()
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
