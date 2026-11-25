import AppKit
import MenuFoldCore
import SwiftUI

extension PanelController {
    // MARK: Open / close motion

    /// Apps-launcher-like appear: window fades in while the glass springs 0.94 → 1 (slight
    /// overshoot) and the content sharpens from a small blur. Reduce Motion: fade only.
    ///
    /// The fade is on the window's `alphaValue` (so the window shadow fades with it); the scale and
    /// blur are explicit `CAAnimation`s that never change the layers' model values, so AppKit's
    /// own layer-geometry management can't fight them and nothing is left behind if they're cut off.
    func animateIn() {
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
    func animateOut(completion: @escaping @Sendable @MainActor (Int) -> Void) {
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
    func resetMotion() {
        glass.layer?.removeAnimation(forKey: Self.scaleKey)
        hostingView.layer?.removeAnimation(forKey: Self.blurKey)
        hostingView.layer?.filters = nil
    }

    /// A transform that scales `layer` around its visual centre, whatever its `anchorPoint`
    /// (AppKit-backed layers default to a (0, 0) anchor, and AppKit may reset it on layout).
    static func centeredScale(_ scale: CGFloat, of layer: CALayer) -> CATransform3D {
        let b = layer.bounds
        let dx = (0.5 - layer.anchorPoint.x) * b.width
        let dy = (0.5 - layer.anchorPoint.y) * b.height
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }
}
