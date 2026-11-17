import Foundation

/// Where an available update comes from (and so what the user can do about it).
public enum AppUpdateKind: String, Codable, Sendable {
    case homebrew, appStore, sparkle
}

/// A newer version of an installed app, found by `AppUpdateChecker`. Never installs anything.
public struct AvailableUpdate: Equatable, Sendable {
    public var appID: String
    public var kind: AppUpdateKind
    public var installedVersion: String?
    public var newVersion: String
    /// Homebrew cask token (`.homebrew`).
    public var caskToken: String?
    /// Mac App Store page (`.appStore`), `macappstore://` scheme.
    public var storeURL: URL?

    public init(appID: String, kind: AppUpdateKind, installedVersion: String? = nil, newVersion: String,
                caskToken: String? = nil, storeURL: URL? = nil) {
        self.appID = appID
        self.kind = kind
        self.installedVersion = installedVersion
        self.newVersion = newVersion
        self.caskToken = caskToken
        self.storeURL = storeURL
    }

    /// `brew upgrade --cask <token>` for a Homebrew update with a safe token; nil otherwise.
    public var brewCommand: String? {
        guard kind == .homebrew, let token = caskToken, AppUpdateParsing.isSafeCaskToken(token) else { return nil }
        return "brew upgrade --cask \(token)"
    }
}

/// What the checker needs to know about one installed app (read off the main actor).
public struct AppUpdateCandidate: Equatable, Sendable {
    public var id: String
    public var installSource: AppInstallSource?
    public var shortVersion: String?
    public var build: String?
    public var appStoreID: String?
    /// `SUFeedURL` from Info.plist.
    public var feedURL: URL?
    /// Homebrew cask token owning this bundle (from the Caskroom scan).
    public var caskToken: String?

    public init(id: String, installSource: AppInstallSource? = nil, shortVersion: String? = nil, build: String? = nil,
                appStoreID: String? = nil, feedURL: URL? = nil, caskToken: String? = nil) {
        self.id = id
        self.installSource = installSource
        self.shortVersion = shortVersion
        self.build = build
        self.appStoreID = appStoreID
        self.feedURL = feedURL
        self.caskToken = caskToken
    }

    /// Reads Info.plist of `app` (disk access: call off the main actor). `caskTokens` maps
    /// "Foo.app" to its cask token (`BundleReader.homebrewCaskTokens()`).
    public static func read(app: AppEntry, caskTokens: [String: String]) -> AppUpdateCandidate {
        let plist = NSDictionary(contentsOf: app.url.appendingPathComponent("Contents/Info.plist"))
        func text(_ key: String) -> String? {
            (plist?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return AppUpdateCandidate(
            id: app.id, installSource: app.installSource,
            shortVersion: text("CFBundleShortVersionString"), build: text("CFBundleVersion"),
            appStoreID: app.appStoreID,
            feedURL: text("SUFeedURL").flatMap { URL(string: $0) },
            caskToken: app.installSource == .homebrew ? caskTokens[app.url.lastPathComponent] : nil)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Looks for newer versions. The default implementation uses the network and `brew`; tests stub it.
public protocol AppUpdateChecker: Sendable {
    /// Updates by bundle id. Apps with no update, or whose source failed, are absent.
    func checkUpdates(for apps: [AppUpdateCandidate]) async -> [String: AvailableUpdate]
}

extension BundleReader {
    /// "Foo.app" -> cask token, for apps installed by Homebrew Cask (the folder name in the Caskroom).
    static func homebrewCaskTokens(roots: [String] = ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"]) -> [String: String] {
        let fm = FileManager.default
        var map: [String: String] = [:]
        for root in roots {
            for token in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let tokenDir = (root as NSString).appendingPathComponent(token)
                for version in (try? fm.contentsOfDirectory(atPath: tokenDir)) ?? [] {
                    let versionDir = (tokenDir as NSString).appendingPathComponent(version)
                    for item in (try? fm.contentsOfDirectory(atPath: versionDir)) ?? [] where item.hasSuffix(".app") {
                        map[item] = token
                    }
                }
            }
        }
        return map
    }
}

/// Pure parsing and comparison; no I/O.
public enum AppUpdateParsing {
    private enum Part: Equatable { case number(Int), text(String) }

    private static func parts(_ version: String) -> [Part] {
        var result: [Part] = []
        var digits = "", letters = ""
        func flush() {
            if !digits.isEmpty { result.append(.number(Int(digits.prefix(9)) ?? 0)); digits = "" }
            if !letters.isEmpty { result.append(.text(letters.lowercased())); letters = "" }
        }
        for ch in version {
            if ch.isASCII, ch.isNumber {
                if !letters.isEmpty { flush() }
                digits.append(ch)
            } else if ch.isLetter {
                if !digits.isEmpty { flush() }
                letters.append(ch)
            } else { flush() }
        }
        flush()
        return result
    }

    /// Sparkle-like ordering: numbers compare numerically, a text part (alpha, beta, rc) is older
    /// than a number and than the end of the version ("1.0b2" < "1.0"), missing numbers count as 0.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : nil
            let y = i < pb.count ? pb[i] : nil
            switch (x, y) {
            case let (.number(m)?, .number(n)?): if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case let (.text(m)?, .text(n)?): if m != n { return m < n ? .orderedAscending : .orderedDescending }
            case (.text?, .number?), (.text?, nil): return .orderedAscending
            case (.number?, .text?), (nil, .text?): return .orderedDescending
            case let (.number(m)?, nil): if m != 0 { return .orderedDescending }
            case let (nil, .number(n)?): if n != 0 { return .orderedAscending }
            default: break
            }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than installed: String) -> Bool {
        compare(candidate, installed) == .orderedDescending
    }

    /// Cask tokens are lowercase letters, digits and `@._+-`; anything else never reaches a command.
    public static func isSafeCaskToken(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 100 && !token.hasPrefix("-") &&
            token.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || "@._+-".contains($0)) }
    }

    // MARK: brew

    public struct BrewOutdatedCask: Equatable, Sendable {
        public var token: String
        public var installed: String?
        public var current: String
    }

    /// `brew outdated --cask --greedy --json=v2`: `{"casks":[{"name","installed_versions","current_version"}]}`.
    public static func parseBrewOutdated(_ data: Data) -> [BrewOutdatedCask] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return [] }
        return casks.compactMap { c in
            guard let name = c["name"] as? String, isSafeCaskToken(name),
                  let current = c["current_version"] as? String, !current.isEmpty else { return nil }
            let installed: String?
            if let list = c["installed_versions"] as? [String] { installed = list.last }
            else { installed = c["installed_versions"] as? String }
            return BrewOutdatedCask(token: name, installed: installed, current: current)
        }
    }

    // MARK: iTunes lookup

    public struct StoreVersion: Equatable, Sendable {
        public var version: String
        public var trackID: Int64?
    }

    /// `https://itunes.apple.com/lookup?bundleId=` result: first entry's `version` and `trackId`.
    public static func parseITunesLookup(_ data: Data) -> StoreVersion? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (root["results"] as? [[String: Any]])?.first,
              let version = first["version"] as? String, !version.isEmpty else { return nil }
        return StoreVersion(version: version, trackID: (first["trackId"] as? NSNumber)?.int64Value)
    }

    // MARK: Sparkle appcast

    public struct AppcastItem: Equatable, Sendable {
        /// `sparkle:version` (the build, what Sparkle compares with CFBundleVersion).
        public var version: String
        public var shortVersion: String?
        public var minimumSystemVersion: String?
        public var isInformational = false
    }

    /// Items of an appcast, unordered. Parsed with `XMLParser` (no external entities are resolved).
    public static func parseAppcast(_ data: Data) -> [AppcastItem] {
        let delegate = AppcastDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// The newest item the OS can run, nil if none.
    public static func newestAppcastItem(_ items: [AppcastItem], osVersion: String) -> AppcastItem? {
        items.filter { item in
            !item.isInformational && !item.version.isEmpty &&
                (item.minimumSystemVersion.map { compare($0, osVersion) != .orderedDescending } ?? true)
        }.max { compare($0.version, $1.version) == .orderedAscending }
    }

    private final class AppcastDelegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "item": current = AppcastItem(version: "")
            case "enclosure":
                guard current != nil else { return }
                if let v = attributes["sparkle:version"], !v.isEmpty { current?.version = v }
                if let v = attributes["sparkle:shortVersionString"], !v.isEmpty { current?.shortVersion = v }
                if let v = attributes["sparkle:minimumSystemVersion"], !v.isEmpty { current?.minimumSystemVersion = v }
            case "sparkle:informationalUpdate": if current != nil { current?.isInformational = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version": if current != nil, !value.isEmpty { current?.version = value }
            case "sparkle:shortVersionString": if current != nil, !value.isEmpty { current?.shortVersion = value }
            case "sparkle:minimumSystemVersion": if current != nil, !value.isEmpty { current?.minimumSystemVersion = value }
            case "item": if let c = current { items.append(c) }; current = nil
            default: break
            }
            text = ""
        }
    }
}

/// Network + `brew` implementation. Read-only: nothing is installed, and only bundle ids
/// (App Store lookups) or the app's own appcast URL are contacted.
public final class DefaultAppUpdateChecker: AppUpdateChecker, @unchecked Sendable {
    private let session: URLSession
    private let brewPaths: [String]
    private let lock = NSLock()
    private var storeCache: [String: (date: Date, value: AppUpdateParsing.StoreVersion?)] = [:]
    private let cacheLifetime: TimeInterval = 6 * 3600
    static let maxAppcastBytes = 4_000_000
    static let maxLookupBytes = 256_000
    static let maxConcurrent = 4

    public init(brewPaths: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
        self.brewPaths = brewPaths
    }

    public func checkUpdates(for apps: [AppUpdateCandidate]) async -> [String: AvailableUpdate] {
        var result: [String: AvailableUpdate] = [:]

        let cask = apps.filter { $0.caskToken != nil }
        if !cask.isEmpty, let outdated = await brewOutdated() {
            let byToken = Dictionary(outdated.map { ($0.token, $0) }, uniquingKeysWith: { a, _ in a })
            for app in cask {
                guard let token = app.caskToken, let o = byToken[token] else { continue }
                result[app.id] = AvailableUpdate(appID: app.id, kind: .homebrew, installedVersion: app.shortVersion ?? o.installed,
                                                 newVersion: o.current, caskToken: token)
            }
        }

        let remote = apps.filter { $0.caskToken == nil && ($0.installSource == .appStore || ($0.installSource == nil && $0.feedURL != nil)) }
        var index = 0
        await withTaskGroup(of: AvailableUpdate?.self) { group in
            func addNext() {
                guard index < remote.count else { return }
                let app = remote[index]; index += 1
                group.addTask { [self] in
                    app.installSource == .appStore ? await storeUpdate(app) : await sparkleUpdate(app)
                }
            }
            for _ in 0..<Self.maxConcurrent { addNext() }
            while let update = await group.next() {
                if let update { result[update.appID] = update }
                addNext()
            }
        }
        return result
    }

    // MARK: brew

    private func brewOutdated() async -> [AppUpdateParsing.BrewOutdatedCask]? {
        guard let brew = brewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        return await Task.detached(priority: .utility) { () -> [AppUpdateParsing.BrewOutdatedCask]? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["outdated", "--cask", "--greedy", "--json=v2"]
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            process.environment = env
            let out = Pipe()
            process.standardOutput = out
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            killer.cancel()
            guard process.terminationStatus == 0, data.count < 8_000_000 else { return nil }
            return AppUpdateParsing.parseBrewOutdated(data)
        }.value
    }

    // MARK: network

    private func fetch(_ url: URL, limit: Int) async -> Data? {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        var request = URLRequest(url: url)
        request.setValue("MenuFold", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme?.lowercased() == "https" else { return nil }
            if http.expectedContentLength > Int64(limit) { return nil }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
            return data
        } catch { return nil }
    }

    private func cachedStore(_ id: String) -> (date: Date, value: AppUpdateParsing.StoreVersion?)? {
        lock.lock(); defer { lock.unlock() }
        return storeCache[id]
    }

    private func setCachedStore(_ id: String, _ value: AppUpdateParsing.StoreVersion?) {
        lock.lock(); defer { lock.unlock() }
        storeCache[id] = (Date(), value)
    }

    private func storeUpdate(_ app: AppUpdateCandidate) async -> AvailableUpdate? {
        guard let installed = app.shortVersion else { return nil }
        let cached = cachedStore(app.id)
        let info: AppUpdateParsing.StoreVersion?
        if let cached, Date().timeIntervalSince(cached.date) < cacheLifetime {
            info = cached.value
        } else {
            var comps = URLComponents(string: "https://itunes.apple.com/lookup")
            comps?.queryItems = [URLQueryItem(name: "bundleId", value: app.id), URLQueryItem(name: "entity", value: "macSoftware")]
            guard let url = comps?.url, let data = await fetch(url, limit: Self.maxLookupBytes) else { return nil }
            info = AppUpdateParsing.parseITunesLookup(data)
            setCachedStore(app.id, info)
        }
        guard let info, AppUpdateParsing.isNewer(info.version, than: installed) else { return nil }
        let id = info.trackID.map(String.init) ?? app.appStoreID
        let store = id.flatMap { Int64($0) }.flatMap { URL(string: "macappstore://apps.apple.com/app/id\($0)") }
        return AvailableUpdate(appID: app.id, kind: .appStore, installedVersion: installed, newVersion: info.version, storeURL: store)
    }

    private func sparkleUpdate(_ app: AppUpdateCandidate) async -> AvailableUpdate? {
        guard let feed = app.feedURL, let installed = app.build ?? app.shortVersion,
              let data = await fetch(feed, limit: Self.maxAppcastBytes) else { return nil }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osText = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        guard let item = AppUpdateParsing.newestAppcastItem(AppUpdateParsing.parseAppcast(data), osVersion: osText),
              AppUpdateParsing.isNewer(item.version, than: installed) else { return nil }
        return AvailableUpdate(appID: app.id, kind: .sparkle, installedVersion: app.shortVersion ?? app.build,
                               newVersion: item.shortVersion ?? item.version)
    }
}
