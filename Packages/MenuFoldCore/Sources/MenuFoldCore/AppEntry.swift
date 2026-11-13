import Foundation

/// One launchable application, de-duplicated by bundle ID.
public struct AppEntry: Identifiable, Hashable, Sendable {
    /// Bundle identifier; stable key used everywhere in the layout.
    public let id: String
    /// Name in the user's system language when the bundle has it.
    public let name: String
    /// Unlocalized name when it differs from `name`; search matches it too.
    public let alternateName: String?
    public let url: URL
    /// Raw `LSApplicationCategoryType` from Info.plist, if any.
    public let infoCategory: String?
    /// Spotlight's `kMDItemLastUsedDate` (any launch, also before MenuFold was installed); nil if unknown.
    public let lastUsedDate: Date?
    /// Mac App Store id (`kMDItemAppStoreAdamID`), for "Відкрити в App Store"; nil for other apps.
    public let appStoreID: String?

    public init(id: String, name: String, alternateName: String? = nil, url: URL, infoCategory: String?,
                lastUsedDate: Date? = nil, appStoreID: String? = nil) {
        self.id = id
        self.name = name
        self.alternateName = alternateName == name ? nil : alternateName
        self.url = url
        self.infoCategory = infoCategory
        self.lastUsedDate = lastUsedDate
        self.appStoreID = appStoreID
    }

    /// True when `query` matches the shown name or the unlocalized one (see `SearchMatcher`:
    /// prefixes, words, initials, substrings, fuzzy, wrong keyboard layout).
    public func matches(_ query: String) -> Bool {
        searchScore(SearchMatcher.Query(query)) != nil
    }

    /// Best `SearchMatcher` score over `name` and `alternateName`; nil = no match.
    func searchScore(_ query: SearchMatcher.Query) -> Double? {
        SearchMatcher.bestScore([name] + (alternateName.map { [$0] } ?? []), query)
    }
}
