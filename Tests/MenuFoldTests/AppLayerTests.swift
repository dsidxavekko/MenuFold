import AppKit
import Carbon.HIToolbox
import MenuFoldCore
import Testing
@testable import MenuFold

@MainActor
@Suite("GridMetrics")
struct GridMetricsTests {
    @Test func defaultPanelSizeMatchesSystemLauncher() {
        let prefs = AppPreferences.shared
        let (c, r, fc, fr) = (prefs.columns, prefs.rows, prefs.fittedColumns, prefs.fittedRows)
        defer { prefs.columns = c; prefs.rows = r; prefs.setFittedGrid(columns: fc, rows: fr) }
        prefs.columns = 7; prefs.rows = 4
        prefs.setFittedGrid(columns: nil, rows: nil)
        #expect(GridMetrics.panelWidth == 844)
        #expect(GridMetrics.panelHeight == 577)
    }

    @Test func panelGrowsWithColumnsAndRows() {
        let prefs = AppPreferences.shared
        let (c, r, fc, fr) = (prefs.columns, prefs.rows, prefs.fittedColumns, prefs.fittedRows)
        defer { prefs.columns = c; prefs.rows = r; prefs.setFittedGrid(columns: fc, rows: fr) }
        prefs.setFittedGrid(columns: nil, rows: nil)
        prefs.columns = 8; prefs.rows = 5
        #expect(GridMetrics.panelWidth == 844 + GridMetrics.tileWidth)
        #expect(GridMetrics.panelHeight == 577 + GridMetrics.rowHeight)
        prefs.setFittedGrid(columns: 6, rows: 3)
        #expect(GridMetrics.columns == 6)
        #expect(GridMetrics.panelWidth == 844 - GridMetrics.tileWidth)
    }
}

@MainActor
@Suite("AppPreferences")
struct AppPreferencesTests {
    private func suite() -> UserDefaults {
        let name = "MenuFoldTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func defaults() {
        let p = AppPreferences(defaults: suite())
        #expect(p.columns == 7 && p.rows == 4)
        #expect(p.hotKey == nil)
        #expect(p.showsRecentTab && p.showsPinned && p.showsFolderCounts && p.showsNewAppDots)
        #expect(!p.showsMenuBarIcon && !p.forcesReduceMotion && !p.forcesIncreaseContrast)
        #expect(p.panelScreenPolicy == .cursor)
        #expect(p.dataDirectory == nil)
    }

    @Test func outOfRangeValuesAreClamped() {
        let d = suite()
        d.set(99, forKey: "gridColumns")
        d.set(0, forKey: "gridRows")
        let p = AppPreferences(defaults: d)
        #expect(p.columns == AppPreferences.columnRange.upperBound)
        #expect(p.rows == AppPreferences.rowRange.lowerBound)
    }

    @Test func valuesPersistAcrossInstances() {
        let d = suite()
        let p = AppPreferences(defaults: d)
        p.columns = 9
        p.showsMenuBarIcon = true
        p.hotKey = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
        p.panelScreenPolicy = .primary
        let q = AppPreferences(defaults: d)
        #expect(q.columns == 9 && q.showsMenuBarIcon)
        #expect(q.hotKey == p.hotKey)
        #expect(q.panelScreenPolicy == .primary)
    }

    @Test func fittedGridOverridesEffectiveOnly() {
        let p = AppPreferences(defaults: suite())
        p.setFittedGrid(columns: 5, rows: 3)
        #expect(p.effectiveColumns == 5 && p.effectiveRows == 3)
        #expect(p.columns == 7 && p.rows == 4)
        p.setFittedGrid(columns: nil, rows: nil)
        #expect(p.effectiveColumns == 7)
    }

    @Test func changeNotificationIsPosted() async {
        let p = AppPreferences(defaults: suite())
        var count = 0
        let token = NotificationCenter.default.addObserver(forName: .menuFoldPreferencesChanged, object: nil, queue: nil) { _ in count += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        p.showsPinned = false
        #expect(count >= 1)
    }

    @Test func layoutFileFollowsDataDirectory() {
        let p = AppPreferences(defaults: suite())
        let dir = URL(fileURLWithPath: "/tmp/MenuFoldTestsData/MenuFold", isDirectory: true)
        p.dataDirectory = dir
        #expect(p.layoutFileURL == dir.appendingPathComponent("layout.json"))
    }
}

@Suite("DockGeometry")
struct DockGeometryTests {
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func bottomDockBand() {
        let visible = NSRect(x: 0, y: 70, width: 1000, height: 730)
        #expect(DockGeometry.isNearDock(NSPoint(x: 500, y: 10), screenFrame: screen, visibleFrame: visible, orientation: .bottom))
        #expect(!DockGeometry.isNearDock(NSPoint(x: 500, y: 400), screenFrame: screen, visibleFrame: visible, orientation: .bottom))
    }

    @Test func autoHideUsesDockBand() {
        // Auto-hide: visibleFrame == frame, so only dockBand counts.
        #expect(DockGeometry.isNearDock(NSPoint(x: 500, y: 60), screenFrame: screen, visibleFrame: screen, orientation: .bottom, dockBand: 72))
        #expect(!DockGeometry.isNearDock(NSPoint(x: 500, y: 200), screenFrame: screen, visibleFrame: screen, orientation: .bottom, dockBand: 72))
    }

    @Test func sideDocks() {
        let left = NSRect(x: 80, y: 0, width: 920, height: 800)
        #expect(DockGeometry.isNearDock(NSPoint(x: 20, y: 400), screenFrame: screen, visibleFrame: left, orientation: .left))
        #expect(!DockGeometry.isNearDock(NSPoint(x: 500, y: 400), screenFrame: screen, visibleFrame: left, orientation: .left))
        let right = NSRect(x: 0, y: 0, width: 920, height: 800)
        #expect(DockGeometry.isNearDock(NSPoint(x: 990, y: 400), screenFrame: screen, visibleFrame: right, orientation: .right))
        #expect(!DockGeometry.isNearDock(NSPoint(x: 10, y: 400), screenFrame: screen, visibleFrame: right, orientation: .right))
    }

    @Test func hostileDockSizeIsClamped() {
        let p = NSPoint(x: 500, y: 600)
        #expect(!DockGeometry.isNearDock(p, screenFrame: screen, visibleFrame: screen, orientation: .bottom, dockBand: .infinity))
        #expect(!DockGeometry.isNearDock(p, screenFrame: screen, visibleFrame: screen, orientation: .bottom, dockBand: 1e9))
    }

    @Test func containsWithTolerance() {
        let r = NSRect(x: 0, y: 0, width: 10, height: 10)
        #expect(DockGeometry.contains(r, NSPoint(x: 10, y: 10), tolerance: 0))
        #expect(!DockGeometry.contains(r, NSPoint(x: 11, y: 5), tolerance: 0))
        #expect(DockGeometry.contains(r, NSPoint(x: 11, y: 5), tolerance: 1))
    }

    @Test func panelIsCenteredInVisibleFrame() {
        let visible = NSRect(x: 0, y: 70, width: 1000, height: 730)
        let f = DockGeometry.panelFrame(size: NSSize(width: 400, height: 300), anchor: .zero, screenFrame: screen, visibleFrame: visible, orientation: .bottom)
        #expect(f.midX == visible.midX && f.midY == visible.midY)
    }

    @Test func oversizedPanelIsPinnedInsideGap() {
        let f = DockGeometry.panelFrame(size: NSSize(width: 2000, height: 2000), anchor: .zero, screenFrame: screen, visibleFrame: screen, orientation: .bottom)
        #expect(f.minX == DockGeometry.gap && f.minY == DockGeometry.gap)
    }
}

@Suite("HotKey formatting")
struct HotKeyFormatTests {
    @Test func displayString() {
        #expect(HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey)).displayString == "⌥Space")
        let all = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        #expect(HotKey(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: all).displayString == "⌃⌥⇧⌘M")
        #expect(HotKey(keyCode: UInt32(kVK_F5), carbonModifiers: 0).displayString == "F5")
        #expect(HotKey.keyName(UInt32(kVK_LeftArrow)) == "←")
        #expect(HotKey.keyName(9999) == "#9999")
    }

    @Test func carbonModifiers() {
        #expect(HotKeyRecordingSession.carbonModifiers([.command, .shift]) == UInt32(cmdKey | shiftKey))
        #expect(HotKeyRecordingSession.carbonModifiers([.option, .control]) == UInt32(optionKey | controlKey))
        #expect(HotKeyRecordingSession.carbonModifiers([]) == 0)
        #expect(HotKeyRecordingSession.carbonModifiers([.capsLock]) == 0)
    }

    @Test func codableRoundTrip() throws {
        let k = HotKey(keyCode: 49, carbonModifiers: UInt32(cmdKey))
        #expect(try JSONDecoder().decode(HotKey.self, from: JSONEncoder().encode(k)) == k)
    }
}

@MainActor
@Suite("ShortcutsHelp / ThemeOverrides")
struct ShortcutsAndThemeTests {
    @Test func shortcutGroupsAreWellFormed() {
        let groups = PanelShortcuts.groups
        #expect(groups.count >= 3)
        for g in groups {
            #expect(!g.title.isEmpty && !g.items.isEmpty)
            for item in g.items { #expect(!item.keys.isEmpty && !item.text.isEmpty) }
        }
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func overridesOnlyTurnOn() {
        let prefs = AppPreferences.shared
        let (m, c) = (prefs.forcesReduceMotion, prefs.forcesIncreaseContrast)
        defer { prefs.forcesReduceMotion = m; prefs.forcesIncreaseContrast = c }
        prefs.forcesReduceMotion = true
        prefs.forcesIncreaseContrast = true
        #expect(ThemeOverrides.reduceMotion)
        #expect(ThemeOverrides.increaseContrast)
        prefs.forcesReduceMotion = false
        #expect(ThemeOverrides.reduceMotion == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

@MainActor
// makeQuickMenu needs an AppDelegate, which owns the real store/catalog and cannot be built in a
// test without touching the user's data; only the static helpers are covered here.
@Suite("AppMenus")
struct AppMenusTests {
    @Test func emojiImageHasRequestedSize() {
        let size = AppDelegate.menuIconSize
        #expect(AppDelegate.emojiImage("📁", size: size).size == size)
    }
}
