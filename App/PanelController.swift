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
    static let reopenGuardInterval: TimeInterval = 0.3
    /// While a tile drag is live, the panel must never be ordered out (it would cancel the session):
    /// a resign-key hide is deferred until the drag ends, and re-checked at this interval.
    static let deferredHideRetryInterval: TimeInterval = 0.1
    /// If a drag stops reporting and the mouse button has been up for this long, its end callback
    /// was lost: restore the panel state (nothing else can clear a click-through panel).
    static let dragWatchdogDelay: TimeInterval = 2
    /// Input events that end the keep-open grace (a mouse click or a key press anywhere).
    static let userInputEventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    /// Clock slack between an event's timestamp and the HID system's "last event" time.
    static let inputClockSlack: TimeInterval = 0.05
    /// System Settings: opening a pane from the search must let the user see it (no keep-open grace).
    static let systemSettingsBundleID = "com.apple.systempreferences"

    let model: GridModel
    let panel: MenuFoldPanel
    let glass = NSGlassEffectView()
    let hostingView: NSHostingView<AnyView>
    /// The SwiftUI root, kept so the tree can be rebuilt after `unloadViewsWhenIdle` dropped it.
    let rootContent: AnyView
    var unloadTask: Task<Void, Never>?
    var viewsUnloaded = false
    /// How long the panel stays hidden before its SwiftUI tree is torn down to give the memory back.
    static let unloadDelay: Duration = .seconds(30)
    var lastHide: Date = .distantPast
    /// Whether the last hide was caused by a click in the Dock area (see `hide(reason:)`).
    var lastHideWasDockClick = false
    var hideInFlight = false
    var isShown = false
    /// A tile drag is outside the panel: the window is dimmed and click-through.
    var dragPassthrough = false
    /// `AppDragSession.appID != nil`, as last reported by the drag session.
    var dragInProgress = false
    /// A hide asked for while a drag was live, applied when the drag ends.
    var hideDeferredByDrag: HideReason?
    /// Bumped by every open/close so a stale animation completion can't undo a newer one.
    var motionGeneration = 0

    /// Set while `onEnded` closes the panel after a drag-out. `hide()` postpones itself while a drag
    /// is live (ordering out mid-drag would cancel the session), but this hide *is* the drag's end.
    var inDragEnd = false

    // The notification and event-monitor tokens are only written on the main actor (in the methods
    // below) but `nonisolated(unsafe)` so `deinit`, which is nonisolated for a `@MainActor` class,
    // can uninstall them: by then the last reference is gone, so no other thread can be using them.
    nonisolated(unsafe) var activationObserver: NSObjectProtocol?
    nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) var keyMonitor: Any?
    var gestures: PanelGestures?
    /// Records `lastPanelInput` (mouse-downs and key presses in the panel).
    nonisolated(unsafe) var panelInputMonitor: Any?
    nonisolated(unsafe) var preferencesObserver: NSObjectProtocol?
    nonisolated(unsafe) var launchObserver: NSObjectProtocol?
    /// System uptime of the last mouse-down / key press in the panel (the click or Return that
    /// launched an app, in keep-open mode). `NSEvent.timestamp` uses the same clock.
    var lastPanelInput: TimeInterval = -.infinity
    /// System uptime at which an app launched while the panel was up (keep-open mode); `-infinity`
    /// when no launch is pending. Only counts while it is newer than `lastPanelInput`.
    var lastLaunchFromPanel: TimeInterval = -.infinity
    /// Like the observer tokens above: written on the main actor, invalidated from `deinit`.
    nonisolated(unsafe) var dragWatchdog: Timer?
    var deferredHideRetryTask: Task<Void, Never>?

    static let scaleKey = "menuFold.panelScale"
    static let blurKey = "menuFold.panelBlur"
    static let blurFilterName = "panelBlur"

    /// Window alpha when fully presented: dimmed while a drag hovers outside the panel.
    var presentedAlpha: CGFloat { dragPassthrough ? 0.15 : 1 }

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

    func configurePanel() {
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
    func resizeIfNeeded() {
        guard isShown else { return }
        // Stay on the screen the panel is on, whatever the screen policy says.
        let anchor = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        DockGeometry.fitGrid(anchor: anchor, policy: .cursor)
        let size = Self.panelSize
        guard panel.frame.size != size else { return }
        panel.setFrame(DockGeometry.panelFrame(size: size, anchor: anchor, policy: .cursor), display: true)
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
    var wasHiddenByThisDockClick: Bool {
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
    func observeLaunchesForKeepOpen() {
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
    static var lastUserInput: TimeInterval {
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
    func shouldStayOpenAfterLaunch() -> Bool {
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
