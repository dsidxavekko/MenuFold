import Foundation

/// Where an app came from. Detected off the main thread by `BundleReader` / `SpotlightAppCatalog`.
public enum AppInstallSource: String, Codable, CaseIterable, Sendable {
    case appStore, homebrew, setapp
}

/// A rule-made category ("smart category"). An app joins it when it meets EVERY criterion that is
/// set (at least one must be). It is shown as a dynamic tab, only while it has apps.
///
/// Priority: a manual `Layout.categoryOverrides` entry always wins; otherwise the first rule (in
/// `Layout.smartRules` order) that matches decides the app's category, before the automatic one.
public struct SmartRule: Identifiable, Codable, Hashable, Sendable {
    /// Always starts with `AppCategory.smartPrefix`.
    public let id: String
    public var name: String
    /// Vendor prefixes of the bundle ID ("com.adobe."), any of them; compared case-insensitively.
    public var bundlePrefixes: [String]
    public var source: AppInstallSource?
    /// The app bundle is at least this many megabytes.
    public var minSizeMB: Int?
    /// Not launched for at least this many days (`AppHistory.lastLaunched`, else Spotlight's date).
    /// An app with no known launch date does not match.
    public var unusedDays: Int?

    public init(id: String = AppCategory.smartPrefix + UUID().uuidString, name: String, bundlePrefixes: [String] = [],
                source: AppInstallSource? = nil, minSizeMB: Int? = nil, unusedDays: Int? = nil) {
        self.id = id
        self.name = name
        self.bundlePrefixes = bundlePrefixes
        self.source = source
        self.minSizeMB = minSizeMB
        self.unusedDays = unusedDays
    }

    private enum CodingKeys: String, CodingKey { case id, name, bundlePrefixes, source, minSizeMB, unusedDays }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        bundlePrefixes = try c.decodeIfPresent([String].self, forKey: .bundlePrefixes) ?? []
        source = try c.decodeIfPresent(AppInstallSource.self, forKey: .source)
        minSizeMB = try c.decodeIfPresent(Int.self, forKey: .minSizeMB)
        unusedDays = try c.decodeIfPresent(Int.self, forKey: .unusedDays)
    }

    public var category: AppCategory { AppCategory(id: id, displayName: name) }

    /// The prefixes without blanks.
    var cleanPrefixes: [String] {
        bundlePrefixes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }

    /// A rule without any criterion would match every app, so it is not valid.
    public var hasCriteria: Bool {
        !cleanPrefixes.isEmpty || source != nil || (minSizeMB ?? 0) > 0 || (unusedDays ?? 0) > 0
    }

    /// Pure matching. `size` and `lastLaunch` are nil when unknown (then that criterion fails).
    public func matches(_ app: AppEntry, size: Int64?, lastLaunch: Date?, now: Date) -> Bool {
        guard hasCriteria else { return false }
        let prefixes = cleanPrefixes
        if !prefixes.isEmpty {
            let id = app.id.lowercased()
            guard prefixes.contains(where: { id.hasPrefix($0) }) else { return false }
        }
        if let source, app.installSource != source { return false }
        if let mb = minSizeMB, mb > 0 {
            guard let size, size >= Int64(mb) * 1_000_000 else { return false }
        }
        if let days = unusedDays, days > 0 {
            guard let lastLaunch, now.timeIntervalSince(lastLaunch) >= Double(days) * 86_400 else { return false }
        }
        return true
    }
}

extension AppCategory {
    /// Prefix of the ids of rule-made categories (`SmartRule.id`).
    public static let smartPrefix = "smart."
    public var isSmart: Bool { id.hasPrefix(Self.smartPrefix) }
}

/// Bundle size on disk, computed off the main thread (a recursive walk).
enum AppSizer {
    static func size(of url: URL) -> Int64? {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey], options: []) else { return nil }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

extension GridModel {
    /// The user's smart rules, in priority order.
    public var smartRules: [SmartRule] { layout.smartRules }

    /// Smart categories that have at least one visible app now (what the tabs show), in rule order.
    public var smartCategories: [AppCategory] {
        let present = Set(visibleApps.compactMap { smartCategory(for: $0)?.id })
        return layout.smartRules.filter { present.contains($0.id) }.map(\.category)
    }

    /// The category of the first matching rule, ignoring manual overrides (the caller checks them).
    func smartCategory(for app: AppEntry) -> AppCategory? {
        guard !layout.smartRules.isEmpty else { return nil }
        let size = appSizes[app.id]
        let last = history.lastLaunched[app.id] ?? app.lastUsedDate
        let date = now()
        return layout.smartRules.first { $0.matches(app, size: size, lastLaunch: last, now: date) }?.category
    }

    /// Visible apps the rule claims right now (for Settings), alphabetical.
    public func apps(matching rule: SmartRule) -> [AppEntry] {
        Self.sorted(visibleApps.filter { category(of: $0).id == rule.id })
    }

    /// Adds a rule (ignored without criteria or a name). A name already used gets a number.
    @discardableResult
    public func addSmartRule(_ rule: SmartRule) -> SmartRule? {
        var rule = rule
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.hasCriteria, !rule.name.isEmpty else { return nil }
        if !rule.id.hasPrefix(AppCategory.smartPrefix) || layout.smartRules.contains(where: { $0.id == rule.id }) {
            rule = SmartRule(name: rule.name, bundlePrefixes: rule.bundlePrefixes, source: rule.source,
                             minSizeMB: rule.minSizeMB, unusedDays: rule.unusedDays)
        }
        let taken = Set(layout.smartRules.map { $0.name.lowercased() })
        let base = rule.name
        var n = 2
        while taken.contains(rule.name.lowercased()) { rule.name = "\(base) \(n)"; n += 1 }
        var l = layout
        l.smartRules.append(rule)
        commit(l)
        refreshAppSizes()
        return rule
    }

    /// Replaces a rule with the same id (ignored without criteria or a name, or when unknown).
    public func updateSmartRule(_ rule: SmartRule) {
        var rule = rule
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.hasCriteria, !rule.name.isEmpty,
              let idx = layout.smartRules.firstIndex(where: { $0.id == rule.id }) else { return }
        var l = layout
        l.smartRules[idx] = rule
        commit(l)
        refreshAppSizes()
    }

    public func deleteSmartRule(id: String) {
        guard layout.smartRules.contains(where: { $0.id == id }) else { return }
        var l = layout
        l.smartRules.removeAll { $0.id == id }
        l.categoryOrder.removeAll { $0 == id }
        commit(l)
    }

    /// Moves a rule one step in priority (-1 earlier, +1 later).
    public func moveSmartRule(id: String, by offset: Int) {
        guard let from = layout.smartRules.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard offset != 0, layout.smartRules.indices.contains(to) else { return }
        var l = layout
        l.smartRules.swapAt(from, to)
        commit(l)
    }

    /// Measures the bundles of apps whose size is not known yet (or whose bundle changed since it
    /// was measured), off the main actor, when a rule needs sizes. Sizes are cached per path and
    /// bundle modification date for the session.
    func refreshAppSizes() {
        guard layout.smartRules.contains(where: { ($0.minSizeMB ?? 0) > 0 }) else { return }
        let items = apps.map { ($0.url.path, $0.url) }
        let cache = sizeCache
        let provider = sizeProvider
        let dateOf = modificationDateProvider
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { () -> [String: CachedAppSize] in
                var found: [String: CachedAppSize] = [:]
                for (path, url) in items {
                    let date = dateOf(url)
                    if let c = cache[path], c.modified == date { continue }
                    if let s = provider(url) { found[path] = CachedAppSize(size: s, modified: date) }
                }
                return found
            }.value
            guard let self else { return }
            for (p, s) in result { self.sizeCache[p] = s }
            self.applyCachedSizes()
        }
    }

    private func applyCachedSizes() {
        var sizes: [String: Int64] = [:]
        for app in apps { if let s = sizeCache[app.url.path] { sizes[app.id] = s.size } }
        if sizes != appSizes { appSizes = sizes }
    }
}

struct CachedAppSize: Sendable, Equatable {
    var size: Int64
    var modified: Date?
}

extension Layout {
    /// Smart rules that can work: a `smart.` id, a name, a criterion; the first of a repeated id wins.
    func validSmartRules() -> [SmartRule] {
        var seen = Set<String>()
        return smartRules.filter {
            $0.id.hasPrefix(AppCategory.smartPrefix) && $0.id.count > AppCategory.smartPrefix.count
                && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.hasCriteria && seen.insert($0.id).inserted
        }
    }
}
