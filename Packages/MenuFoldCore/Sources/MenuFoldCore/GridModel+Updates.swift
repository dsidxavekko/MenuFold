import Foundation

extension GridModel {
    /// True when `AppUpdateChecker` found a newer version of the app.
    public func hasUpdate(_ appID: String) -> Bool { availableUpdates[appID] != nil }

    /// Apps (visible, in catalog order) that have an update; what the search words "updates" and
    /// "оновлення" list.
    public var appsWithUpdates: [AppEntry] {
        visibleApps.filter { availableUpdates[$0.id] != nil }
    }

    /// Runs `checker` over the catalog (Info.plist reads off the main actor) and publishes the result.
    public func refreshAvailableUpdates(using checker: AppUpdateChecker) async {
        let snapshot = apps
        let candidates = await Task.detached(priority: .utility) { () -> [AppUpdateCandidate] in
            let tokens = BundleReader.homebrewCaskTokens()
            return snapshot.map { AppUpdateCandidate.read(app: $0, caskTokens: tokens) }
        }.value
        let found = await checker.checkUpdates(for: candidates)
        let ids = Set(apps.map(\.id))
        availableUpdates = found.filter { ids.contains($0.key) }
    }

    /// Forgets all found updates (the feature was switched off).
    public func clearAvailableUpdates() {
        if !availableUpdates.isEmpty { availableUpdates = [:] }
    }

    /// Whether the (trimmed) search text asks for apps with updates.
    static func isUpdatesQuery(_ text: String) -> Bool {
        ["updates", "update", "оновлення", "оновлень"].contains(text.lowercased())
    }
}
