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

    public init(id: String, name: String, alternateName: String? = nil, url: URL, infoCategory: String?) {
        self.id = id
        self.name = name
        self.alternateName = alternateName == name ? nil : alternateName
        self.url = url
        self.infoCategory = infoCategory
    }

    /// True when `query` occurs in the shown name or the unlocalized one.
    public func matches(_ query: String) -> Bool {
        name.localizedStandardContains(query) || (alternateName?.localizedStandardContains(query) ?? false)
    }
}
