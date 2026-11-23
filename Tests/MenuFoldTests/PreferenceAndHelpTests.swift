import AppKit
import Carbon.HIToolbox
import MenuFoldCore
import SwiftUI
import Testing
@testable import MenuFold

/// `AppPreferences` clamping and key handling. Every test gets its own `UserDefaults` suite (a fresh
/// UUID name), so nothing here reads or writes the user's real preferences, and `AppPreferences.shared`
/// is never touched: that is the one the app and the other test suites share.
@MainActor
@Suite("AppPreferences ranges and keys")
struct AppPreferenceRangeTests {
    private func suite() throws -> UserDefaults {
        let name = "MenuFoldTests.Preferences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: Clamping

    /// Stored values are clamped when they are loaded, so a hand-edited or synced defaults file cannot
    /// give the grid a size `GridMetrics` has no layout for. Both sides of every bound, plus values far
    /// out of range.
    @Test(arguments: [(4, 5), (5, 5), (6, 6), (9, 9), (10, 10), (11, 10), (0, 5), (-7, 5),
                      (Int.max, 10), (Int.min, 5)])
    func storedColumnsAreClamped(stored: Int, expected: Int) throws {
        let defaults = try suite()
        defaults.set(stored, forKey: "gridColumns")
        #expect(AppPreferences(defaults: defaults).columns == expected)
    }

    @Test(arguments: [(2, 3), (3, 3), (4, 4), (6, 6), (7, 7), (8, 7), (0, 3), (-1, 3),
                      (Int.max, 7), (Int.min, 3)])
    func storedRowsAreClamped(stored: Int, expected: Int) throws {
        let defaults = try suite()
        defaults.set(stored, forKey: "gridRows")
        #expect(AppPreferences(defaults: defaults).rows == expected)
    }

    /// A missing key is the default, not the low bound: 7 × 4 is the system launcher's panel size.
    @Test func missingGridSizeUsesTheDefault() throws {
        let prefs = AppPreferences(defaults: try suite())
        #expect(prefs.columns == 7 && prefs.rows == 4)
        #expect(AppPreferences.columnRange.contains(prefs.columns))
        #expect(AppPreferences.rowRange.contains(prefs.rows))
    }

    /// The setter stores what it is given; the range is enforced on the next load (the only place the
    /// number can come from outside the app). Settings only offers the range, so this is a guard, not
    /// a code path users reach.
    @Test func rangeIsEnforcedOnLoadNotOnAssignment() throws {
        let defaults = try suite()
        let prefs = AppPreferences(defaults: defaults)
        prefs.columns = 99
        #expect(defaults.integer(forKey: "gridColumns") == 99)
        #expect(AppPreferences(defaults: defaults).columns == AppPreferences.columnRange.upperBound)
    }

    // MARK: Fitted grid

    /// The fitted grid is the screen's answer for this session: it overrides the preference, may go
    /// below the preference range (the panel must fit a small display), and is not persisted.
    @Test func fittedGridOverridesTheSessionOnly() throws {
        let defaults = try suite()
        let prefs = AppPreferences(defaults: defaults)
        prefs.columns = 9
        prefs.rows = 5
        prefs.setFittedGrid(columns: 4, rows: 2)
        #expect(prefs.effectiveColumns == 4 && prefs.effectiveRows == 2)
        #expect(prefs.columns == 9 && prefs.rows == 5)
        #expect(prefs.effectiveColumns < AppPreferences.columnRange.lowerBound)

        prefs.setFittedGrid(columns: nil, rows: nil)
        #expect(prefs.effectiveColumns == 9 && prefs.effectiveRows == 5)

        let relaunched = AppPreferences(defaults: defaults)
        #expect(relaunched.fittedColumns == nil && relaunched.fittedRows == nil)
        #expect(relaunched.effectiveColumns == 9 && relaunched.effectiveRows == 5)
    }

    /// One axis can shrink on its own (a wide but short screen), and the other keeps the preference.
    @Test func fittedGridCanCoverOneAxis() throws {
        let prefs = AppPreferences(defaults: try suite())
        prefs.setFittedGrid(columns: 5, rows: nil)
        #expect(prefs.effectiveColumns == 5)
        #expect(prefs.effectiveRows == prefs.rows)
        prefs.setFittedGrid(columns: nil, rows: 6)
        #expect(prefs.effectiveColumns == prefs.columns)
        #expect(prefs.effectiveRows == 6)
    }

    @Test func fittingGridPostsNoChangeNotification() throws {
        let prefs = AppPreferences(defaults: try suite())
        // `nonisolated(unsafe)`: `queue: nil` delivers on the posting thread, which is the main
        // actor here, so the observer never runs concurrently with the test body.
        nonisolated(unsafe) var changes = 0
        let token = NotificationCenter.default.addObserver(forName: .menuFoldPreferencesChanged,
                                                           object: nil, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        prefs.setFittedGrid(columns: 5, rows: 3)
        // It is recomputed on every show; a notification per show would re-apply the shell's settings.
        #expect(changes == 0)
        prefs.setFittedGrid(columns: nil, rows: nil)
        #expect(changes == 0)
    }

    // MARK: Defaults

    @Test func defaultsForTabsAndFlags() throws {
        let prefs = AppPreferences(defaults: try suite())
        // On by default: the tabs and rows that make the panel feel like the system launcher.
        #expect(prefs.showsRecentTab)
        #expect(prefs.showsClipboardTab)
        #expect(prefs.showsPinned)
        #expect(prefs.showsFolderCounts)
        #expect(prefs.showsNewAppDots)
        #expect(prefs.usesGestures)
        // Off by default: anything that costs a permission, the network or the user's attention.
        #expect(!prefs.showsMenuBarIcon)
        #expect(!prefs.keepsPanelOpenAfterLaunch)
        #expect(!prefs.rememberLastTab)
        #expect(!prefs.checksForAppUpdates)
        #expect(!prefs.forcesReduceMotion && !prefs.forcesIncreaseContrast)
        #expect(!prefs.hasSeenFirstRunHint)
        #expect(prefs.hotKey == nil)
        #expect(prefs.panelScreenPolicy == .cursor)
        #expect(prefs.dataDirectory == nil)
        #expect(prefs.layoutFileURL == LayoutStore.defaultURL)
    }

    // MARK: Keys stay per suite

    @Test func differentSuitesDoNotShareKeys() throws {
        let first = try suite()
        let second = try suite()
        let a = AppPreferences(defaults: first)
        let b = AppPreferences(defaults: second)
        a.columns = 8
        a.showsPinned = false
        a.hotKey = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
        b.rows = 6

        #expect(b.columns == 7 && b.rows == 6)
        #expect(a.columns == 8 && a.rows == 4)
        #expect(b.showsPinned && !a.showsPinned)
        #expect(b.hotKey == nil && a.hotKey != nil)
        // Nothing was written through to the other suite's backing store.
        #expect(second.object(forKey: "gridColumns") == nil)
        #expect(second.object(forKey: "hotKey") == nil)
        #expect(first.object(forKey: "gridRows") == nil)
    }

    // MARK: Negative cases

    /// A raw value that no longer exists (an older or a hand-edited file) falls back to the default
    /// instead of failing to start.
    @Test func unknownPanelScreenPolicyFallsBackToTheCursor() throws {
        let defaults = try suite()
        for raw in ["", "bogus", "Primary", "active-window"] {
            defaults.set(raw, forKey: "panelScreenPolicy")
            #expect(AppPreferences(defaults: defaults).panelScreenPolicy == .cursor, "raw value \"\(raw)\"")
        }
        defaults.set("activeWindow", forKey: "panelScreenPolicy")
        #expect(AppPreferences(defaults: defaults).panelScreenPolicy == .activeWindow)
    }

    @Test func brokenHotKeyDataIsIgnored() throws {
        let defaults = try suite()
        defaults.set(Data("not json".utf8), forKey: "hotKey")
        #expect(AppPreferences(defaults: defaults).hotKey == nil)
        // Right shape, wrong payload: a key that is missing a field cannot be a shortcut.
        defaults.set(Data(#"{"keyCode":49}"#.utf8), forKey: "hotKey")
        #expect(AppPreferences(defaults: defaults).hotKey == nil)
        // A shortcut stored as something else entirely (a string) is not a HotKey either.
        defaults.set("cmd-space", forKey: "hotKey")
        #expect(AppPreferences(defaults: defaults).hotKey == nil)
    }

    @Test func hotKeyRoundTripsAndCanBeCleared() throws {
        let defaults = try suite()
        let prefs = AppPreferences(defaults: defaults)
        let shortcut = HotKey(keyCode: UInt32(kVK_ANSI_M), carbonModifiers: UInt32(cmdKey | shiftKey))
        prefs.hotKey = shortcut
        #expect(defaults.data(forKey: "hotKey") != nil)
        #expect(AppPreferences(defaults: defaults).hotKey == shortcut)
        prefs.hotKey = nil
        #expect(defaults.object(forKey: "hotKey") == nil)
        #expect(AppPreferences(defaults: defaults).hotKey == nil)
    }

    @Test func dataDirectoryRoundTripsAndClears() throws {
        let defaults = try suite()
        let prefs = AppPreferences(defaults: defaults)
        let folder = URL(fileURLWithPath: "/tmp/MenuFoldTests/Shared/MenuFold", isDirectory: true)
        prefs.dataDirectory = folder
        #expect(prefs.layoutFileURL == folder.appendingPathComponent("layout.json"))
        #expect(AppPreferences(defaults: defaults).dataDirectory?.path == folder.path)

        prefs.dataDirectory = nil
        #expect(defaults.object(forKey: "dataDirectory") == nil)
        #expect(AppPreferences(defaults: defaults).layoutFileURL == LayoutStore.defaultURL)
    }

    /// The first-run hint is bookkeeping, not a switch of the shell: writing it must not make the
    /// app re-apply the hotkey, the menu bar icon and the rest.
    @Test func firstRunHintDoesNotNotifyButSwitchesDo() throws {
        let prefs = AppPreferences(defaults: try suite())
        // `nonisolated(unsafe)`: `queue: nil` delivers on the posting thread, which is the main
        // actor here, so the observer never runs concurrently with the test body.
        nonisolated(unsafe) var changes = 0
        let token = NotificationCenter.default.addObserver(forName: .menuFoldPreferencesChanged,
                                                           object: nil, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        prefs.hasSeenFirstRunHint = true
        #expect(changes == 0)
        prefs.showsMenuBarIcon = true
        #expect(changes == 1)
    }
}

/// The shortcut list of the panel (⌘/ and Settings → Загальне). It is built in code, so a row can go
/// missing, repeat a combination or lose its text without any compiler help. Rows are compared by
/// `keys`, which is also what `ForEach(group.items, id: \.keys)` needs to be unique — inside a group.
@MainActor
@Suite("PanelShortcuts list")
struct ShortcutCatalogTests {
    private struct Row {
        let group: Int
        let keys: String
        let text: String
    }

    private var rows: [Row] {
        PanelShortcuts.groups.enumerated().flatMap { index, group in
            group.items.map { Row(group: index, keys: $0.keys, text: $0.text) }
        }
    }

    @Test func groupsKeepTheirOrderAndSize() {
        let groups = PanelShortcuts.groups
        // Grid keys, tile order, clipboard, then tabs and the panel itself: the two columns of the
        // card split them 2 + 2.
        #expect(groups.count == 4)
        #expect(groups.map(\.items.count) == [9, 3, 4, 4])
        #expect(groups.map(\.id).allSatisfy { !$0.isEmpty })
        #expect(Set(groups.map(\.id)).count == groups.count)
    }

    @Test func rowsKeepTheirOrder() {
        #expect(rows.map(\.keys) == [
            "↑ ↓ ← →", "↩", "⌥↩", "⇧↩  ⌘R", "⇥", "⌘I", "⌘⌫", "Home  End", "Page Up  Page Down",
            "⌘D", "⌥← ⌥→ ⌥↑ ⌥↓", "⌘Z  ⇧⌘Z",
            "↑ ↓", "↩", "⌘D", "⌘⌫",
            "⌘1 … ⌘9", "⌃⇥  ⌃⇧⇥", "⌘/", "⎋",
        ])
        #expect(rows.count == 20)
    }

    /// `ForEach(group.items, id: \.keys)` renders nothing for a repeated id, so a duplicate would
    /// silently drop a row instead of failing.
    @Test func combinationsAreUniqueInsideAGroup() {
        for (index, group) in PanelShortcuts.groups.enumerated() {
            let keys = group.items.map(\.keys)
            #expect(Set(keys).count == keys.count, "group \(index) repeats a key combination")
        }
    }

    /// A combination may appear twice only where the panel means two different things by it (the grid
    /// and the clipboard), and never inside one group.
    @Test func repeatedCombinationsAreTheContextOnesOnly() {
        let repeated = Dictionary(grouping: rows, by: \.keys).filter { $0.value.count > 1 }
        #expect(Set(repeated.keys) == ["↩", "⌘D", "⌘⌫"])
        for (keys, same) in repeated {
            #expect(Set(same.map(\.group)).count > 1, "\(keys) repeats inside one group")
            // A repeated row (same group and wording) is a copy-paste leftover, not a second context.
            #expect(Set(same.map { "\($0.group)|\($0.text)" }).count == same.count, "\(keys) repeats a row")
        }
        // Pinning really is the same action on both surfaces; the other two have to say what they do
        // in the clipboard, since it differs from the grid.
        #expect(Set((repeated["⌘D"] ?? []).map(\.text)).count == 1)
        for keys in ["↩", "⌘⌫"] {
            let texts = (repeated[keys] ?? []).map(\.text)
            #expect(Set(texts).count == texts.count, "\(keys) uses one wording on both surfaces")
        }
    }

    @Test func everyRowHasKeysAndADescription() {
        for row in rows {
            #expect(!row.keys.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!row.text.trimmingCharacters(in: .whitespaces).isEmpty)
            // The card shows keys and text on one line each: padding or a newline would show up.
            #expect(row.keys == row.keys.trimmingCharacters(in: .whitespaces))
            #expect(row.text == row.text.trimmingCharacters(in: .whitespaces))
            #expect(!row.keys.contains("\n") && !row.text.contains("\n"))
        }
    }

    @Test func everyRowShowsAKeySymbol() {
        // Modifiers and the special keys the panel listens for. A row without one (a bare word) would
        // be a description in the wrong column. Home, End, Page Up and Page Down are spelled out on
        // Apple's keyboards, so their names count as keys too.
        let symbols = Set("⌘⌥⌃⇧↩⇥⎋⌫↑↓←→")
        let named = ["Home", "End", "Page Up", "Page Down"]
        for row in rows {
            #expect(row.keys.contains { symbols.contains($0) } || named.contains(where: { row.keys.contains($0) }),
                    "\(row.keys) shows no key symbol")
        }
    }

    @Test func cardSplitsTheGroupsAcrossTwoColumns() {
        let groups = PanelShortcuts.groups
        let left = groups.prefix(2)
        let right = groups.dropFirst(2)
        // Every group is drawn exactly once; the taller column is the left one.
        #expect(left.count + right.count == groups.count)
        #expect(Set((Array(left) + Array(right)).map(\.id)) == Set(groups.map(\.id)))
        #expect(left.count >= right.count)
        #expect(ShortcutsHelpCard.width > 0)
    }
}
