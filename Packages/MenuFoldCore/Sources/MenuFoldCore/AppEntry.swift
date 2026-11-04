import Foundation

/// One launchable application, de-duplicated by bundle ID.
public struct AppEntry: Identifiable, Hashable, Sendable {
    /// Bundle identifier; stable key used everywhere in the layout.
    public let id: String
    public let name: String
    public let url: URL
    /// Raw `LSApplicationCategoryType` from Info.plist, if any.
    public let infoCategory: String?

    public init(id: String, name: String, url: URL, infoCategory: String?) {
        self.id = id
        self.name = name
        self.url = url
        self.infoCategory = infoCategory
    }
}
