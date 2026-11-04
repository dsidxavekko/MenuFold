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

    private let model: GridModel
    private let panel: MenuFoldPanel
    private let glass = NSGlassEffectView()
    private let hostingView: NSHostingView<AnyView>
    private var lastHide: Date = .distantPast
    /// Whether the last hide was a resign-key with the mouse in the Dock area (i.e. likely a Dock click).
    private var lastHideWasNearDock = false
    private var hideInFlight = false
    private(set) var isShown = false
    /// A tile drag is outside the panel: the window is dimmed and click-through.
    private var dragPassthrough = false
    /// Bumped by every open/close so a stale animation completion can't undo a newer one.
    private var motionGeneration = 0

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
        } else if !(lastHideWasNearDock && Date().timeIntervalSince(lastHide) <= 0.3) {
            // A Dock click can first resign key (→ hide) and then call reopen (→ toggle);
            // don't immediately reopen in that case.
            show()
        }
    }

    func show() {
        let anchor = NSEvent.mouseLocation
        model.panelDidOpen()

        let size = contentSize
        let frame = DockGeometry.panelFrame(size: size, anchor: anchor)

        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        isShown = true
        hideInFlight = false

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        animateIn()
    }

    func hide(reason: HideReason = .dismissed) {
        // Act on the real window state too, so `isShown` and the panel can't drift apart;
        // but don't restart a fade-out that is already running (it would lose its reason).
        guard isShown || (panel.isVisible && !hideInFlight) else { return }
        isShown = false
        hideInFlight = true
        lastHide = Date()
        lastHideWasNearDock = reason == .resignedKey && DockGeometry.isNearDock(NSEvent.mouseLocation)

        let panel = panel
        animateOut { [weak self] in
            guard let self, !self.isShown else { return }
            self.hideInFlight = false
            panel.orderOut(nil)
            self.resetMotion()
            panel.alphaValue = 1
            // After an app launch, NSApp.hide would race the launched app's activation.
            guard reason != .appLaunched else { return }
            // Give focus back to the previous app unless another MenuFold window (Settings) is open.
            let otherVisible = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
            if !otherVisible, NSApp.isActive { NSApp.hide(nil) }
        }
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
    private func animateOut(completion: @escaping @MainActor () -> Void) {
        motionGeneration += 1
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
            MainActor.assumeIsolated { completion() }
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
            self.panel.ignoresMouseEvents = false
            if droppedOutside {
                self.dragPassthrough = false
                // Fades out from the current (dimmed) alpha; the completion restores alpha 1.
                self.hide()
            } else {
                self.setDragPassthrough(false)
            }
        }
    }

    private func setDragPassthrough(_ on: Bool) {
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

    // MARK: NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        hide(reason: .resignedKey)
    }
}

