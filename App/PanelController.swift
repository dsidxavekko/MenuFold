import AppKit
import Darwin
import MenuFoldCore
import SwiftUI

/// Borderless key-capable panel. Esc closes it.
final class MenuFoldPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

extension Notification.Name {
    /// Posted right before Esc closes an open folder, so an in-progress title edit can be reverted.
    static let menuFoldFolderEscape = Notification.Name("MenuFoldFolderEscape")
    /// Esc while a category tab is being renamed: the tab reverts its name and ends editing.
    static let menuFoldCategoryEscape = Notification.Name("MenuFoldCategoryEscape")
    /// Return while the in-panel "move to Trash" card is up: the card runs its default button.
    static let menuFoldTrashConfirm = Notification.Name("MenuFoldTrashConfirm")
}

/// Owns the Stack-like panel: window chrome (Liquid Glass), placement, show/hide and the
/// window-level open/close motion. `MenuFoldRootView` draws only content; the chrome lives here.
///
/// View tree: `panel.contentView` (plain layer-backed container) → `NSGlassEffectView` (the glass,
/// rounded by `cornerRadius`; its layer is what the open/close scale animates) → `contentView`
/// = `NSHostingView` with the SwiftUI root (its layer gets the brief open blur).
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    static let cornerRadius: CGFloat = Theme.panelCorner
    /// The panel's size: follows the grid columns/rows in Settings (`GridMetrics`), so it is
    /// re-read on every show and when the preferences change.
    static var panelSize: NSSize { NSSize(width: GridMetrics.panelWidth, height: GridMetrics.panelHeight) }

    /// A Dock click can first resign key (→ hide) and then call reopen (→ toggle). A reopen that
    /// arrives within this window after a Dock-caused hide is therefore the *same* click.
    private static let reopenGuardInterval: TimeInterval = 0.3
    /// While a tile drag is live, the panel must never be ordered out (it would cancel the session):
    /// a resign-key hide is deferred until the drag ends, and re-checked at this interval.
    private static let deferredHideRetryInterval: TimeInterval = 0.1
    /// If a drag stops reporting and the mouse button has been up for this long, its end callback
    /// was lost: restore the panel state (nothing else can clear a click-through panel).
    private static let dragWatchdogDelay: TimeInterval = 2
    /// Input events that end the keep-open grace (a mouse click or a key press anywhere).
    private static let userInputEventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    /// Clock slack between an event's timestamp and the HID system's "last event" time.
    private static let inputClockSlack: TimeInterval = 0.05
    /// System Settings: opening a pane from the search must let the user see it (no keep-open grace).
    private static let systemSettingsBundleID = "com.apple.systempreferences"

    private let model: GridModel
    private let panel: MenuFoldPanel
    private let glass = NSGlassEffectView()
    private let hostingView: NSHostingView<AnyView>
    /// The SwiftUI root, kept so the tree can be rebuilt after `unloadViewsWhenIdle` dropped it.
    private let rootContent: AnyView
    private var unloadTask: Task<Void, Never>?
    private var viewsUnloaded = false
    /// How long the panel stays hidden before its SwiftUI tree is torn down to give the memory back.
    private static let unloadDelay: Duration = .seconds(30)
    private var lastHide: Date = .distantPast
    /// Whether the last hide was caused by a click in the Dock area (see `hide(reason:)`).
    private var lastHideWasDockClick = false
    private var hideInFlight = false
    private(set) var isShown = false
    /// A tile drag is outside the panel: the window is dimmed and click-through.
    private var dragPassthrough = false
    /// `AppDragSession.appID != nil`, as last reported by the drag session.
    private var dragInProgress = false
    /// A hide asked for while a drag was live, applied when the drag ends.
    private var hideDeferredByDrag: HideReason?
    /// Bumped by every open/close so a stale animation completion can't undo a newer one.
    private var motionGeneration = 0

    /// Set while `onEnded` closes the panel after a drag-out. `hide()` postpones itself while a drag
    /// is live (ordering out mid-drag would cancel the session), but this hide *is* the drag's end.
    private var inDragEnd = false

    // The notification and event-monitor tokens are only written on the main actor (in the methods
    // below) but `nonisolated(unsafe)` so `deinit`, which is nonisolated for a `@MainActor` class,
    // can uninstall them: by then the last reference is gone, so no other thread can be using them.
    private nonisolated(unsafe) var activationObserver: NSObjectProtocol?
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    private nonisolated(unsafe) var keyMonitor: Any?
    private var gestures: PanelGestures?
    /// Records `lastPanelInput` (mouse-downs and key presses in the panel).
    private nonisolated(unsafe) var panelInputMonitor: Any?
    private nonisolated(unsafe) var preferencesObserver: NSObjectProtocol?
    private nonisolated(unsafe) var launchObserver: NSObjectProtocol?
    /// System uptime of the last mouse-down / key press in the panel (the click or Return that
    /// launched an app, in keep-open mode). `NSEvent.timestamp` uses the same clock.
    private var lastPanelInput: TimeInterval = -.infinity
    /// System uptime at which an app launched while the panel was up (keep-open mode); `-infinity`
    /// when no launch is pending. Only counts while it is newer than `lastPanelInput`.
    private var lastLaunchFromPanel: TimeInterval = -.infinity
    /// Like the observer tokens above: written on the main actor, invalidated from `deinit`.
    private nonisolated(unsafe) var dragWatchdog: Timer?
    private var deferredHideRetryTask: Task<Void, Never>?

    private static let scaleKey = "menuFold.panelScale"
    private static let blurKey = "menuFold.panelBlur"
    private static let blurFilterName = "panelBlur"

    /// Window alpha when fully presented: dimmed while a drag hovers outside the panel.
    private var presentedAlpha: CGFloat { dragPassthrough ? 0.15 : 1 }

    enum HideReason {
        /// Esc or a second Dock click.
        case dismissed
        /// The panel lost key status (click elsewhere, including the Dock).
        case resignedKey
        /// An app was launched from the panel: don't hide MenuFold, the launched app is activating.
        case appLaunched
    }

    init(model: GridModel) {
        self.model = model

        let root = MenuFoldRootView(model: model)
            .environment(model)
            .themeOverrides()
        rootContent = AnyView(root)
        hostingView = NSHostingView(rootView: rootContent)
        hostingView.sizingOptions = [.intrinsicContentSize]

        panel = MenuFoldPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        observeAppDrags()
        installKeyMonitor()
        gestures = PanelGestures(model: model, panel: panel)
        // Coming back to MenuFold (Dock click, ⌘-Tab) ends any "this click came from the Dock" guess.
        // `didBecomeActiveNotification` is the ObjC `NSApplicationDidBecomeActiveNotification`.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastHideWasDockClick = false }
        }
        // Unplugging a display or changing resolution can leave a visible panel stranded off-centre or
        // on a gone screen (display changes do not resign key). Re-placement happens only in `show()`,
        // so a shown panel is hidden instead.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShown else { return }
                self.hide()
            }
        }
        // Columns/rows changed in Settings: a visible panel takes the new size right away (centred
        // again on its screen), a hidden one picks it up in `show()`.
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .menuFoldPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resizeIfNeeded() }
        }
        observeLaunchesForKeepOpen()
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let panelInputMonitor { NSEvent.removeMonitor(panelInputMonitor) }
        dragWatchdog?.invalidate()
        deferredHideRetryTask?.cancel()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // No window shadow: AppKit's shadow traced a thin dark outline with a square-ish notch at
        // the rounded corners. The glass reads fine on its own.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        // Resign-key already hides the panel; a second, AppKit-driven hide could desync `isShown`.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle, .stationary]
        panel.delegate = self
        // Esc cancels a tab rename, then closes an open folder (the search field can swallow SwiftUI's
        // onKeyPress), then the panel.
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.pendingTrashAppID != nil {
                // While the system is trashing, the card stays so its result is seen.
                if !self.model.isTrashing { self.model.pendingTrashAppID = nil }
            } else if self.model.quickActionsAppID != nil {
                // Esc closes only the Tab action list.
                self.model.quickActionsAppID = nil
            } else if self.model.folderPickerSourceID != nil {
                self.model.folderPickerSourceID = nil
            } else if self.model.infoAppID != nil || self.model.showsShortcutsHelp {
                self.model.infoAppID = nil
                self.model.showsShortcutsHelp = false
            } else if self.model.renamingCategoryID != nil {
                NotificationCenter.default.post(name: .menuFoldCategoryEscape, object: nil)
            } else if self.model.openFolderID != nil {
                NotificationCenter.default.post(name: .menuFoldFolderEscape, object: nil)
                // Same motion as the SwiftUI Esc path (MenuFoldRootView): whichever responder sees the key
                // first, the folder closes with the same curve.
                let reduceMotion = ThemeOverrides.reduceMotion
                withAnimation(reduceMotion ? Theme.crossfade : Theme.folderClose) { self.model.openFolderID = nil }
            } else {
                self.hide()
            }
        }

        // A plain container as the window's content view: AppKit manages the geometry of the
        // content view's own layer, so the animated layer is one level down (the glass view).
        let container = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        glass.style = .regular
        // Light mode: plain glass over a busy/dark desktop leaves black labels unreadable, so frost it
        // with a white tint (like the Apps launcher). Dark mode reads fine untinted.
        glass.tintColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .clear
                : NSColor.white.withAlphaComponent(0.2)
        }
        glass.cornerRadius = Theme.panelCorner
        glass.frame = container.bounds
        glass.autoresizingMask = [.width, .height]
        glass.wantsLayer = true

        hostingView.wantsLayer = true
        hostingView.layerUsesCoreImageFilters = true
        hostingView.frame = glass.bounds
        hostingView.autoresizingMask = [.width, .height]
        glass.contentView = hostingView

        container.addSubview(glass)
        panel.contentView = container
    }

    /// Re-sizes a visible panel to `panelSize`, centred on the screen it is on.
    private func resizeIfNeeded() {
        guard isShown else { return }
        // Stay on the screen the panel is on, whatever the screen policy says.
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        DockGeometry.fitGrid(anchor: anchor, policy: .cursor)
        let size = Self.panelSize
        guard panel.frame.size != size else { return }
        panel.setFrame(DockGeometry.panelFrame(size: size, anchor: anchor, policy: .cursor), display: true)
    }

    // MARK: Keyboard

    /// Every key press goes through `PanelKeyRouter` (MenuFoldCore) for the decision and through
    /// `perform(_:context:)` for its effect. A local monitor, because the search field (first
    /// responder) swallows the keys before SwiftUI's `onKeyPress` would see them.
    private func installKeyMonitor() {
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

    private enum KeyCode {
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
    private func latinKey(_ event: NSEvent) -> String? {
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
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard event.window === panel, panel.isKeyWindow, isShown else { return false }
        let context = keyContext()
        return perform(PanelKeyRouter.action(for: keyEvent(from: event), context: context), context: context)
    }

    // MARK: Key translation

    /// NSEvent → the router's logical key: key codes for the special keys (layout-independent),
    /// `latinKey` and `digit` for letters and the number row.
    private func keyEvent(from event: NSEvent) -> PanelKeyEvent {
        var modifiers: PanelKeyModifiers = []
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        // An input method is composing (candidate list, Return to commit): the keys are its own.
        let composing = (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
        return PanelKeyEvent(key: logicalKey(of: event), modifiers: modifiers, hasMarkedText: composing)
    }

    private func logicalKey(of event: NSEvent) -> PanelKeyEvent.Key {
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
    private func keyContext() -> PanelKeyContext {
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
    private static var folderRows: Int { max(1, Int(GridMetrics.folderHeight / GridMetrics.rowHeight)) }

    // MARK: Action execution

    /// Runs the router's action with the calls and animations the panel has always used. False only
    /// when the key must still reach the first responder.
    private func perform(_ action: PanelKeyAction, context: PanelKeyContext) -> Bool {
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
    private var sectionSizes: [Int] { model.navigableSections.map(\.count) }

    private var flatSelectionIndex: Int? {
        guard let id = model.selectedItemID else { return nil }
        var offset = 0
        for section in model.navigableSections {
            if let index = section.firstIndex(of: id) { return offset + index }
            offset += section.count
        }
        return nil
    }

    /// Applies a flat index from `GridNavigation` (Home/End/PageUp/PageDown) to the selection.
    private func navigate(to target: Int?) {
        guard let target else { return }
        let flat = model.navigableSections.flatMap { $0 }
        guard flat.indices.contains(target) else { return }
        model.selectedItemID = flat[target]
    }

    /// Tab switches and undo re-flow the grid; Reduce Motion gets a crossfade.
    private static var contentAnimation: Animation {
        ThemeOverrides.reduceMotion ? Theme.crossfade : Theme.content
    }

    /// Digit of the physical number-row key (key codes are layout-independent), so ⌘1…⌘9 also work
    /// where the row types symbols without Shift (AZERTY).
    private static func digit(_ event: NSEvent) -> Int? {
        let row: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        return row[event.keyCode]
    }

    // MARK: Show / hide

    /// `bypassingDockGuard`: the global hotkey, the menu bar icon, URLs and Shortcuts are never the
    /// tail of a Dock click, so the reopen guard must not swallow them.
    func toggle(bypassingDockGuard: Bool = false) {
        if isShown {
            hide()
        } else if bypassingDockGuard || !wasHiddenByThisDockClick {
            // A Dock click can first resign key (→ hide) and then call reopen (→ toggle);
            // don't immediately reopen in that case.
            show()
        }
    }

    /// True when the hide we are looking at was caused by a Dock click that is probably still
    /// arriving as this reopen. Armed only if (a) the screen's Dock is at the bottom, (b) the pointer
    /// was in the bottom band, and (c) the event that made the panel resign key was a mouse-down —
    /// i.e. the click itself. Any click that merely *happened* near the bottom edge of the screen
    /// (a Desktop icon, a Finder window, a browser tab strip) therefore can't swallow a later,
    /// unrelated Dock click.
    private var wasHiddenByThisDockClick: Bool {
        guard lastHideWasDockClick, Date().timeIntervalSince(lastHide) <= Self.reopenGuardInterval else {
            return false
        }
        return true
    }

    /// Opens the panel with a fresh state. Idempotent: on a panel that is already up (URLs,
    /// Shortcuts, a launch-time show racing a command) it only brings it to the front, without
    /// resetting the query/folder/tab or replaying the open motion.
    func show() {
        if isShown {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let anchor = NSEvent.mouseLocation
        restoreViewsIfNeeded()
        ClipboardMonitor.shared.refresh()
        model.panelDidOpen()

        // Resolve the screen once: the activeWindow policy walks CGWindowList, which is not free.
        let screen = DockGeometry.targetScreen(anchor: anchor)
        DockGeometry.fitGrid(anchor: anchor, screen: screen)
        let size = Self.panelSize
        let frame = DockGeometry.panelFrame(size: size, anchor: anchor, screen: screen)

        // Reopening is the newer intent, so a hide that is still waiting for a drag to end is dropped.
        cancelDeferredHide()
        // A show is always a full reset of the window state: a lost drag-end callback, a deferred
        // drag hide or a half-faded window must not leak into this presentation.
        if dragInProgress { endDragState() }
        dragPassthrough = false
        panel.ignoresMouseEvents = false
        hideInFlight = false
        lastHideWasDockClick = false
        lastLaunchFromPanel = -.infinity

        panel.setFrame(frame, display: false)
        // Normally 0 for the fade-in. On a reopen that interrupts a fade-out stay at the current alpha:
        // the alpha shown must not dip to 0 and back (a visible blink; the window animator would queue
        // both changes while the drag/passthrough alpha is the authoritative value).
        panel.alphaValue = isShown || panel.isVisible ? max(panel.alphaValue, 0.01) : 0
        isShown = true

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        // animateIn bumps motionGeneration first: any pending out-completion is stale from here on.
        animateIn()
    }

    /// Opens the panel on `tab` (the clipboard shortcut): pressing the same shortcut again hides it,
    /// so one key toggles one tab the way the main shortcut toggles the panel.
    func show(tab: GridTab) {
        if isShown, model.tab == tab {
            hide()
            return
        }
        show()
        model.tab = tab
    }

    func hide(reason: HideReason = .dismissed) {
        // A tile drag is in progress: ordering the panel out now would cancel the drag session and
        // make the pointer cut-through in a weird state. Remember the intent and apply it on drag end.
        if dragInProgress, !inDragEnd {
            // Only an Esc / resign-key hide asked for *during* a drag is postponed: a drag-out ends
            // with its own fade-out (`fadeOutAfterDrag`), and `.appLaunched` hides without
            // deactivating, which must not come back as a `NSApp.hide` later.
            if reason == .dismissed || reason == .resignedKey { deferHideUntilDragEnd(reason) }
            return
        }
        // Act on the real window state too, so `isShown` and the panel can't drift apart;
        // but don't restart a fade-out that is already running (it would lose its reason).
        guard isShown || (panel.isVisible && !hideInFlight) else { return }
        isShown = false
        hideInFlight = true
        lastHide = Date()
        lastHideWasDockClick = Self.isDockClickHide(reason: reason)

        let panel = panel
        animateOut { [weak self] generation in
            guard let self, generation == self.motionGeneration, !self.isShown else { return }
            // `animateOut` already dropped stale generations; the alpha/tween state is restored here
            // so every hide path (dismiss, resign-key, app launch, drag-out) ends in the same state.
            // After an app launch, NSApp.hide would race the launched app's activation.
            if reason == .appLaunched {
                self.hideInFlight = false
                panel.orderOut(nil)
                self.resetMotion()
                panel.alphaValue = 1
                self.scheduleViewUnload()
                return
            }
            // Also gives focus back to the previous app unless another MenuFold window (Settings) is open.
            self.resetAfterHide()
        }
    }

    /// Classifies a resign-key hide as "the user clicked the Dock". See `wasHiddenByThisDockClick`.
    private static func isDockClickHide(reason: HideReason) -> Bool {
        guard reason == .resignedKey else { return false }
        // Any Dock orientation: `isNearDock` checks the Dock's edge and that a Dock window is under
        // the pointer, so a side Dock arms the guard only on the display that shows it.
        guard DockGeometry.isNearDock(NSEvent.mouseLocation) else { return false }
        // Only a mouse click counts: that is what takes focus away from the panel. Key equivalents,
        // Cmd-Tab and programmatic resigns leave `currentEvent` as something else. The mouse-down is
        // the real event; the up-variants only cover a resign that AppKit reports a click later.
        switch NSApp.currentEvent?.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return true
        default:
            return false
        }
    }

    // MARK: Deferred hide (drag in progress)

    private func deferHideUntilDragEnd(_ reason: HideReason) {
        guard hideDeferredByDrag == nil else { return }
        hideDeferredByDrag = reason
        // Backstop for the case where no drag-end callback ever arrives: retry every 0.1 s for about
        // 3 s (then give up; `show()` also cancels this). Each retry re-reads `dragInProgress`, so a
        // normal drag-end clears the flag and the next tick applies the hide within 0.1 s.
        deferredHideRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(Self.deferredHideRetryInterval))
                guard let self, self.hideDeferredByDrag != nil else { return }
                if !self.dragInProgress { self.flushDeferredHide(); return }
            }
        }
    }

    /// Applies a hide that was postponed while a drag was live. One-shot by design: a deferred hide
    /// must never start a second fade-out or outlive the presentation it belongs to.
    private func flushDeferredHide() {
        guard let reason = hideDeferredByDrag else { return }
        hideDeferredByDrag = nil
        deferredHideRetryTask?.cancel()
        deferredHideRetryTask = nil
        hide(reason: reason)
    }

    private func cancelDeferredHide() {
        hideDeferredByDrag = nil
        deferredHideRetryTask?.cancel()
        deferredHideRetryTask = nil
    }

    // MARK: Open / close motion

    /// Apps-launcher-like appear: window fades in while the glass springs 0.94 → 1 (slight
    /// overshoot) and the content sharpens from a small blur. Reduce Motion: fade only.
    ///
    /// The fade is on the window's `alphaValue` (so the window shadow fades with it); the scale and
    /// blur are explicit `CAAnimation`s that never change the layers' model values, so AppKit's
    /// own layer-geometry management can't fight them and nothing is left behind if they're cut off.
    private func animateIn() {
        motionGeneration += 1
        let generation = motionGeneration
        resetMotion()

        let reduceMotion = ThemeOverrides.reduceMotion
        let panel = panel
        let target = presentedAlpha
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Theme.panelFadeIn
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = target
        }
        guard !reduceMotion, let layer = glass.layer else { return }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.motionGeneration == generation else { return }
                self.hostingView.layer?.filters = nil
                // The shadow was captured from the first (scaled, faded) frame; refresh it.
                self.panel.invalidateShadow()
            }
        }

        let response = Theme.panelOpenResponse
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * Theme.panelOpenDamping / response
        spring.fromValue = NSValue(caTransform3D: Self.centeredScale(Theme.panelOpenScale, of: layer))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: Self.scaleKey)

        if let contentLayer = hostingView.layer, let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = Self.blurFilterName
            blur.setValue(0, forKey: kCIInputRadiusKey)
            contentLayer.filters = [blur]
            let sharpen = CABasicAnimation(keyPath: "filters.\(Self.blurFilterName).inputRadius")
            sharpen.fromValue = Theme.panelOpenBlur
            sharpen.toValue = 0
            sharpen.duration = 0.15
            sharpen.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentLayer.add(sharpen, forKey: Self.blurKey)
        }
        CATransaction.commit()
    }

    /// Quick close: fade out while the glass shrinks to 0.97 from wherever it currently is
    /// (an open spring may still be running). Reduce Motion: fade only.
    ///
    /// The completion is tagged with its `motionGeneration`, and only the newest motion may run it:
    /// a fade-out that was superseded halfway (reopen, or a second hide) must not order the panel out
    /// or call `NSApp.hide` behind the newer presentation's back.
    /// `@Sendable`: AppKit's animation completion handler is one, and the closure only runs on the
    /// main actor (it is called through `MainActor.assumeIsolated`), so nothing crosses a thread.
    private func animateOut(completion: @escaping @Sendable @MainActor (Int) -> Void) {
        motionGeneration += 1
        let generation = motionGeneration
        let reduceMotion = ThemeOverrides.reduceMotion
        hostingView.layer?.removeAnimation(forKey: Self.blurKey)
        hostingView.layer?.filters = nil

        if !reduceMotion, let layer = glass.layer {
            let from = layer.presentation()?.transform ?? CATransform3DIdentity
            layer.removeAnimation(forKey: Self.scaleKey)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = NSValue(caTransform3D: from)
            shrink.toValue = NSValue(caTransform3D: Self.centeredScale(Theme.panelCloseScale, of: layer))
            shrink.duration = Theme.panelClose
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            // Hold the end state until the window is ordered out; `resetMotion` removes it.
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: Self.scaleKey)
        }

        let panel = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Theme.panelClose
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { completion(generation) }
        })
    }

    /// Drops any running or held scale/blur animation, leaving the layers at their model values.
    private func resetMotion() {
        glass.layer?.removeAnimation(forKey: Self.scaleKey)
        hostingView.layer?.removeAnimation(forKey: Self.blurKey)
        hostingView.layer?.filters = nil
    }

    /// A transform that scales `layer` around its visual centre, whatever its `anchorPoint`
    /// (AppKit-backed layers default to a (0, 0) anchor, and AppKit may reset it on layout).
    private static func centeredScale(_ scale: CGFloat, of layer: CALayer) -> CATransform3D {
        let b = layer.bounds
        let dx = (0.5 - layer.anchorPoint.x) * b.width
        let dy = (0.5 - layer.anchorPoint.y) * b.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }

    // MARK: Dragging an app out of the panel

    /// While a tile drag is outside the panel, fade it and let clicks/drops through to what's under
    /// it (Desktop, Finder, Dock). Never ordered out mid-drag: that could cancel the session.
    private func observeAppDrags() {
        let session = AppDragSession.shared
        session.onOutsidePanelChanged = { [weak self] outside in
            self?.setDragPassthrough(outside)
        }
        session.onEnded = { [weak self] droppedOutside in
            guard let self else { return }
            // Read before anything else can clear it: `dragPassthrough` is the only record that the
            // panel is dimmed from a drag, and every reset below runs before the fade-out's completion.
            let wasPassthrough = self.dragPassthrough
            self.endDragState()
            if droppedOutside {
                // The user chose to drop outside: close, fading from the current (dimmed) alpha, then
                // restore the window for the next presentation. `hide()` is called with the marker so
                // its drag deferral does not swallow this hide.
                self.inDragEnd = true
                self.hide()
                self.inDragEnd = false
                if self.hideInFlight, wasPassthrough { self.fadeOutAfterDrag() }
            } else {
                self.setDragPassthrough(false)
                // A resign-key hide that was postponed for the drag now owns the panel.
                self.flushDeferredHide()
            }
        }
    }

    /// Fade-out for a drag that ended outside the panel. Not `hide()`: that path reads drag state that
    /// `AppDragSession.ended` has already reset by the time its completion runs, so the panel would
    /// stay at 15 % alpha and click-through.
    private func fadeOutAfterDrag() {
        guard isShown else { self.resetAfterHide(); return }
        isShown = false
        hideInFlight = true
        lastHide = Date()
        lastHideWasDockClick = false
        animateOut { [weak self] generation in
            guard let self, generation == self.motionGeneration, !self.isShown else { return }
            self.resetAfterHide()
        }
    }

    /// Shared tail of every hide: window hidden, motion and alpha back to the resting state, and the
    /// app deactivated only if no other MenuFold window (Settings) is visible.
    private func resetAfterHide() {
        hideInFlight = false
        panel.orderOut(nil)
        resetMotion()
        panel.alphaValue = 1
        let otherVisible = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if !otherVisible, NSApp.isActive { NSApp.hide(nil) }
        scheduleViewUnload()
    }

    /// A hidden panel still keeps its whole SwiftUI tree (tiles, display lists, decoded icons), tens of
    /// MB. After a while without use the tree is dropped; `show()` rebuilds it while the panel is
    /// still transparent. View-local state (scroll position) is lost, the model's state is not.
    private func scheduleViewUnload() {
        unloadTask?.cancel()
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.unloadDelay)
            guard !Task.isCancelled, let self, !self.isShown, !self.panel.isVisible else { return }
            self.hostingView.rootView = AnyView(EmptyView())
            // A hidden window is not re-rendered, so without this the old graph would linger.
            self.hostingView.layoutSubtreeIfNeeded()
            self.viewsUnloaded = true
            IconCache.shared.removeAll()
            FileIconCache.shared.removeAll()
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    private func restoreViewsIfNeeded() {
        unloadTask?.cancel()
        unloadTask = nil
        guard viewsUnloaded else { return }
        hostingView.rootView = rootContent
        viewsUnloaded = false
    }

    private func setDragPassthrough(_ on: Bool) {
        if on {
            dragInProgress = true
            startDragWatchdog()
        } else {
            // Passthrough ends: stop the watchdog too, or it would tick forever when this runs after
            // `endDragState` cleared the drag (nothing else would ever stop it).
            stopDragWatchdog()
        }
        dragPassthrough = on
        panel.ignoresMouseEvents = on
        // Overrides a running open fade (the window animator keeps one alpha animation); a fade-out
        // in progress is left alone.
        guard isShown else { return }
        let panel = panel
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = on ? 0.15 : 1
        }
    }

    /// Clears everything a drag can leave behind: the click-through flag, the dimmed alpha and a
    /// hide that was waiting for the drag.
    private func endDragState() {
        dragInProgress = false
        dragPassthrough = false
        stopDragWatchdog()
        // Deferred to the next main-queue turn on purpose: AppKit's in-process drag loop restores the
        // backing window's `ignoresMouseEvents` from a snapshot taken when the drag started, *after*
        // the source's `endedAt` callback. Setting the flag synchronously would let that restore put
        // `ignoresMouseEvents = true` back on a panel that will stay visible (pointer still in the
        // Dock band), and a quick second Dock click would then reach the panel's tiles and launch an
        // app. One turn later the drag loop is gone, so nothing can resurrect it.
        if panel.ignoresMouseEvents {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.dragInProgress else { return }
                self.panel.ignoresMouseEvents = false
            }
        }
        if isShown, panel.alphaValue < 1 {
            let panel = panel
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Watchdog for a lost drag-end callback: nothing else can clear a click-through panel, so if the
    /// mouse button has been up for `dragWatchdogDelay` while a drag is "in progress", end it here.
    /// 0.5 s ticks in `.common` mode are free; the timer is created at most once per drag.
    private func startDragWatchdog() {
        guard dragWatchdog == nil else { return }
        var releasedAt: Date?
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons & 1 == 0 else { releasedAt = nil; return }
                let now = Date()
                let since = releasedAt ?? now
                releasedAt = since
                guard self.dragInProgress,
                      now.timeIntervalSince(since) >= Self.dragWatchdogDelay else { return }
                // Recover as if the drag ended inside the panel: keep it open, but interactable.
                // The session's callbacks stay installed and harmless without a drag.
                self.endDragState()
                self.flushDeferredHide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragWatchdog = timer
    }

    private func stopDragWatchdog() {
        dragWatchdog?.invalidate()
        dragWatchdog = nil
    }

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if shouldStayOpenAfterLaunch() {
            // The app just launched from the panel took focus; keep the panel up and key so the next
            // app can be clicked or typed for. Next turn: AppKit is still inside the resign.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isShown, !self.panel.isKeyWindow else { return }
                NSApp.activate()
                self.panel.makeKeyAndOrderFront(nil)
            }
            return
        }
        hide(reason: .resignedKey)
    }

    // MARK: Keep open after launch

    /// In keep-open mode, an app launched from the panel may activate itself when it finishes
    /// launching (`GridModel.launch` launches without activating, but many apps don't care), which
    /// makes the panel resign key. That activation is undone, but only until the user's next input:
    /// a click or key press anywhere after the launch means a later resign-key is the user leaving.
    private func observeLaunchesForKeepOpen() {
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let isRegular = app?.activationPolicy == .regular
            MainActor.assumeIsolated {
                guard let self, self.isShown, isRegular, bundleID != Self.systemSettingsBundleID else { return }
                self.noteLaunchFromPanel()
            }
        }
    }

    /// Arms the keep-open grace for an app launch that happened while the panel was up.
    func noteLaunchFromPanel() {
        guard model.keepsPanelOpenAfterLaunch else { return }
        lastLaunchFromPanel = ProcessInfo.processInfo.systemUptime
    }

    /// System uptime of the user's latest click or key press anywhere (HID level, so other apps'
    /// windows and the Dock count too; needs no permission).
    private static var lastUserInput: TimeInterval {
        let since = userInputEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
        return ProcessInfo.processInfo.systemUptime - since
    }

    /// True when this resign-key is an app launched from the panel activating itself: keep-open mode,
    /// a launch after the user's last input in the panel, and no click or key press since that input
    /// (anything else means the user moved on). System Settings is never treated so (see
    /// `systemSettingsBundleID`), and an app that was already running hides the panel through
    /// `onLaunched` instead.
    private func shouldStayOpenAfterLaunch() -> Bool {
        guard isShown, model.keepsPanelOpenAfterLaunch, !dragInProgress else { return false }
        guard Self.lastUserInput <= lastPanelInput + Self.inputClockSlack else { return false }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier == Self.systemSettingsBundleID { return false }
        if lastLaunchFromPanel >= lastPanelInput { return true }
        // The launched app may activate before its launch notification arrives.
        let now = Date()
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           let launched = front.launchDate {
            let launchedUptime = ProcessInfo.processInfo.systemUptime - now.timeIntervalSince(launched)
            return launchedUptime >= lastPanelInput - Self.inputClockSlack
        }
        return false
    }
}
