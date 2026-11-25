import AppKit
import MenuFoldCore
import SwiftUI

extension PanelController {
    // MARK: Keyboard

    /// Every key press goes through `PanelKeyRouter` (MenuFoldCore) for the decision and through
    /// `perform(_:context:)` for its effect. A local monitor, because the search field (first
    /// responder) swallows the keys before SwiftUI's `onKeyPress` would see them.
    func installKeyMonitor() {
        // Passive: only notes when the user last clicked or typed in the panel (keep-open grace).
        panelInputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let self, event.window === self.panel else { return }
                self.lastPanelInput = max(self.lastPanelInput, event.timestamp)
            }
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread. Only a Bool crosses the isolation boundary
            // (NSEvent isn't Sendable).
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleKeyDown(event) ?? false }
            return handled ? nil : event
        }
    }

    enum KeyCode {
        static let r: UInt16 = 15
        static let z: UInt16 = 6
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let delete: UInt16 = 51
        static let escape: UInt16 = 53
        static let keypadEnter: UInt16 = 76
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
        static let home: UInt16 = 115
        static let end: UInt16 = 119
        static let pageUp: UInt16 = 116
        static let pageDown: UInt16 = 121
    }

    /// The pressed letter for shortcut matching: the typed character on a Latin layout (so Dvorak
    /// works), the key's US-QWERTY letter on a non-Latin one (⌘R on the Ukrainian "к" key).
    func latinKey(_ event: NSEvent) -> String? {
        if let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1,
           chars.unicodeScalars.allSatisfy(\.isASCII) {
            return chars
        }
        let qwerty: [UInt16: String] = [KeyCode.r: "r", KeyCode.z: "z", 12: "q", 13: "w", 4: "h", 43: ",", 34: "i", 2: "d", 44: "/"]
        return qwerty[event.keyCode]
    }

    /// True when the event was used (and must not reach the first responder).
    ///
    /// The decision itself is `PanelKeyRouter`'s (pure, tested in the package); this method only
    /// translates the event, gathers the model's state and executes the action with the same calls
    /// and animations the panel has always made.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel, panel.isKeyWindow, isShown else { return false }
        let context = keyContext()
        return perform(PanelKeyRouter.action(for: keyEvent(from: event), context: context), context: context)
    }

    // MARK: Key translation

    /// NSEvent → the router's logical key: key codes for the special keys (layout-independent),
    /// `latinKey` and `digit` for letters and the number row.
    func keyEvent(from event: NSEvent) -> PanelKeyEvent {
        var modifiers: PanelKeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        // An input method is composing (candidate list, Return to commit): the keys are its own.
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        return PanelKeyEvent(key: logicalKey(of: event), modifiers: modifiers, hasMarkedText: composing)
    }

    func logicalKey(of event: NSEvent) -> PanelKeyEvent.Key {
        switch event.keyCode {
        case KeyCode.up: return .up
        case KeyCode.down: return .down
        case KeyCode.left: return .left
        case KeyCode.right: return .right
        case KeyCode.home: return .home
        case KeyCode.end: return .end
        case KeyCode.pageUp: return .pageUp
        case KeyCode.pageDown: return .pageDown
        case KeyCode.returnKey: return .return
        case KeyCode.keypadEnter: return .keypadEnter
        case KeyCode.escape: return .escape
        case KeyCode.tab: return .tab
        case KeyCode.delete: return .delete
        default: break
        }
        // ⌘1…⌘9 must work where the number row types symbols without Shift (AZERTY) and from the
        // keypad: the physical row first, then whatever digit was actually typed.
        if let digit = Self.digit(event) ?? latinKey(event).flatMap({ Int($0) }) { return .digit(digit) }
        if let character = latinKey(event) { return .character(character) }
        return .other
    }

    /// What the router needs to know about the panel, gathered from the model. The overlay order is
    /// the order the keys were checked in before: only one of them can be up at a time.
    func keyContext() -> PanelKeyContext {
        let overlay: PanelKeyContext.Overlay
        if model.pendingTrashAppID != nil {
            overlay = .pendingTrash
        } else if let id = model.quickActionsAppID {
            overlay = .quickActions(appID: id, actionCount: QuickActionRunner.actions(for: id).count,
                                    index: model.quickActionIndex)
        } else if model.folderPickerSourceID != nil {
            overlay = .folderPicker
        } else if model.infoAppID != nil || model.showsShortcutsHelp {
            overlay = .card(infoShown: model.infoAppID != nil, shortcutsShown: model.showsShortcutsHelp)
        } else if model.renamingFolderID != nil || model.renamingCategoryID != nil {
            overlay = .renaming
        } else {
            overlay = .none
        }
        let folderOpen = model.openFolderID != nil
        let app = model.selectedApp
        return PanelKeyContext(
            overlay: overlay,
            folderOpen: folderOpen,
            // The search field is disabled while a folder is open, so a field editor there is the
            // folder title's.
            folderTitleEditing: folderOpen && panel.firstResponder is NSText,
            clipboardTab: model.tab == .clipboard,
            clipboardSelection: model.selectedClipboardEntry != nil,
            selectedAppID: app?.id,
            selectionExists: model.selectedItemID != nil,
            queryEmpty: model.query.isEmpty,
            canUndo: model.canUndo,
            canRedo: model.canRedo,
            canTrash: app.map { model.canTrash($0) } ?? false,
            rows: folderOpen ? Self.folderRows : AppPreferences.shared.effectiveRows
        )
    }

    /// Rows of the folder overlay that fit its fixed height, so PageUp/PageDown step inside a folder
    /// too (it has no Settings-driven row count of its own).
    static var folderRows: Int { max(1, Int(GridMetrics.folderHeight / GridMetrics.rowHeight)) }

    // MARK: Action execution

    /// Runs the router's action with the calls and animations the panel has always used. False only
    /// when the key must still reach the first responder.
    func perform(_ action: PanelKeyAction, context: PanelKeyContext) -> Bool {
        let columns = model.openFolderID != nil ? GridMetrics.folderColumns : GridMetrics.columns
        let reduceMotion = ThemeOverrides.reduceMotion
        switch action {
        case .passToFirstResponder:
            return false
        case .swallow:
            return true
        case .confirmTrash:
            NotificationCenter.default.post(name: .menuFoldTrashConfirm, object: nil)
        case .setQuickActionIndex(let index):
            model.quickActionIndex = index
        case .closeQuickActions:
            model.quickActionsAppID = nil
        case .runQuickAction(let index):
            if let id = model.quickActionsAppID, let app = model.apps.first(where: { $0.id == id }) {
                let actions = QuickActionRunner.actions(for: app.id)
                if actions.indices.contains(index) {
                    QuickActionRunner.run(actions[index], app: app, model: model)
                }
            }
            model.quickActionsAppID = nil
        case .closeCards:
            model.infoAppID = nil
            model.showsShortcutsHelp = false
        case .toggleShortcutsHelp:
            model.showsShortcutsHelp.toggle()
            model.infoAppID = nil
        case .closeInfoCard:
            model.infoAppID = nil
        case .cycleTab(let offset):
            withAnimation(Self.contentAnimation) { model.cycleTab(by: offset) }
        case .selectTab(let index):
            withAnimation(Self.contentAnimation) { model.selectTab(at: index) }
        case .openQuickActions(let appID):
            model.quickActionIndex = 0
            withAnimation(reduceMotion ? Theme.crossfade : Theme.content) { model.quickActionsAppID = appID }
        case .showShortcutsHelp:
            withAnimation(reduceMotion ? Theme.crossfade : Theme.content) { model.showsShortcutsHelp = true }
        case .showInfo:
            withAnimation(reduceMotion ? Theme.crossfade : Theme.content) { _ = model.showInfoForSelection() }
        case .togglePin:
            withAnimation(Self.contentAnimation) { _ = model.togglePinOnSelection() }
        case .moveTile(let direction):
            // Nothing moved (a search, another tab, the edge of the grid): let the event reach the
            // search field, which uses ⌥←/→ for word jumps.
            var moved = false
            withAnimation(Self.contentAnimation) { moved = model.moveSelectedTile(direction, columns: columns) }
            return moved
        case .launchNewInstance:
            return model.launchNewInstanceOfSelection()
        case .revealSelection:
            return model.revealSelectionInFinder()
        case .moveSelection(let direction):
            model.moveSelection(direction, columns: columns)
        case .jumpToStart:
            navigate(to: GridNavigation.home(from: flatSelectionIndex, sections: sectionSizes))
        case .jumpToEnd:
            navigate(to: GridNavigation.end(from: flatSelectionIndex, sections: sectionSizes))
        case .page(let pages):
            navigate(to: GridNavigation.page(from: flatSelectionIndex, sections: sectionSizes,
                                             columns: columns, rows: max(1, context.rows), pages: pages))
        case .activateSelection:
            // Opening a folder morphs like a click on its tile.
            withAnimation(reduceMotion ? Theme.crossfade : Theme.morph) { _ = model.activateSelection() }
        case .undo:
            withAnimation(Self.contentAnimation) { model.undo() }
        case .redo:
            withAnimation(Self.contentAnimation) { model.redo() }
        case .requestTrash:
            guard let app = model.selectedApp else { return false }
            model.pendingTrashAppID = app.id
        case .clipboardMove(let step):
            model.moveClipboardSelection(by: step)
        case .clipboardCopy:
            guard let entry = model.selectedClipboardEntry else { return false }
            ClipboardMonitor.shared.copy(entry)
            model.onLaunched?()
        case .clipboardPin:
            withAnimation(Self.contentAnimation) { _ = model.togglePinOnClipboardSelection() }
        case .clipboardDelete:
            withAnimation(Self.contentAnimation) { _ = model.removeClipboardSelection() }
        }
        return true
    }

    /// Item counts of the navigation sections, and where the selection sits in their flat order.
    var sectionSizes: [Int] { model.navigableSections.map(\.count) }

    var flatSelectionIndex: Int? {
        guard let id = model.selectedItemID else { return nil }
        var offset = 0
        for section in model.navigableSections {
            if let index = section.firstIndex(of: id) { return offset + index }
            offset += section.count
        }
        return nil
    }

    /// Applies a flat index from `GridNavigation` (Home/End/PageUp/PageDown) to the selection.
    func navigate(to target: Int?) {
        guard let target else { return }
        let flat = model.navigableSections.flatMap { $0 }
        guard flat.indices.contains(target) else { return }
        model.selectedItemID = flat[target]
    }

    /// Tab switches and undo re-flow the grid; Reduce Motion gets a crossfade.
    static var contentAnimation: Animation {
        ThemeOverrides.reduceMotion ? Theme.crossfade : Theme.content
    }

    /// Digit of the physical number-row key (key codes are layout-independent), so ⌘1…⌘9 also work
    /// where the row types symbols without Shift (AZERTY).
    static func digit(_ event: NSEvent) -> Int? {
        let row: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        return row[event.keyCode]
    }
}
