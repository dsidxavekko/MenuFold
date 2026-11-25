import Foundation
import Testing
@testable import MenuFoldCore

@Suite("DropRules") struct DropRulesTests {
    @Test func edgesAndCenter() {
        // width 100, edge = 22
        #expect(DropRules.zone(x: 0, width: 100, allowsCenter: true, allowsReorder: true) == .before)
        #expect(DropRules.zone(x: 21.9, width: 100, allowsCenter: true, allowsReorder: true) == .before)
        #expect(DropRules.zone(x: 22, width: 100, allowsCenter: true, allowsReorder: true) == .center)
        #expect(DropRules.zone(x: 78, width: 100, allowsCenter: true, allowsReorder: true) == .center)
        #expect(DropRules.zone(x: 78.1, width: 100, allowsCenter: true, allowsReorder: true) == .after)
        #expect(DropRules.zone(x: 100, width: 100, allowsCenter: true, allowsReorder: true) == .after)
    }

    @Test func noReorderMeansOnlyCenter() {
        #expect(DropRules.zone(x: 1, width: 100, allowsCenter: true, allowsReorder: false) == .center)
        #expect(DropRules.zone(x: 1, width: 100, allowsCenter: false, allowsReorder: false) == nil)
    }

    @Test func noCenterPicksNearerEdge() {
        #expect(DropRules.zone(x: 49, width: 100, allowsCenter: false, allowsReorder: true) == .before)
        #expect(DropRules.zone(x: 50, width: 100, allowsCenter: false, allowsReorder: true) == .after)
    }

    @Test func zeroWidth() {
        #expect(DropRules.zone(x: 5, width: 0, allowsCenter: true, allowsReorder: true) == .center)
        #expect(DropRules.zone(x: 5, width: 0, allowsCenter: false, allowsReorder: true) == nil)
    }

    @Test func outOfRangePointerClampsToEdges() {
        #expect(DropRules.zone(x: -10, width: 100, allowsCenter: true, allowsReorder: true) == .before)
        #expect(DropRules.zone(x: 500, width: 100, allowsCenter: true, allowsReorder: true) == .after)
    }

    @Test func appActionRules() {
        func act(_ z: DropZone, known: Bool = true, center: Bool = true, reorder: Bool = true, can: Bool = true) -> DropRules.AppAction? {
            DropRules.appAction(zone: z, isKnownApp: known, allowsCenter: center, allowsReorder: reorder, canReorder: can)
        }
        #expect(act(.center) == .center)
        #expect(act(.before) == .reorder(after: false))
        #expect(act(.after) == .reorder(after: true))
        #expect(act(.center, known: false) == nil)
        #expect(act(.center, center: false) == nil)
        #expect(act(.after, reorder: false) == nil)
        #expect(act(.before, can: false) == nil)
        // canReorder only matters on the edges.
        #expect(act(.center, can: false) == .center)
    }

    @Test func folderZoneNeverOnItselfOrCenter() {
        #expect(DropRules.folderZone(x: 50, width: 100, allowsReorder: true, canReorderFolders: true, isSelf: false) == .after)
        #expect(DropRules.folderZone(x: 10, width: 100, allowsReorder: true, canReorderFolders: true, isSelf: false) == .before)
        #expect(DropRules.folderZone(x: 10, width: 100, allowsReorder: true, canReorderFolders: true, isSelf: true) == nil)
        #expect(DropRules.folderZone(x: 10, width: 100, allowsReorder: false, canReorderFolders: true, isSelf: false) == nil)
        #expect(DropRules.folderZone(x: 10, width: 100, allowsReorder: true, canReorderFolders: false, isSelf: false) == nil)
    }

    @Test func appZoneUnknownIDKeepsReorder() {
        #expect(DropRules.appZone(x: 5, width: 100, allowsCenter: true, allowsReorder: true, canReorder: nil) == .before)
        #expect(DropRules.appZone(x: 5, width: 100, allowsCenter: true, allowsReorder: true, canReorder: false) == .center)
        #expect(DropRules.appZone(x: 5, width: 100, allowsCenter: false, allowsReorder: true, canReorder: false) == nil)
    }

    @Test func payloadPrecedenceAndAcceptance() {
        #expect(DropRules.payload(hasApp: true, hasFolder: true, hasFile: true) == .app)
        #expect(DropRules.payload(hasApp: false, hasFolder: true, hasFile: true) == .folder)
        #expect(DropRules.payload(hasApp: false, hasFolder: false, hasFile: true) == .file)
        #expect(DropRules.payload(hasApp: false, hasFolder: false, hasFile: false) == .none)
        func ok(_ p: DropRules.Payload, c: Bool = false, r: Bool = false, f: Bool = false, files: Bool = false) -> Bool {
            DropRules.accepts(p, allowsCenter: c, allowsReorder: r, canReorderFolders: f, supportsFiles: files)
        }
        #expect(ok(.app, c: true))
        #expect(ok(.app, r: true))
        #expect(!ok(.app))
        #expect(ok(.folder, r: true, f: true))
        #expect(!ok(.folder, r: true))
        #expect(!ok(.folder, f: true))
        #expect(ok(.file, files: true))
        #expect(!ok(.file))
        #expect(!ok(.none, c: true, r: true, f: true, files: true))
    }

    @Test func fileLimits() {
        #expect(!DropRules.isAcceptableFileCount(0))
        #expect(DropRules.isAcceptableFileCount(1))
        #expect(DropRules.isAcceptableFileCount(20))
        #expect(!DropRules.isAcceptableFileCount(21))
        #expect(DropRules.isExecutableExtension("SH"))
        #expect(DropRules.isExecutableExtension("app"))
        #expect(DropRules.isExecutableExtension("dmg"))
        #expect(!DropRules.isExecutableExtension("txt"))
        #expect(!DropRules.isExecutableExtension(""))
    }

    @Test func dragMask() {
        #expect(DragMask.forOutside(overDock: true) == .outsideDock)
        #expect(DragMask.forOutside(overDock: false) == .outsideLink)
    }
}

@Suite("ClipboardPolicy") struct ClipboardPolicyTests {
    @Test func concealedTypesAreSkippedEvenWithText() {
        for t in ClipboardPolicy.ignoredTypes {
            #expect(ClipboardPolicy.decide(types: [t, "public.utf8-plain-text"], hasText: true) == .skip)
            #expect(ClipboardPolicy.decide(types: [t, "public.png"], hasText: false) == .skip)
        }
        #expect(ClipboardPolicy.ignoredTypes.contains("org.nspasteboard.ConcealedType"))
        #expect(ClipboardPolicy.ignoredTypes.contains("org.nspasteboard.TransientType"))
        #expect(ClipboardPolicy.ignoredTypes.contains("org.nspasteboard.AutoGeneratedType"))
    }

    @Test func textBeatsImage() {
        #expect(ClipboardPolicy.decide(types: ["public.png", "public.utf8-plain-text"], hasText: true) == .text)
    }

    @Test func pngBeatsTiff() {
        #expect(ClipboardPolicy.decide(types: ["public.tiff", "public.png"], hasText: false) == .image(.png))
        #expect(ClipboardPolicy.decide(types: ["public.tiff"], hasText: false) == .image(.tiff))
    }

    @Test func nothingUsable() {
        #expect(ClipboardPolicy.decide(types: [], hasText: false) == .skip)
        #expect(ClipboardPolicy.decide(types: ["public.file-url"], hasText: false) == .skip)
    }

    @Test func changeCountHandling() {
        #expect(!ClipboardPolicy.changed(current: 5, last: 5))
        #expect(ClipboardPolicy.changed(current: 6, last: 5))
        #expect(ClipboardPolicy.isStillCurrent(count: 6, last: 6))
        #expect(!ClipboardPolicy.isStillCurrent(count: 6, last: 7))
        #expect(ClipboardPolicy.isAcceptableImageSize(10, limit: 10))
        #expect(!ClipboardPolicy.isAcceptableImageSize(11, limit: 10))
    }
}

@Suite("HotKeyPlanner") struct HotKeyPlannerTests {
    @Test func staleKeys() {
        let registered = ["main": 1, "app:a": 2, "app:b": 3]
        let wanted = ["main": 1, "app:a": 9, "app:c": 4]
        #expect(HotKeyPlanner.staleKeys(wanted: wanted, registered: registered) == ["app:a", "app:b"])
        #expect(HotKeyPlanner.staleKeys(wanted: registered, registered: registered).isEmpty)
    }

    @Test func staleConflicts() {
        #expect(HotKeyPlanner.staleConflicts(wanted: ["a": 1], conflicts: ["a": 1, "b": 2, "c": 3]) == ["b", "c"])
        #expect(HotKeyPlanner.staleConflicts(wanted: ["a": 2], conflicts: ["a": 1]) == ["a"])
    }

    @Test func needsApply() {
        let w = ["a": 1]
        #expect(HotKeyPlanner.needsApply(hasApplied: false, wanted: w, registered: w, conflicts: [:]))
        #expect(!HotKeyPlanner.needsApply(hasApplied: true, wanted: w, registered: w, conflicts: [:]))
        #expect(HotKeyPlanner.needsApply(hasApplied: true, wanted: w, registered: [:], conflicts: [:]))
        // Conflicts are retried on every call.
        #expect(HotKeyPlanner.needsApply(hasApplied: true, wanted: w, registered: [:], conflicts: ["a": 1]))
        #expect(HotKeyPlanner.needsApply(hasApplied: true, wanted: ["a": 1], registered: ["a": 1], conflicts: ["x": 1]))
    }

    @Test func mainRegistersFirst() {
        #expect(HotKeyPlanner.registrationOrder(["app:z", "clipboard", "main", "app:a"])
                == ["main", "app:a", "app:z", "clipboard"])
        // Even a key sorting before everything cannot beat main ("" ties are the only edge).
        #expect(HotKeyPlanner.registrationOrder(["", "main"]).count == 2)
    }

    @Test func ids() {
        #expect(HotKeyPlanner.nextID(for: "main", usedIDs: [2, 3]) == 1)
        #expect(HotKeyPlanner.nextID(for: "app:a", usedIDs: [UInt32]()) == 2)
        #expect(HotKeyPlanner.nextID(for: "app:a", usedIDs: [1, 2, 5]) == 6)
    }

    @Test func pressRouting() {
        let map: [UInt32: String] = [2: "app:a", 3: "clipboard"]
        #expect(HotKeyPlanner.press(id: 1, idToKey: map, clipboardKey: "clipboard") == .main)
        #expect(HotKeyPlanner.press(id: 2, idToKey: map, clipboardKey: "clipboard") == .target("app:a"))
        #expect(HotKeyPlanner.press(id: 3, idToKey: map, clipboardKey: "clipboard") == .clipboard)
        #expect(HotKeyPlanner.press(id: 9, idToKey: map, clipboardKey: "clipboard") == .unknown)
    }
}
