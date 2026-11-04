import AppKit
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
    static let fallbackSize = NSSize(width: GridMetrics.panelWidth, height: GridMetrics.panelHeight)

    /// A Dock click can first resign key (→ hide) and then call reopen (→ toggle). A reopen that
    /// arrives within this window after a Dock-caused hide is therefore the *same* click.
    private static let reopenGuardInterval: TimeInterval = 0.3
    /// While a tile drag is live, the panel must never be ordered out (it would cancel the session):
    /// a resign-key hide is deferred until the drag ends, and re-checked at this interval.
    private static let deferredHideRetryInterval: TimeInterval = 0.1
    /// If a drag stops reporting and the mouse button has been up for this long, its end callback
    /// was lost: restore the panel state (nothing else can clear a click-through panel).
    private static let dragWatchdogDelay: TimeInterval = 2

    private let model: GridModel
    private let panel: MenuFoldPanel
    private let glass = NSGlassEffectView()
    private let hostingView: NSHostingView<AnyView>
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

    private var activationObserver: NSObjectProtocol?
    private var dragWatchdog: Timer?
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
            .overlay {
                // Faint inner rim on top of the glass's own edge lighting, so the panel edge
                // stays crisp over busy or very light backgrounds.
                RoundedRectangle(cornerRadius: Theme.panelCorner, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            }
        hostingView = NSHostingView(rootView: AnyView(root))
        hostingView.sizingOptions = [.intrinsicContentSize]

        panel = MenuFoldPanel(
            contentRect: NSRect(origin: .zero, size: Self.fallbackSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()
        configurePanel()
        observeAppDrags()
        // Coming back to MenuFold (Dock click, ⌘-Tab) ends any "this click came from the Dock" guess.
        // `didBecomeActiveNotification` is the ObjC `NSApplicationDidBecomeActiveNotification`.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastHideWasDockClick = false }
        }
    }

    deinit {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        dragWatchdog?.invalidate()
        deferredHideRetryTask?.cancel()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        // Resign-key already hides the panel; a second, AppKit-driven hide could desync `isShown`.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self
        // Esc closes an open folder first (the search field can swallow SwiftUI's onKeyPress), then the panel.
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.model.openFolderID != nil {
                NotificationCenter.default.post(name: .menuFoldFolderEscape, object: nil)
                withAnimation(Theme.morph) { self.model.openFolderID = nil }
            } else {
                self.hide()
            }
        }

        // A plain container as the window's content view: AppKit manages the geometry of the
        // content view's own layer, so the animated layer is one level down (the glass view).
        let container = NSView(frame: NSRect(origin: .zero, size: Self.fallbackSize))
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

    private var contentSize: NSSize {
        let fitting = hostingView.fittingSize
        return fitting.width > 10 && fitting.height > 10 ? fitting : Self.fallbackSize
    }

    // MARK: Show / hide

    func toggle() {
        if isShown {
            hide()
        } else if !wasHiddenByThisDockClick {
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

    func show() {
        let anchor = NSEvent.mouseLocation
        model.panelDidOpen()

        let size = contentSize
        let frame = DockGeometry.panelFrame(size: size, anchor: anchor)

        // Reopening is the newer intent, so a hide that is still waiting for a drag to end is dropped.
        cancelDeferredHide()
        // A show is always a full reset of the window state: a lost drag-end callback, a deferred
        // drag hide or a half-faded window must not leak into this presentation.
        if dragInProgress { endDragState() }
        dragPassthrough = false
        panel.ignoresMouseEvents = false
        hideInFlight = false
        lastHideWasDockClick = false

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
                return
            }
            // Also gives focus back to the previous app unless another MenuFold window (Settings) is open.
            self.resetAfterHide()
        }
    }

    /// Classifies a resign-key hide as "the user clicked the Dock". See `wasHiddenByThisDockClick`.
    private static func isDockClickHide(reason: HideReason) -> Bool {
        guard reason == .resignedKey else { return false }
        // A left/right Dock is not detected (see `DockGeometry.isNearDock`), so the guard stays off.
        guard DockGeometry.orientation == .bottom else { return false }
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

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            sharpen.duration = 0.3
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
    private func animateOut(completion: @escaping @MainActor (Int) -> Void) {
        motionGeneration += 1
        let generation = motionGeneration
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
    }

    private func setDragPassthrough(_ on: Bool) {
        if on { dragInProgress = true }
        startDragWatchdog()
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
        hide(reason: .resignedKey)
    }
}
