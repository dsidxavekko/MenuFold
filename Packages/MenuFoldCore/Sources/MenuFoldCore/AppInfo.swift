import Foundation

/// Facts about one installed app for the ⌘I card: bundle details read from disk plus MenuFold's own
/// history (first seen, last launch, launch count).
public struct AppInfo: Equatable, Sendable {
    /// Where the app came from, judged from files next to the bundle.
    public enum Source: String, Equatable, Sendable {
        case appStore, homebrew, setapp, system, other

        public var title: String {
            switch self {
            case .appStore: return "App Store"
            case .homebrew: return "Homebrew"
            case .setapp: return "Setapp"
            case .system: return L("Система")
            case .other: return L("Інше")
            }
        }
    }

    public var id: String
    public var name: String
    public var version: String?
    public var build: String?
    /// Size of the bundle on disk in bytes; nil when it could not be measured.
    public var sizeBytes: Int64?
    /// Creation date of the bundle (when it was installed or last replaced).
    public var installedDate: Date?
    public var path: String
    public var source: Source
    public var firstSeen: Date?
    public var lastLaunched: Date?
    /// Launches seen by MenuFold; nil when none were counted yet.
    public var launchCount: Int?

    /// Reads the bundle at `app.url`. Touches the disk (the size walk can take a while on a big
    /// app), so call it off the main actor.
    public static func read(app: AppEntry, firstSeen: Date? = nil, lastLaunched: Date? = nil,
                            launchCount: Int? = nil) -> AppInfo {
        let fm = FileManager.default
        let url = app.url
        let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return AppInfo(
            id: app.id, name: app.name,
            version: (plist?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            build: (plist?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            sizeBytes: directorySize(url),
            installedDate: attrs?[.creationDate] as? Date,
            path: url.path,
            source: detectSource(of: app),
            firstSeen: firstSeen.flatMap { $0 == .distantPast ? nil : $0 },
            lastLaunched: lastLaunched ?? app.lastUsedDate,
            launchCount: launchCount)
    }

    /// Mac App Store (a `_MASReceipt` inside the bundle), Setapp (under a Setapp folder), Homebrew
    /// (a symlink into a Caskroom, or a Caskroom folder named like the app), system apps, or other.
    public static func detectSource(of app: AppEntry) -> Source {
        let fm = FileManager.default
        let url = app.url
        let path = url.path
        if path.hasPrefix("/System/") { return .system }
        if path.contains("/Setapp/") { return .setapp }
        if fm.fileExists(atPath: url.appendingPathComponent("Contents/_MASReceipt").path)
            || app.appStoreID != nil { return .appStore }
        let resolved = url.resolvingSymlinksInPath().path
        if resolved.contains("/Caskroom/") { return .homebrew }
        let token = app.url.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        for root in ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]
        where fm.fileExists(atPath: root + "/" + token) { return .homebrew }
        return .other
    }

    /// Total allocated size of everything under `url`, not following symlinks.
    static func directorySize(_ url: URL) -> Int64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true }) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

extension GridModel {
    /// Info for the ⌘I card. The bundle is read off the main actor; nil when the app is not in the
    /// catalog. History is copied first, so nothing main-actor crosses over.
    public func appInfo(for appID: String) async -> AppInfo? {
        guard let app = apps.first(where: { $0.id == appID }) else { return nil }
        let first = history.firstSeen[appID]
        let last = history.lastLaunched[appID]
        let count = history.launchCounts[appID]
        return await Task.detached(priority: .userInitiated) {
            AppInfo.read(app: app, firstSeen: first, lastLaunched: last, launchCount: count)
        }.value
    }
}
