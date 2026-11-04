import AppKit

/// Panel placement (centered on the clicked screen) and Dock-area detection.
enum DockGeometry {
    enum Orientation: String {
        case bottom, left, right
    }

    /// Gap between the panel and the Dock edge of `visibleFrame` (and the screen edges when clamping).
    static let gap: CGFloat = 8
    /// Slack beyond the Dock band that still counts as "clicked the Dock icon".
    static let dockProximity: CGFloat = 16
    /// A real Dock is at most tile size × magnification + padding; anything above this is a corrupt
    /// or hostile `com.apple.dock` value, which must not turn the whole screen into "the Dock area".
    static let maxDockSize: CGFloat = 200

    /// Thickness of the Dock's icon row from its `tilesize` (default 48), or the magnified
    /// `largesize` when magnification is on, plus padding.
    /// Needed because with auto-hide `visibleFrame` doesn't reserve any space for the Dock.
    static var dockBand: CGFloat {
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let tile = dock?.double(forKey: "tilesize") ?? 0
        var size = (tile.isFinite && tile > 0) ? tile : 48
        if dock?.bool(forKey: "magnification") == true,
           let large = dock?.double(forKey: "largesize"), large.isFinite, large > size {
            size = large
        }
        return CGFloat(min(size, maxDockSize)) + 24
    }

    /// Dock orientation from `defaults read com.apple.dock orientation` (bottom when unset/unknown).
    static var orientation: Orientation {
        let raw = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
        return raw.flatMap(Orientation.init(rawValue:)) ?? .bottom
    }

    /// Screen containing `point` (falls back to the main screen).
    static func screen(containing point: NSPoint) -> NSScreen? {
        // Inclusive on every edge with 1 pt of slack: the mouse at the very bottom row of the screen
        // (y == frame.minY) is excluded by NSMouseInRect.
        NSScreen.screens.first { contains($0.frame, point, tolerance: 1) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func contains(_ rect: NSRect, _ p: NSPoint, tolerance: CGFloat) -> Bool {
        p.x >= rect.minX - tolerance && p.x <= rect.maxX + tolerance
            && p.y >= rect.minY - tolerance && p.y <= rect.maxY + tolerance
    }

    /// Whether `point` (default: the current mouse location) is in the Dock area.
    ///
    /// Only the *bottom* edge is checked, on purpose. macOS keeps a left/right Dock on a single
    /// display, but the app can't tell which display hosts it, so honouring `.left`/`.right` used to
    /// arm the "clicked the Dock" logic on the matching edge of *every* screen (a false positive that
    /// swallows the user's real Dock click). The bottom-only rule errs the other way: with a side
    /// Dock the guard simply never arms, which costs at most one redundant reopen. `visibleFrame`
    /// still measures a side Dock correctly, so nothing here is ever armed wrongly.
    @MainActor
    static func isNearDock(_ point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = screen(containing: point) else { return false }
        return isNearDock(point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame, dockBand: dockBand)
    }

    /// Bottom band of one screen: Dock thickness = the larger of the visible-frame inset (≈0 when the
    /// Dock auto-hides) and `dockBand`, plus `dockProximity`. Both parts are clamped to `maxDockSize`.
    static func isNearDock(_ point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect, dockBand: CGFloat = 0) -> Bool {
        let inset = visibleFrame.minY - screenFrame.minY
        let thickness = min(max(inset.isFinite ? inset : 0, dockBand.isFinite ? dockBand : 0), maxDockSize)
        return point.y - screenFrame.minY <= thickness + dockProximity
    }

    /// Frame for a panel of `size` on the screen under the current mouse location.
    @MainActor
    static func panelFrame(size: NSSize, anchor: NSPoint = NSEvent.mouseLocation) -> NSRect {
        guard let screen = screen(containing: anchor) else {
            return NSRect(origin: .zero, size: size)
        }
        return panelFrame(size: size, anchor: anchor, screenFrame: screen.frame,
                          visibleFrame: screen.visibleFrame, orientation: orientation, dockBand: dockBand)
    }

    /// Pure placement (Cocoa coordinates, origin bottom-left): always centered in `visibleFrame`
    /// of the screen under the anchor (user preference, like the old Launchpad), clamped by `gap`.
    /// `orientation`/`dockBand` are kept for callers; Dock proximity only matters for the reopen guard.
    static func panelFrame(size: NSSize, anchor: NSPoint, screenFrame: NSRect,
                           visibleFrame: NSRect, orientation: Orientation, dockBand: CGFloat = 0) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: gap, dy: gap)
        var origin = NSPoint(x: visibleFrame.midX - size.width / 2,
                             y: visibleFrame.midY - size.height / 2)
        origin.x = clamp(origin.x, bounds.minX, bounds.maxX - size.width)
        origin.y = clamp(origin.y, bounds.minY, bounds.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        // If the panel is larger than the bounds, pin to the low edge.
        hi < lo ? lo : min(max(v, lo), hi)
    }
}
