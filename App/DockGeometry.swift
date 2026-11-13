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

    /// Whether `point` (default: the current mouse location) is in the Dock area, for any Dock
    /// orientation.
    ///
    /// Two checks, both required:
    /// 1. A band along the Dock's edge (bottom, left or right, from `orientation`) of the screen under
    ///    the point. The band alone is not enough for a side Dock: macOS keeps a left/right Dock on one
    ///    display only, and the band would also arm on the matching edge of every other screen.
    /// 2. The point is over a visible window of the Dock process (`dockWindowFrames`). At the moment of
    ///    a real Dock click the Dock is on screen (even with auto-hide, the pointer revealed it), so
    ///    this tells the Dock's display from the others. If the probe finds no Dock window at all (it
    ///    can't read the window list), only the band decides, but a bottom Dock is then the only one
    ///    trusted, since a side band on the wrong display would swallow a real click.
    @MainActor
    static func isNearDock(_ point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = screen(containing: point) else { return false }
        let side = orientation
        guard isNearDock(point, screenFrame: screen.frame, visibleFrame: screen.visibleFrame,
                         orientation: side, dockBand: dockBand) else { return false }
        let frames = dockWindowFrames()
        if frames.isEmpty { return side == .bottom }
        return frames.contains { contains($0, point, tolerance: dockProximity) }
    }

    /// Band along the Dock edge of one screen: Dock thickness = the larger of the visible-frame inset
    /// on that edge (≈0 when the Dock auto-hides) and `dockBand`, plus `dockProximity`. Both parts are
    /// clamped to `maxDockSize`.
    static func isNearDock(_ point: NSPoint, screenFrame: NSRect, visibleFrame: NSRect,
                           orientation: Orientation = .bottom, dockBand: CGFloat = 0) -> Bool {
        let inset: CGFloat
        let distance: CGFloat
        switch orientation {
        case .bottom:
            inset = visibleFrame.minY - screenFrame.minY
            distance = point.y - screenFrame.minY
        case .left:
            inset = visibleFrame.minX - screenFrame.minX
            distance = point.x - screenFrame.minX
        case .right:
            inset = screenFrame.maxX - visibleFrame.maxX
            distance = screenFrame.maxX - point.x
        }
        let thickness = min(max(inset.isFinite ? inset : 0, dockBand.isFinite ? dockBand : 0), maxDockSize)
        return distance <= thickness + dockProximity
    }

    /// Frames (AppKit screen coordinates) of the Dock process's visible windows at the Dock window
    /// level. Window bounds and owner PIDs need no Screen Recording permission (only titles do).
    @MainActor
    static func dockWindowFrames() -> [NSRect] {
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .map(\.processIdentifier))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        return info.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, dockPIDs.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == dockLevel,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            // CG window bounds are top-left based on the primary screen.
            return NSRect(x: bounds.minX, y: primary.frame.maxY - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
    }

    /// Whether `point` is near the Dock band of its screen for DRAG purposes (pinning to the Dock).
    /// Band only, no window probe: the drag code runs its own authoritative CGWindowList probe
    /// (`AppDragSource.isDockWindow`), and the Dock simply rejects a drop that is not on it.
    @MainActor
    static func isNearDockForDrag(_ point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard let screen = screen(containing: point) else { return false }
        return isNearDock(point, screenFrame: screen.frame, visibleFrame: screen.frame,
                          orientation: orientation, dockBand: dockBand)
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
