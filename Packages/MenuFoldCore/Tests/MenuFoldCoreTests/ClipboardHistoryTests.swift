import Foundation
import Testing
@testable import MenuFoldCore

@Suite struct ClipboardHistoryTests {
    @Test func newestFirstAndDeduplicated() {
        var h = ClipboardHistory()
        h.add("a"); h.add("b"); h.add("a")
        #expect(h.entries.map(\.text) == ["a", "b"])
        #expect(h.add("a") == false)
    }

    @Test func blankAndHugeTextIgnored() {
        var h = ClipboardHistory()
        #expect(h.add("  \n ") == false)
        #expect(h.add(String(repeating: "x", count: ClipboardHistory.maxLength + 1)) == false)
        #expect(h.entries.isEmpty)
    }

    @Test func limitDropsOldestButKeepsPinned() {
        var h = ClipboardHistory(limit: 2)
        h.add("a")
        h.togglePin(id: h.entries[0].id)
        h.add("b"); h.add("c"); h.add("d")
        #expect(h.entries.map(\.text) == ["a", "d", "c"])
    }

    @Test func pinMovesToFrontAndClearKeepsPins() {
        var h = ClipboardHistory()
        h.add("a"); h.add("b"); h.add("c")
        h.togglePin(id: h.entries[2].id)
        #expect(h.entries.map(\.text) == ["a", "c", "b"])
        h.clear()
        #expect(h.entries.map(\.text) == ["a"])
    }

    @Test func filterAndPreview() {
        var h = ClipboardHistory()
        h.add("\n  Hello World\nsecond"); h.add("other")
        #expect(h.filtered("hello").count == 1)
        #expect(h.entries.last?.preview == "Hello World")
    }

    @MainActor @Test func clipboardTabIsFirstWhenShown() {
        let model = GridModel.preview
        #expect(model.availableTabs.first == .all)
        model.showsClipboardTab = true
        #expect(model.availableTabs.first == .clipboard)
    }
}

@MainActor
@Suite struct CacheObservationTests {
    /// A view body that only hits the `visibleApps` cache must still be told when the catalog changes
    /// (the category tabs once stayed as first drawn).
    @Test func cacheHitStillTracksCatalog() {
        let catalog = StaticAppCatalog(apps: [])
        let model = GridModel(catalog: catalog, store: nil)
        _ = model.availableTabs // fills the caches while the catalog is empty
        var fired = false
        withObservationTracking {
            _ = model.availableTabs // a second read: cache hit
        } onChange: {
            fired = true
        }
        catalog.replace([AppEntry(id: "a", name: "A", url: URL(fileURLWithPath: "/Applications/A.app"), infoCategory: "public.app-category.productivity")])
        #expect(fired)
    }
}
