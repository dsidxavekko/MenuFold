import Foundation

/// The modifiers the panel cares about. Everything else (Fn, caps lock, numeric pad) is noise for
/// the router, so `PanelController` drops it when it builds the event.
public struct PanelKeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = PanelKeyModifiers(rawValue: 1 << 0)
    public static let option = PanelKeyModifiers(rawValue: 1 << 1)
    public static let control = PanelKeyModifiers(rawValue: 1 << 2)
    public static let shift = PanelKeyModifiers(rawValue: 1 << 3)
}

/// One key press as the panel's key monitor saw it: the *logical* key, never a raw key code, so the
/// routing table below reads like the shortcut list in the UI and can be tested without AppKit.
public struct PanelKeyEvent: Sendable, Equatable {
    public enum Key: Sendable, Equatable {
        case up, down, left, right
        case home, end, pageUp, pageDown
        case `return`
        /// The keypad's Enter: runs the same branches as Return, but it is not the Return key code.
        case keypadEnter
        case escape
        case tab
        /// Backspace (key code 51), the panel's "delete".
        case delete
        /// A printable key as a lowercased Latin/US character, so ⌘R and ⌘Z work on a Cyrillic layout.
        case character(String)
        /// A number-row or keypad digit (⌘1…⌘9), independent of what the layout types without Shift.
        case digit(Int)
        /// Any other key: no branch of the router has an opinion about it.
        case other
    }

    public let key: Key
    public let modifiers: PanelKeyModifiers
    /// An input method is composing (candidate list, Return to commit): the keys are its own.
    public let hasMarkedText: Bool

    public init(key: Key, modifiers: PanelKeyModifiers = [], hasMarkedText: Bool = false) {
        self.key = key
        self.modifiers = modifiers
        self.hasMarkedText = hasMarkedText
    }

    /// Return and the keypad's Enter have always run the same branches.
    public var isReturn: Bool { key == .return || key == .keypadEnter }

    /// The typed logical character, nil for the special keys.
    public var character: String? {
        if case .character(let text) = key { return text }
        return nil
    }
}

/// Everything the router needs to know about the panel. It is a plain value: the router never looks
/// at the model, so every branch can be tested as a (context, event) → action table.
public struct PanelKeyContext: Sendable, Equatable {
    /// What is layered over the grid, since each of these owns (or mutes) the keyboard.
    public enum Overlay: Sendable, Equatable {
        case none
        /// The in-panel "move to Trash" card: only Return and the app menu work.
        case pendingTrash
        /// The Tab action list on a tile, with its highlighted row.
        case quickActions(appID: String, actionCount: Int, index: Int)
        /// "Створити папку з…": its search field takes typing and Return.
        case folderPicker
        /// The ⌘I info card and/or the ⌘/ shortcut list.
        case card(infoShown: Bool, shortcutsShown: Bool)
        /// An inline rename of a category tab or a folder title.
        case renaming
    }

    public var overlay: Overlay = .none
    /// A folder is expanded over the grid (no tabs there, folder columns).
    public var folderOpen = false
    /// The open folder's title is being edited in a text field: the field owns the keyboard.
    public var folderTitleEditing = false
    /// The clipboard tab is current: its rows have their own selection.
    public var clipboardTab = false
    public var clipboardSelection = false
    /// Bundle id of the app under the selection (nil for a folder, a pane or no selection).
    public var selectedAppID: String?
    /// Something is selected in the grid (`selectedItemID != nil`).
    public var selectionExists = false
    public var queryEmpty = true
    public var canUndo = false
    public var canRedo = false
    /// The selected app may be moved to the Trash (false for /System apps and without a selection).
    public var canTrash = false
    /// Visible grid rows: PageUp/PageDown shift by `rows × columns` items.
    public var rows = 1

    public init(overlay: Overlay = .none, folderOpen: Bool = false, folderTitleEditing: Bool = false,
                clipboardTab: Bool = false, clipboardSelection: Bool = false, selectedAppID: String? = nil,
                selectionExists: Bool = false, queryEmpty: Bool = true, canUndo: Bool = false,
                canRedo: Bool = false, canTrash: Bool = false, rows: Int = 1) {
        self.overlay = overlay
        self.folderOpen = folderOpen
        self.folderTitleEditing = folderTitleEditing
        self.clipboardTab = clipboardTab
        self.clipboardSelection = clipboardSelection
        self.selectedAppID = selectedAppID
        self.selectionExists = selectionExists
        self.queryEmpty = queryEmpty
        self.canUndo = canUndo
        self.canRedo = canRedo
        self.canTrash = canTrash
        self.rows = rows
    }
}

/// What the panel should do with a key. The router only names the intent: animations, model calls and
/// AppKit live in `PanelController`, which executes the action with the same calls it always made.
public enum PanelKeyAction: Sendable, Equatable {
    /// The key belongs to the search field / responder chain (text editing, its own Enter).
    case passToFirstResponder
    /// Consume the key and do nothing (a modal card that must not leak keys to the hidden query).
    case swallow

    // MARK: Trash card
    /// Return: the card runs its default button.
    case confirmTrash

    // MARK: Tab action list
    /// The list's highlighted row, already wrapped around the ends.
    case setQuickActionIndex(Int)
    case closeQuickActions
    /// Run the action at the index, then close the list.
    case runQuickAction(Int)

    // MARK: ⌘I / ⌘/ cards
    case closeCards
    /// ⌘/ while a card is up: flip the shortcut list (and drop the info card).
    case toggleShortcutsHelp
    case closeInfoCard

    // MARK: Tabs
    case cycleTab(Int)
    case selectTab(Int)

    // MARK: Selection
    case moveSelection(MoveDirection)
    /// Home: first item of the current navigation section.
    case jumpToStart
    /// End: last item of the current navigation section.
    case jumpToEnd
    /// PageUp/PageDown: shift by `pages × rows × columns` items (`rows` from the context).
    case page(Int)
    case activateSelection
    case undo
    case redo
    /// ⌘R and ⇧Return: show the selected app in Finder.
    case revealSelection
    /// ⌘⌫: ask for the trash confirmation card.
    case requestTrash

    // MARK: Actions on the selected tile
    case openQuickActions(appID: String)
    case showShortcutsHelp
    case showInfo
    case togglePin
    case moveTile(MoveDirection)
    case launchNewInstance

    // MARK: Clipboard tab
    case clipboardMove(Int)
    case clipboardCopy
    case clipboardPin
    case clipboardDelete
}

/// The panel's whole keyboard table, pure and testable: one function from (event, context) to action.
///
/// It is the former `PanelController.handleKeyDown`/`handleClipboardKey`/`handleQuickAction` chain,
/// branch by branch and in the same order, because every early return there was load-bearing (a card
/// swallowing keys before the search field sees them, ⌘Q/⌘W/⌘H/⌘, passing through, ⌥←/→ reaching the
/// search field's word jumps when the tile cannot move).
public enum PanelKeyRouter {
    /// App-level shortcuts that must reach the app menu even while a card is up. The panel swallows
    /// everything else there, so the hidden search query can't change behind the card.
    private static let appShortcuts: Set<String> = ["q", "w", "h", ","]
    /// Clipboard-editing shortcuts the folder picker's search field keeps while ⌘ is held.
    private static let folderPickerEditingKeys: Set<String> = ["q", "w", "h", ",", "v", "c", "x", "a", "z"]

    public static func action(for event: PanelKeyEvent, context: PanelKeyContext) -> PanelKeyAction {
        // Composing text owns the keyboard before any mode gets a say.
        if event.hasMarkedText { return .passToFirstResponder }

        switch context.overlay {
        case .pendingTrash:
            return trashAction(event)
        case let .quickActions(_, count, index):
            return quickActionsAction(event, count: count, index: index)
        case .folderPicker:
            return folderPickerAction(event)
        case let .card(infoShown, _):
            return cardAction(event, infoShown: infoShown)
        case .renaming:
            return .passToFirstResponder
        case .none:
            break
        }
        // The open folder's title field is a real text field: arrows and typing are its own.
        if context.folderTitleEditing { return .passToFirstResponder }
        return gridAction(event, context)
    }

    // MARK: Overlays

    /// Return runs the card's default button, Esc reaches `onCancel`, the app-level shortcuts keep
    /// working; everything else is swallowed.
    private static func trashAction(_ event: PanelKeyEvent) -> PanelKeyAction {
        if event.isReturn, event.modifiers.isEmpty { return .confirmTrash }
        if event.key == .escape { return .passToFirstResponder }
        if event.modifiers == .command, let key = event.character, appShortcuts.contains(key) {
            return .passToFirstResponder
        }
        return .swallow
    }

    private static func quickActionsAction(_ event: PanelKeyEvent, count: Int, index: Int) -> PanelKeyAction {
        if event.key == .escape { return .passToFirstResponder }
        if event.modifiers.isEmpty {
            switch event.key {
            case .down, .up:
                // An empty list has nowhere to move, but the key is still not the search field's.
                guard count > 0 else { return .swallow }
                let step = event.key == .down ? 1 : -1
                return .setQuickActionIndex(((index + step) % count + count) % count)
            case .tab:
                return .closeQuickActions
            case .return, .keypadEnter:
                // Return always closes the list; it only runs something when the row is real.
                return count > 0 && (0..<count).contains(index) ? .runQuickAction(index) : .closeQuickActions
            default:
                break
            }
        }
        if event.modifiers == .command, let key = event.character, appShortcuts.contains(key) {
            return .passToFirstResponder
        }
        return .swallow
    }

    /// The picker's field takes typing and Return; Esc reaches `onCancel`; ⌘ plus a non-editing key is
    /// swallowed so it can't trigger a panel shortcut behind the card.
    private static func folderPickerAction(_ event: PanelKeyEvent) -> PanelKeyAction {
        if event.modifiers == .command, let key = event.character, !folderPickerEditingKeys.contains(key) {
            return .swallow
        }
        return .passToFirstResponder
    }

    /// Return and Esc close a card (Esc reaches `onCancel`), ⌘/ and ⌘I toggle, the app-level shortcuts
    /// keep working, everything else is swallowed.
    private static func cardAction(_ event: PanelKeyEvent, infoShown: Bool) -> PanelKeyAction {
        if event.key == .escape { return .passToFirstResponder }
        if event.isReturn, event.modifiers.isEmpty { return .closeCards }
        if event.modifiers == .command || event.modifiers == [.command, .shift], let key = event.character {
            if key == "/" { return .toggleShortcutsHelp }
            // ⌘I closes an info card that is up; with no card it is swallowed below (the grid's ⌘I
            // must not open one behind the shortcuts list).
            if key == "i", infoShown { return .closeInfoCard }
            if event.modifiers == .command, appShortcuts.contains(key) { return .passToFirstResponder }
        }
        return .swallow
    }

    // MARK: Grid

    private static func gridAction(_ event: PanelKeyEvent, _ context: PanelKeyContext) -> PanelKeyAction {
        // ⌃Tab / ⌃⇧Tab: next / previous tab, as in browsers. No tabs inside an open folder.
        if event.key == .tab, !context.folderOpen,
           event.modifiers == .control || event.modifiers == [.control, .shift] {
            return .cycleTab(event.modifiers.contains(.shift) ? -1 : 1)
        }
        // Clipboard tab: the rows have their own selection. Anything it does not claim goes on to the
        // usual handling below, exactly as before.
        if context.clipboardTab, !context.folderOpen, let action = clipboardAction(event, context) {
            return action
        }
        // Tab on a selected app tile opens its action list.
        if event.key == .tab, event.modifiers.isEmpty, let appID = context.selectedAppID {
            return .openQuickActions(appID: appID)
        }
        if let action = tileShortcutAction(event, context) { return action }
        // No modifier at all: the selection keys. Everything else is the first responder's.
        if event.modifiers.isEmpty { return plainKeyAction(event, context) }
        // ⌘1…⌘9: the n-th tab, like browser tabs.
        if event.modifiers == .command, !context.folderOpen,
           case .digit(let digit) = event.key, (1...9).contains(digit) {
            return .selectTab(digit - 1)
        }
        // ⌘Z / ⇧⌘Z undo layout changes, but only while the search field is empty: with text in it the
        // keys stay the field's own text undo. Nothing to undo → the field's undo.
        if event.character == "z", context.queryEmpty,
           event.modifiers == .command || event.modifiers == [.command, .shift] {
            let redo = event.modifiers.contains(.shift)
            guard redo ? context.canRedo : context.canUndo else { return .passToFirstResponder }
            return redo ? .redo : .undo
        }
        if event.modifiers == .command {
            if event.character == "r", context.selectedAppID != nil { return .revealSelection }
            // With text in the search field ⌘⌫ keeps deleting the line, as in any text field.
            if event.key == .delete, context.queryEmpty, context.selectedAppID != nil, context.canTrash {
                return .requestTrash
            }
        }
        return .passToFirstResponder
    }

    /// The keys that need no modifier at all. Anything unknown goes to the search field.
    private static func plainKeyAction(_ event: PanelKeyEvent, _ context: PanelKeyContext) -> PanelKeyAction {
        switch event.key {
        case .down:
            return .moveSelection(.down)
        case .up:
            return .moveSelection(.up)
        case .left, .right:
            // Without a selection the caret moves in the search field.
            guard context.selectionExists else { return .passToFirstResponder }
            return .moveSelection(event.key == .left ? .left : .right)
        case .return, .keypadEnter:
            // No selection: the search field's onSubmit launches the first app.
            guard context.selectionExists else { return .passToFirstResponder }
            return .activateSelection
        case .home, .end, .pageUp, .pageDown:
            // The clipboard rows have no pages and their selection is their own: there these keys
            // keep moving the caret in the search field, as they did before.
            guard !context.clipboardTab else { return .passToFirstResponder }
            switch event.key {
            case .home: return .jumpToStart
            case .end: return .jumpToEnd
            case .pageUp: return .page(-1)
            default: return .page(1)
            }
        default:
            return .passToFirstResponder
        }
    }

    /// ⌘/ (keys list), ⌘I (info), ⌘D (pin), ⌥+arrows (move the tile), ⌥Return (new instance),
    /// ⇧Return (show in Finder). Nil when the key is none of these, or has nothing to act on, so the
    /// caller goes on with the plain keys (the search field keeps ⌥←/→ word jumps and Return).
    private static func tileShortcutAction(_ event: PanelKeyEvent, _ context: PanelKeyContext) -> PanelKeyAction? {
        if event.modifiers == .command || event.modifiers == [.command, .shift], event.character == "/" {
            return .showShortcutsHelp
        }
        if event.modifiers == .command, context.selectedAppID != nil {
            switch event.character {
            case "i": return .showInfo
            case "d": return .togglePin
            default: break
            }
        }
        if event.modifiers == .option, context.selectionExists, let direction = tileDirection(event.key) {
            return .moveTile(direction)
        }
        if event.isReturn, context.selectedAppID != nil {
            if event.modifiers == .option { return .launchNewInstance }
            if event.modifiers == .shift { return .revealSelection }
        }
        return nil
    }

    private static func tileDirection(_ key: PanelKeyEvent.Key) -> MoveDirection? {
        switch key {
        case .left: return .left
        case .right: return .right
        case .up: return .up
        case .down: return .down
        default: return nil
        }
    }

    /// The clipboard tab's own keys: ↑/↓ pick a row, Return copies the picked one (without a pick the
    /// search field's Enter copies the first match), ⌘D pins, ⌘⌫ deletes (with an empty query).
    /// Nil when the event is not for the list, so it goes on to the usual handling.
    private static func clipboardAction(_ event: PanelKeyEvent, _ context: PanelKeyContext) -> PanelKeyAction? {
        if event.modifiers.isEmpty {
            switch event.key {
            case .down, .up:
                return .clipboardMove(event.key == .down ? 1 : -1)
            case .return, .keypadEnter:
                return context.clipboardSelection ? .clipboardCopy : nil
            default:
                return nil
            }
        }
        if event.modifiers == .command, context.clipboardSelection {
            if event.character == "d" { return .clipboardPin }
            // With text in the search field ⌘⌫ keeps deleting the line.
            if event.key == .delete, context.queryEmpty { return .clipboardDelete }
        }
        return nil
    }
}
