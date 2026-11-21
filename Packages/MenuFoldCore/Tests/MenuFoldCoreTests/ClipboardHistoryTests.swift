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

    private func image(_ seed: UInt8, size: Int = 100) -> ClipboardImage {
        ClipboardImage(data: Data(repeating: seed, count: size), thumbnail: Data([seed]), width: 800, height: 600)
    }

    @Test func imagesAreDeduplicatedByContentAndKeepTextsApart() {
        var h = ClipboardHistory()
        h.add("a")
        let first = h.add(image: image(1))
        h.add(image: image(2))
        let again = h.add(image: image(1))
        #expect(first && again)
        #expect(h.entries.compactMap { $0.image?.data.first } == [1, 2])
        #expect(h.entries.count == 3)
        let repeated = h.add(image: image(1))
        #expect(repeated == false)
    }

    @Test func oversizedAndEmptyImagesIgnored() {
        var h = ClipboardHistory()
        let huge = h.add(image: image(1, size: ClipboardHistory.maxImageBytes + 1))
        let empty = h.add(image: ClipboardImage(data: Data(), thumbnail: Data(), width: 1, height: 1))
        #expect(!huge && !empty)
        #expect(h.entries.isEmpty)
    }

    @Test func imageBytesAreCappedOldestFirstPinsExempt() {
        var h = ClipboardHistory()
        let big = ClipboardHistory.maxImageBytes
        h.add(image: image(1, size: big))
        h.togglePin(id: h.entries[0].id)
        for seed in 2...8 { h.add(image: image(UInt8(seed), size: big)) }
        let unpinned = h.entries.filter { !$0.isPinned }
        #expect(unpinned.count == 4)
        #expect(unpinned.first?.image?.data.first == 8)
        #expect(h.entries.first?.image?.data.first == 1)
    }

    @Test func imagePreviewAndFilter() {
        var h = ClipboardHistory()
        h.add("hello"); h.add(image: image(1))
        #expect(h.entries[0].preview.hasSuffix("800×600"))
        #expect(h.filtered("image").count == 1)
        #expect(h.filtered("800").count == 1)
        #expect(h.filtered("hello").map(\.text) == ["hello"])
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

@MainActor
@Suite struct ClipboardKeyboardTests {
    private func model(_ texts: [String]) -> GridModel {
        let m = GridModel(catalog: StaticAppCatalog(apps: []), store: nil)
        for t in texts.reversed() { m.clipboard.add(t) }
        m.tab = .clipboard
        return m
    }

    @Test func arrowsPickRowsAndStopAtEnds() {
        let m = model(["a", "b", "c"])
        m.moveClipboardSelection(by: 1)
        #expect(m.selectedClipboardEntry?.text == "a")
        m.moveClipboardSelection(by: 1); m.moveClipboardSelection(by: 1); m.moveClipboardSelection(by: 1)
        #expect(m.selectedClipboardEntry?.text == "c")
        m.moveClipboardSelection(by: -1)
        #expect(m.selectedClipboardEntry?.text == "b")
    }

    @Test func upFromNothingPicksLast() {
        let m = model(["a", "b"])
        m.moveClipboardSelection(by: -1)
        #expect(m.selectedClipboardEntry?.text == "b")
    }

    @Test func queryFiltersHistoryAndReturnUsesFirstMatch() {
        let m = model(["alpha", "beta", "gamma"])
        #expect(m.clipboardEntryToUse == nil)
        m.query = "ta"
        #expect(m.clipboardEntries.map(\.text) == ["beta"])
        #expect(m.clipboardEntryToUse?.text == "beta")
    }

    @Test func removeMovesPickToNeighbourAndPinKeepsPick() {
        let m = model(["a", "b", "c"])
        m.moveClipboardSelection(by: 1); m.moveClipboardSelection(by: 1)
        let removed = m.removeClipboardSelection()
        #expect(removed)
        #expect(m.selectedClipboardEntry?.text == "c")
        let pinned = m.togglePinOnClipboardSelection()
        #expect(pinned)
        #expect(m.selectedClipboardEntry?.isPinned == true)
    }

    @Test func leavingTabClearsFilterAndPick() {
        let m = model(["a"])
        m.query = "a"
        m.moveClipboardSelection(by: 1)
        m.tab = .all
        #expect(m.query.isEmpty && m.clipboardSelectedID == nil)
    }
}
