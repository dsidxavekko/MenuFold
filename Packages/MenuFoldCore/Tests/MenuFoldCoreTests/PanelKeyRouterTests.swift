import Testing
@testable import MenuFoldCore

/// The routing table of the panel: every mode, every documented shortcut. These tests are the record
/// of the behaviour `PanelController.handleKeyDown` had before the table moved into the core, plus the
/// keys added with it (Home/End/PageUp/PageDown).
@Suite struct PanelKeyRouterTests {
    func action(_ key: PanelKeyEvent.Key, _ modifiers: PanelKeyModifiers = [],
                _ context: PanelKeyContext = PanelKeyContext()) -> PanelKeyAction {
        PanelKeyRouter.action(for: PanelKeyEvent(key: key, modifiers: modifiers), context: context)
    }

    /// A grid with an app tile under the selection.
    var appSelected: PanelKeyContext { PanelKeyContext(selectedAppID: "a", selectionExists: true) }

    /// A grid with a folder tile under the selection (no app).
    var folderSelected: PanelKeyContext { PanelKeyContext(selectionExists: true) }

    // MARK: Grid

    @Test func arrowsMoveTheSelection() {
        for context in [PanelKeyContext(), appSelected, folderSelected, PanelKeyContext(folderOpen: true)] {
            #expect(action(.down, [], context) == .moveSelection(.down))
            #expect(action(.up, [], context) == .moveSelection(.up))
        }
        // ←/→ with nothing selected are the search field's caret keys.
        #expect(action(.left, [], PanelKeyContext()) == .passToFirstResponder)
        #expect(action(.right, [], PanelKeyContext()) == .passToFirstResponder)
        #expect(action(.left, [], appSelected) == .moveSelection(.left))
        #expect(action(.right, [], folderSelected) == .moveSelection(.right))
    }

    @Test func returnNeedsASelection() {
        // Without a selection the search field's Enter launches the first app.
        #expect(action(.return) == .passToFirstResponder)
        #expect(action(.keypadEnter) == .passToFirstResponder)
        #expect(action(.return, [], appSelected) == .activateSelection)
        #expect(action(.keypadEnter, [], folderSelected) == .activateSelection)
        // Return with a modifier is none of the monitor's business.
        #expect(action(.return, .command, appSelected) == .passToFirstResponder)
    }

    @Test func tabOpensTheActionList() {
        #expect(action(.tab, [], appSelected) == .openQuickActions(appID: "a"))
        // A folder tile has no action list, and without a selection Tab stays the field's.
        #expect(action(.tab, [], folderSelected) == .passToFirstResponder)
        #expect(action(.tab) == .passToFirstResponder)
        #expect(action(.tab, .shift, appSelected) == .passToFirstResponder)
    }

    @Test func controlTabCyclesTabs() {
        #expect(action(.tab, .control) == .cycleTab(1))
        #expect(action(.tab, [.control, .shift]) == .cycleTab(-1))
        // No tabs inside an open folder.
        #expect(action(.tab, .control, PanelKeyContext(folderOpen: true)) == .passToFirstResponder)
        #expect(action(.up, .control) == .passToFirstResponder)
    }

    @Test func commandDigitsPickTabs() {
        #expect(action(.digit(1), .command) == .selectTab(0))
        #expect(action(.digit(5), .command) == .selectTab(4))
        #expect(action(.digit(9), .command) == .selectTab(8))
        // The row has no 10th tab, and a bare digit is the search field's.
        #expect(action(.digit(0), .command) == .passToFirstResponder)
        #expect(action(.digit(1)) == .passToFirstResponder)
        #expect(action(.digit(1), .option) == .passToFirstResponder)
        #expect(action(.digit(3), .command, PanelKeyContext(folderOpen: true)) == .passToFirstResponder)
    }

    @Test func undoRedoNeedAnEmptyQueryAndHistory() {
        let undoable = PanelKeyContext(canUndo: true, canRedo: true)
        #expect(action(.character("z"), .command, undoable) == .undo)
        #expect(action(.character("z"), [.command, .shift], undoable) == .redo)
        // Nothing to undo: the key stays the search field's own undo.
        #expect(action(.character("z"), .command) == .passToFirstResponder)
        #expect(action(.character("z"), [.command, .shift], PanelKeyContext(canUndo: true)) == .passToFirstResponder)
        // With text in the field ⌘Z is text undo.
        #expect(action(.character("z"), .command, PanelKeyContext(queryEmpty: false, canUndo: true)) == .passToFirstResponder)
        #expect(action(.character("z"), .command) == .passToFirstResponder)
        #expect(action(.character("z"), [.command, .option], undoable) == .passToFirstResponder)
    }

    @Test func commandRShowsTheAppInFinder() {
        #expect(action(.character("r"), .command, appSelected) == .revealSelection)
        #expect(action(.character("r"), .command, folderSelected) == .passToFirstResponder)
        #expect(action(.character("r"), .command, PanelKeyContext()) == .passToFirstResponder)
        #expect(action(.character("r"), [.command, .shift], appSelected) == .passToFirstResponder)
    }

    @Test func commandDeleteAsksForTrash() {
        #expect(action(.delete, .command, PanelKeyContext(selectedAppID: "a", selectionExists: true, canTrash: true)) == .requestTrash)
        // A /System app, a folder tile or no selection: no card.
        #expect(action(.delete, .command, appSelected) == .passToFirstResponder)
        #expect(action(.delete, .command, folderSelected) == .passToFirstResponder)
        // With text in the field ⌘⌫ deletes the line.
        #expect(action(.delete, .command, PanelKeyContext(selectedAppID: "a", selectionExists: true,
                                                          queryEmpty: false, canTrash: true)) == .passToFirstResponder)
        // A bare ⌫ is the field's.
        #expect(action(.delete, [], appSelected) == .passToFirstResponder)
    }

    @Test func tileShortcuts() {
        // ⌘/ works without a selection too: it is the panel's own help list.
        #expect(action(.character("/"), .command) == .showShortcutsHelp)
        #expect(action(.character("/"), [.command, .shift]) == .showShortcutsHelp)
        #expect(action(.character("i"), .command, appSelected) == .showInfo)
        #expect(action(.character("d"), .command, appSelected) == .togglePin)
        #expect(action(.character("i"), .command, folderSelected) == .passToFirstResponder)
        #expect(action(.character("d"), .command, folderSelected) == .passToFirstResponder)
        #expect(action(.character("i"), [.command, .shift], appSelected) == .passToFirstResponder)
    }

    @Test func optionArrowsMoveTheTile() {
        #expect(action(.left, .option, appSelected) == .moveTile(.left))
        #expect(action(.right, .option, appSelected) == .moveTile(.right))
        #expect(action(.up, .option, appSelected) == .moveTile(.up))
        #expect(action(.down, .option, appSelected) == .moveTile(.down))
        // Nothing selected: the search field's word jumps.
        #expect(action(.left, .option) == .passToFirstResponder)
        #expect(action(.left, [.option, .command], appSelected) == .passToFirstResponder)
    }

    @Test func optionAndShiftReturn() {
        #expect(action(.return, .option, appSelected) == .launchNewInstance)
        #expect(action(.return, .shift, appSelected) == .revealSelection)
        #expect(action(.return, .option, folderSelected) == .passToFirstResponder)
        #expect(action(.return, .shift) == .passToFirstResponder)
    }

    @Test func appShortcutsAndUnknownKeysPass() {
        for key in ["q", "w", "h", ","] {
            #expect(action(.character(key), .command, appSelected) == .passToFirstResponder)
        }
        #expect(action(.escape, [], appSelected) == .passToFirstResponder)
        #expect(action(.character("a"), [], appSelected) == .passToFirstResponder)
        #expect(action(.character("v"), .command, appSelected) == .passToFirstResponder)
        #expect(action(.other, [], appSelected) == .passToFirstResponder)
    }

    // MARK: Trash card

    @Test func trashCardSwallowsEverythingButItsOwnKeys() {
        let trash = PanelKeyContext(overlay: .pendingTrash, selectedAppID: "a", selectionExists: true)
        #expect(action(.return, [], trash) == .confirmTrash)
        #expect(action(.keypadEnter, [], trash) == .confirmTrash)
        // Esc reaches `MenuFoldPanel.cancelOperation`, which owns the card.
        #expect(action(.escape, [], trash) == .passToFirstResponder)
        for key in ["q", "w", "h", ","] {
            #expect(action(.character(key), .command, trash) == .passToFirstResponder)
        }
        // The hidden query must not change behind the card.
        #expect(action(.character("a"), [], trash) == .swallow)
        #expect(action(.delete, .command, trash) == .swallow)
        #expect(action(.character("z"), .command, trash) == .swallow)
        #expect(action(.return, .shift, trash) == .swallow)
        #expect(action(.character("q"), [.command, .shift], trash) == .swallow)
        #expect(action(.digit(1), .command, trash) == .swallow)
        #expect(action(.other, [], trash) == .swallow)
    }

    // MARK: Tab action list

    @Test func quickActionListMovesAndWraps() {
        func list(index: Int, count: Int = 3) -> PanelKeyContext {
            .init(overlay: .quickActions(appID: "a", actionCount: count, index: index))
        }
        #expect(action(.down, [], list(index: 0)) == .setQuickActionIndex(1))
        #expect(action(.down, [], list(index: 2)) == .setQuickActionIndex(0))
        #expect(action(.up, [], list(index: 0)) == .setQuickActionIndex(2))
        #expect(action(.up, [], list(index: 2)) == .setQuickActionIndex(1))
        // A list with nothing in it has nowhere to move, but the key is still not the field's.
        #expect(action(.down, [], list(index: 0, count: 0)) == .swallow)
    }

    @Test func quickActionListRunsTabsAndEscapes() {
        let list = PanelKeyContext(overlay: .quickActions(appID: "a", actionCount: 3, index: 1))
        #expect(action(.return, [], list) == .runQuickAction(1))
        #expect(action(.keypadEnter, [], list) == .runQuickAction(1))
        // A row that no longer exists still closes the list.
        let stale = PanelKeyContext(overlay: .quickActions(appID: "a", actionCount: 3, index: 7))
        #expect(action(.return, [], stale) == .closeQuickActions)
        #expect(action(.tab, [], list) == .closeQuickActions)
        #expect(action(.escape, [], list) == .passToFirstResponder)
        for key in ["q", "w", "h", ","] {
            #expect(action(.character(key), .command, list) == .passToFirstResponder)
        }
        #expect(action(.character("x"), [], list) == .swallow)
        #expect(action(.down, .option, list) == .swallow)
        #expect(action(.character("q"), [.command, .shift], list) == .swallow)
    }

    // MARK: Folder picker

    @Test func folderPickerKeepsItsEditingShortcuts() {
        let picker = PanelKeyContext(overlay: .folderPicker)
        for key in ["q", "w", "h", ",", "v", "c", "x", "a", "z"] {
            #expect(action(.character(key), .command, picker) == .passToFirstResponder)
        }
        // A panel shortcut behind the card stays swallowed.
        #expect(action(.character("r"), .command, picker) == .swallow)
        #expect(action(.character("d"), .command, picker) == .swallow)
        #expect(action(.character("a"), [], picker) == .passToFirstResponder)
        #expect(action(.return, [], picker) == .passToFirstResponder)
        #expect(action(.escape, [], picker) == .passToFirstResponder)
        #expect(action(.tab, .control, picker) == .passToFirstResponder)
    }

    // MARK: ⌘I / ⌘/ cards

    @Test func cardsCloseWithReturnAndEscape() {
        let shortcuts = PanelKeyContext(overlay: .card(infoShown: false, shortcutsShown: true))
        #expect(action(.return, [], shortcuts) == .closeCards)
        #expect(action(.keypadEnter, [], shortcuts) == .closeCards)
        #expect(action(.escape, [], shortcuts) == .passToFirstResponder)
    }

    @Test func cardsToggleTheHelpListAndCloseTheInfoCard() {
        let shortcuts = PanelKeyContext(overlay: .card(infoShown: false, shortcutsShown: true))
        #expect(action(.character("/"), .command, shortcuts) == .toggleShortcutsHelp)
        #expect(action(.character("/"), [.command, .shift], shortcuts) == .toggleShortcutsHelp)
        // ⌘I only closes an info card that is actually up (⌘⇧I too); otherwise it is swallowed.
        let info = PanelKeyContext(overlay: .card(infoShown: true, shortcutsShown: false))
        #expect(action(.character("i"), .command, info) == .closeInfoCard)
        #expect(action(.character("i"), [.command, .shift], info) == .closeInfoCard)
        #expect(action(.character("i"), .command, shortcuts) == .swallow)
        for key in ["q", "w", "h", ","] {
            #expect(action(.character(key), .command, info) == .passToFirstResponder)
        }
        #expect(action(.character("q"), [.command, .shift], info) == .swallow)
        // A card owns the keyboard: no tile shortcuts leak through it.
        #expect(action(.character("d"), .command, info) == .swallow)
        #expect(action(.character("a"), [], info) == .swallow)
    }

    // MARK: Renames

    @Test func renamesOwnTheKeyboard() {
        let renaming = PanelKeyContext(overlay: .renaming, folderOpen: true, selectionExists: true)
        for key: PanelKeyEvent.Key in [.up, .down, .left, .right, .home, .end, .pageUp, .pageDown,
                                       .return, .escape, .tab, .delete, .character("a")] {
            #expect(action(key, [], renaming) == .passToFirstResponder)
        }
        #expect(action(.character("z"), .command, renaming) == .passToFirstResponder)
    }

    @Test func folderTitleEditingOwnsTheKeyboard() {
        let editing = PanelKeyContext(folderOpen: true, folderTitleEditing: true, selectionExists: true)
        for key: PanelKeyEvent.Key in [.up, .down, .home, .end, .pageUp, .pageDown, .return, .character("a")] {
            #expect(action(key, [], editing) == .passToFirstResponder)
        }
        #expect(action(.character("/"), .command, editing) == .passToFirstResponder)
    }

    // MARK: Home / End / PageUp / PageDown

    @Test func homeEndAndPagingInTheGrid() {
        for context in [appSelected, folderSelected, PanelKeyContext()] {
            #expect(action(.home, [], context) == .jumpToStart)
            #expect(action(.end, [], context) == .jumpToEnd)
            #expect(action(.pageUp, [], context) == .page(-1))
            #expect(action(.pageDown, [], context) == .page(1))
        }
        // The same rules inside an open folder (its own columns and rows).
        let folder = PanelKeyContext(folderOpen: true, selectedAppID: "a", selectionExists: true)
        #expect(action(.home, [], folder) == .jumpToStart)
        #expect(action(.end, [], folder) == .jumpToEnd)
        #expect(action(.pageDown, [], folder) == .page(1))
        #expect(action(.pageUp, [], folder) == .page(-1))
        // With a modifier they are nobody's: ⇧Home is the field's text selection.
        for modifiers: PanelKeyModifiers in [.shift, .command, .option, .control] {
            #expect(action(.home, modifiers, appSelected) == .passToFirstResponder)
            #expect(action(.pageDown, modifiers, appSelected) == .passToFirstResponder)
        }
        // The clipboard list has no pages: Home/End keep moving the caret in the field.
        let clipboard = PanelKeyContext(clipboardTab: true, clipboardSelection: true, rows: 4)
        #expect(action(.home, [], clipboard) == .passToFirstResponder)
        #expect(action(.end, [], clipboard) == .passToFirstResponder)
        #expect(action(.pageDown, [], clipboard) == .passToFirstResponder)
    }

    // MARK: Clipboard tab

    @Test func clipboardTabKeys() {
        let picked = PanelKeyContext(clipboardTab: true, clipboardSelection: true)
        #expect(action(.down, [], picked) == .clipboardMove(1))
        #expect(action(.up, [], picked) == .clipboardMove(-1))
        #expect(action(.return, [], picked) == .clipboardCopy)
        #expect(action(.keypadEnter, [], picked) == .clipboardCopy)
        #expect(action(.character("d"), .command, picked) == .clipboardPin)
        #expect(action(.delete, .command, picked) == .clipboardDelete)
    }

    @Test func clipboardTabWithoutAPickOrWithTextLetsKeysThrough() {
        let tab = PanelKeyContext(clipboardTab: true)
        // Without a pick the search field's Enter copies the first match.
        #expect(action(.return, [], tab) == .passToFirstResponder)
        #expect(action(.character("d"), .command, tab) == .passToFirstResponder)
        #expect(action(.delete, .command, tab) == .passToFirstResponder)
        // With text in the field ⌘⌫ deletes the line.
        let typing = PanelKeyContext(clipboardTab: true, clipboardSelection: true, queryEmpty: false)
        #expect(action(.delete, .command, typing) == .passToFirstResponder)
        // ⌘↑ / ⌘Z / ⌘C are not the list's.
        #expect(action(.up, .command, PanelKeyContext(clipboardTab: true, clipboardSelection: true, canUndo: true)) == .passToFirstResponder)
        #expect(action(.character("z"), .command, PanelKeyContext(clipboardTab: true, queryEmpty: true, canUndo: true)) == .undo)
        #expect(action(.character("c"), .command, tab) == .passToFirstResponder)
    }

    @Test func clipboardShortcutsDoNotLeakIntoTheGrid() {
        // The same keys on a regular tab are the tile's.
        #expect(action(.character("d"), .command, appSelected) == .togglePin)
        #expect(action(.delete, .command, PanelKeyContext(selectedAppID: "a", selectionExists: true, canTrash: true)) == .requestTrash)
        #expect(action(.down, [], appSelected) == .moveSelection(.down))
    }

    // MARK: Input method

    @Test func markedTextPassesEverything() {
        let composing = PanelKeyEvent(key: .return, hasMarkedText: true)
        #expect(PanelKeyRouter.action(for: composing, context: PanelKeyContext(overlay: .pendingTrash)) == .passToFirstResponder)
        #expect(PanelKeyRouter.action(for: composing, context: appSelected) == .passToFirstResponder)
        let down = PanelKeyEvent(key: .down, hasMarkedText: true)
        #expect(PanelKeyRouter.action(for: down, context: appSelected) == .passToFirstResponder)
    }
}

/// Home/End/PageUp/PageDown arithmetic over the flat section list (`GridNavigation`).
@Suite struct GridNavigationJumpTests {
    // [3, 7] is the panel with a "Часті" row: section 0 = 0…2, section 1 = 3…9.
    let sections = [3, 7]

    @Test func homeStaysInsideTheSection() {
        #expect(GridNavigation.home(from: 0, sections: sections) == 0)
        #expect(GridNavigation.home(from: 2, sections: sections) == 0)
        #expect(GridNavigation.home(from: 3, sections: sections) == 3)
        #expect(GridNavigation.home(from: 9, sections: sections) == 3)
    }

    @Test func endStaysInsideTheSection() {
        #expect(GridNavigation.end(from: 0, sections: sections) == 2)
        #expect(GridNavigation.end(from: 2, sections: sections) == 2)
        #expect(GridNavigation.end(from: 3, sections: sections) == 9)
        #expect(GridNavigation.end(from: 8, sections: sections) == 9)
    }

    @Test func homeAndEndWithoutSelection() {
        // Home starts at the first item, End goes to the very last one.
        #expect(GridNavigation.home(from: nil, sections: sections) == 0)
        #expect(GridNavigation.end(from: nil, sections: sections) == 9)
        #expect(GridNavigation.home(from: nil, sections: [0, 0]) == nil)
        #expect(GridNavigation.end(from: nil, sections: []) == nil)
        #expect(GridNavigation.home(from: nil, sections: [0, 4]) == 0)
        #expect(GridNavigation.end(from: nil, sections: [0, 4]) == 3)
    }

    @Test func emptySectionsAreSkipped() {
        // A leading empty section (no "Закріплені" row) must not add an offset.
        #expect(GridNavigation.home(from: 3, sections: [0, 4]) == 0)
        #expect(GridNavigation.end(from: 0, sections: [0, 4]) == 3)
        // An empty section between two rows.
        #expect(GridNavigation.home(from: 2, sections: [2, 0, 4]) == 2)
        #expect(GridNavigation.end(from: 1, sections: [2, 0, 4]) == 1)
        #expect(GridNavigation.end(from: 5, sections: [2, 0, 4]) == 5)
        // An empty grid has nothing to jump to.
        #expect(GridNavigation.home(from: 0, sections: [0, 0]) == nil)
        #expect(GridNavigation.end(from: 0, sections: [0, 0]) == nil)
        #expect(GridNavigation.page(from: 0, sections: [0], columns: 7, rows: 4, pages: 1) == nil)
    }

    @Test func shortLastRowAndASingleRow() {
        // One section of 7 in 3 columns: (0 1 2) (3 4 5) (6)
        #expect(GridNavigation.end(from: 4, sections: [7]) == 6)
        #expect(GridNavigation.home(from: 4, sections: [7]) == 0)
        // A one-row section (the "Часті" row): Home/End are its ends, whatever the column count.
        #expect(GridNavigation.home(from: 3, sections: [2, 3]) == 2)
        #expect(GridNavigation.end(from: 2, sections: [2, 3]) == 4)
        #expect(GridNavigation.home(from: 1, sections: [2, 3]) == 0)
    }

    @Test func pageClampsAtTheEnds() {
        // Ten items, 3 columns × 2 rows: a page is 6 items.
        #expect(GridNavigation.page(from: 0, sections: [10], columns: 3, rows: 2, pages: 1) == 6)
        #expect(GridNavigation.page(from: 8, sections: [10], columns: 3, rows: 2, pages: 1) == 9)
        #expect(GridNavigation.page(from: 9, sections: [10], columns: 3, rows: 2, pages: -1) == 3)
        #expect(GridNavigation.page(from: 2, sections: [10], columns: 3, rows: 2, pages: -1) == 0)
        #expect(GridNavigation.page(from: 6, sections: [10], columns: 3, rows: 2, pages: -1) == 0)
        // A short last row clamps to the last item, not past it.
        #expect(GridNavigation.page(from: 5, sections: [7], columns: 3, rows: 1, pages: 1) == 6)
        #expect(GridNavigation.page(from: 4, sections: [7], columns: 3, rows: 2, pages: 1) == 6)
    }

    @Test func pagesCrossSectionsInOrder() {
        // [0, 4, 0, 6] in 2 columns, one row per page: a flat shift of 2.
        let s = [0, 4, 0, 6]
        #expect(GridNavigation.page(from: 0, sections: s, columns: 2, rows: 1, pages: 1) == 2)
        #expect(GridNavigation.page(from: 3, sections: s, columns: 2, rows: 1, pages: 1) == 5)
        #expect(GridNavigation.page(from: 4, sections: s, columns: 2, rows: 1, pages: -1) == 2)
        #expect(GridNavigation.page(from: 9, sections: s, columns: 2, rows: 1, pages: 1) == 9)
        #expect(GridNavigation.page(from: 2, sections: s, columns: 2, rows: 1, pages: -2) == 0)
    }

    @Test func pagingWithoutSelectionStartsAtTheFirstItem() {
        #expect(GridNavigation.page(from: nil, sections: [3, 7], columns: 3, rows: 2, pages: 1) == 0)
        #expect(GridNavigation.page(from: nil, sections: [3, 7], columns: 3, rows: 2, pages: -1) == 0)
    }

    @Test func pageStepFollowsTheGridSize() {
        // Same selection and sections, a different grid: the step is rows × columns.
        #expect(GridNavigation.page(from: 4, sections: [3, 7], columns: 3, rows: 1, pages: 1) == 7)
        #expect(GridNavigation.page(from: 4, sections: [3, 7], columns: 2, rows: 1, pages: 1) == 6)
        #expect(GridNavigation.page(from: 4, sections: [3, 7], columns: 3, rows: 2, pages: 1) == 9)
        #expect(GridNavigation.page(from: 4, sections: [3, 7], columns: 3, rows: 4, pages: 1) == 9)
        // Home/End do not depend on the grid size at all.
        #expect(GridNavigation.home(from: 4, sections: [3, 7]) == 3)
        #expect(GridNavigation.end(from: 4, sections: [3, 7]) == 9)
        // Nonsense geometry still moves by at least one item.
        #expect(GridNavigation.page(from: 1, sections: [10], columns: 0, rows: 0, pages: 1) == 2)
        #expect(GridNavigation.page(from: 1, sections: [10], columns: -3, rows: 2, pages: 1) == 3)
    }

    @Test func outOfRangeIndexBehavesLikeNoSelection() {
        #expect(GridNavigation.home(from: 99, sections: sections) == 0)
        #expect(GridNavigation.end(from: 99, sections: sections) == 9)
        #expect(GridNavigation.page(from: 99, sections: sections, columns: 3, rows: 1, pages: 1) == 0)
        #expect(GridNavigation.home(from: -1, sections: sections) == 0)
        #expect(GridNavigation.end(from: -1, sections: sections) == 9)
        #expect(GridNavigation.page(from: -1, sections: sections, columns: 3, rows: 1, pages: -1) == 0)
    }
}
