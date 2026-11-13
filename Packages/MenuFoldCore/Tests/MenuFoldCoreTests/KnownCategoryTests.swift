import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct KnownCategoryTests {
    func app(_ id: String, _ raw: String? = nil) -> AppEntry {
        AppEntry(id: id, name: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), infoCategory: raw)
    }

    func id(_ short: String) -> String { "public.app-category." + short }

    @Test func infoPlistWins() {
        #expect(AppCategory.automatic(for: app("com.google.Chrome", id("games"))).id == id("games"))
        // An unknown Info.plist category falls through to the table.
        #expect(AppCategory.automatic(for: app("com.google.Chrome", "public.app-category.nonsense")).id == id("productivity"))
    }

    @Test func tableIsCaseInsensitive() {
        #expect(AppCategory.automatic(for: app("com.apple.dt.Xcode")).id == id("developer-tools"))
        #expect(AppCategory.automatic(for: app("com.tinyspeck.slackmacgap")).id == id("business"))
        #expect(AppCategory.automatic(for: app("com.spotify.client")).id == id("music"))
        #expect(AppCategory.automatic(for: app("com.apple.iWork.Pages")).id == id("productivity"))
        #expect(AppCategory.automatic(for: app("org.videolan.vlc")).id == id("video"))
    }

    @Test func prefixRules() {
        #expect(AppCategory.automatic(for: app("com.jetbrains.intellij")).id == id("developer-tools"))
        #expect(AppCategory.automatic(for: app("com.adobe.Photoshop")).id == id("graphics-design"))
        // The longest prefix wins.
        #expect(AppCategory.automatic(for: app("com.adobe.PremierePro.25")).id == id("video"))
        #expect(AppCategory.automatic(for: app("com.valvesoftware.portal2")).id == id("games"))
        // Exact entries beat prefixes.
        #expect(AppCategory.automatic(for: app("com.adobe.Reader")).id == id("productivity"))
        // `com.microsoft.` is not a blanket rule.
        #expect(AppCategory.automatic(for: app("com.microsoft.unknownthing")) == .other)
    }

    @Test func unknownIsOther() {
        #expect(AppCategory.automatic(for: app("com.example.whatever")) == .other)
        #expect(AppCategory.automatic(for: app("mail")) == .other)
    }

    @Test func tableIsWellFormed() {
        for (key, value) in KnownApps.byBundleID {
            #expect(key == key.lowercased(), "\(key) must be lowercased")
            #expect(AppCategory.from(raw: id(value)) != .other, "\(key) → \(value) is not a known category")
        }
        for rule in KnownApps.byPrefix {
            #expect(rule.prefix == rule.prefix.lowercased())
            #expect(AppCategory.from(raw: id(rule.category)) != .other)
        }
        #expect(KnownApps.byBundleID.count >= 150)
    }
}
