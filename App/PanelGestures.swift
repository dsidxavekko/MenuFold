import AppKit
import MenuFoldCore

/// Trackpad gestures in the panel: a two-finger horizontal swipe switches tabs, a pinch changes the
/// grid size. A local event monitor, installed by `PanelController`.
@MainActor
final class PanelGestures {
    private let model: GridModel
    private let panel: NSPanel
    private var swipe = SwipeAccumulator()
    private var pinch = PinchAccumulator()
    private var monitor: Any?
    /// True while the rest of a decided horizontal swipe is being swallowed.
    private var swallowing = false

    init(model: GridModel, panel: NSPanel) {
        self.model = model
        self.panel = panel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private var isAvailable: Bool {
        AppPreferences.shared.usesGestures
            && panel.isVisible
            && model.openFolderID == nil
            && model.query.isEmpty
            && model.pendingTrashAppID == nil
            && model.infoAppID == nil
            && !model.showsShortcutsHelp
    }

    /// Frame of the category tab strip in the panel's top-left coordinates (set by `CategoryTabs`).
    /// Over it the gestures stand aside, so the strip scrolls normally.
    static var tabStripFrame: CGRect = .zero

    private func isOverTabStrip(_ event: NSEvent) -> Bool {
        guard let height = panel.contentView?.bounds.height else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        return Self.tabStripFrame.contains(point)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === panel, isAvailable else { return false }
        if isOverTabStrip(event) {
            swallowing = false
            return false
        }
        switch event.type {
        case .scrollWheel: return handleScroll(event)
        case .magnify: return handleMagnify(event)
        default: return false
        }
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        // Momentum after the fingers lift is never a new gesture.
        if !event.momentumPhase.isEmpty { return swallowing }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            swipe.reset()
            swallowing = false
        }
        defer { if event.phase.contains(.ended) || event.phase.contains(.cancelled) { swallowing = false } }
        if swallowing { return true }
        if let step = swipe.add(dx: Double(event.scrollingDeltaX), dy: Double(event.scrollingDeltaY)) {
            swallowing = true
            model.cycleTab(by: step)
            return true
        }
        return false
    }

    private func handleMagnify(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) { pinch.reset() }
        guard let step = pinch.add(Double(event.magnification)) else { return true }
        // Pinch out = bigger tiles = fewer columns and rows.
        let prefs = AppPreferences.shared
        let columns = min(max(prefs.columns - step, AppPreferences.columnRange.lowerBound), AppPreferences.columnRange.upperBound)
        let rows = min(max(prefs.rows - step, AppPreferences.rowRange.lowerBound), AppPreferences.rowRange.upperBound)
        // The panel resizes through the preferences-changed notification (`PanelController.resizeIfNeeded`).
        if columns != prefs.columns { prefs.columns = columns }
        if rows != prefs.rows { prefs.rows = rows }
        return true
    }
}
