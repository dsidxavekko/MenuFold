import AppKit
import SwiftUI
import UniformTypeIdentifiers

// AppKit drag source for app tiles.
//
// SwiftUI's `.draggable` offers no control over the drag operation mask, so a plain-String drag
// became a text clipping in Finder and could never become an alias or a Dock pin. Here an
// `NSDraggingSource` view sits over the tile's label and starts its own `NSDraggingSession`:
// - the pasteboard item carries the app's file URL (Finder, Dock) and a private type with the
//   bundle ID (internal drops). No plain text, so text views never receive the ID;
// - outside the app the mask is `.link` (Finder makes an alias, it can't move or copy), plus
//   `.generic` only while the pointer is over the Dock's own window (pinning);
// - inside the app the mask is `[.move, .generic]` (folder drops, auto-scroll zones).
// Mouse events that don't start a drag are forwarded to the hosting view, so the SwiftUI
// button (click to launch), hover and context menu keep working.

extension UTType {
    /// Private drag type: the dragged app's bundle ID (UTF-8). Declared in Info.plist.
    static let menuFoldAppID = UTType(exportedAs: "com.menufold.app-id")
}

extension NSPasteboard.PasteboardType {
    static let menuFoldAppID = NSPasteboard.PasteboardType(UTType.menuFoldAppID.identifier)
}

/// The app drag in progress (at most one), shared between the drag source, the internal drop
/// targets and the panel (which fades out while the drag is outside it).
@MainActor
@Observable
final class AppDragSession {
    static let shared = AppDragSession()

    /// Bundle ID of the app being dragged, or nil when no tile drag is in progress.
    private(set) var appID: String?
    /// Whether the pointer is currently outside the panel window.
    private(set) var isOutsidePanel = false
    /// Whether the pointer is over the Dock's window; widens the outside mask so the Dock can pin.
    private(set) var isOverDock = false

    /// Called when the pointer leaves (true) or re-enters (false) the panel during a drag.
    @ObservationIgnored var onOutsidePanelChanged: ((Bool) -> Void)?
    /// Called when the drag ends. `droppedOutside` = released outside the panel with an operation.
    @ObservationIgnored var onEnded: ((_ droppedOutside: Bool) -> Void)?

    @ObservationIgnored private weak var window: NSWindow?

    private init() {}

    func began(appID: String, in window: NSWindow?) {
        self.appID = appID
        self.window = window
        isOutsidePanel = false
        isOverDock = false
    }

    /// Ends the current drag immediately, without waiting for AppKit's callback.
    ///
    /// The panel calls this on paths where the drag loop is known to be gone (e.g. the window was
    /// ordered out under the pointer), so a latched `isOutsidePanel`/`isOverDock` — and the
    /// click-through window state that follows it — can never outlive the drag. Uses the current
    /// pointer as the end point and `.none` as the operation, i.e. "cancelled", so the panel is
    /// treated as not having received a drop. Safe to call when no drag is in progress.
    func forceEnd() {
        guard appID != nil || isOutsidePanel || isOverDock || window != nil else { return }
        ended(at: NSEvent.mouseLocation, operation: [])
    }

    func moved(to screenPoint: NSPoint) {
        isOverDock = Self.isDockWindow(at: screenPoint)
        let outside = !isInsidePanel(screenPoint)
        guard outside != isOutsidePanel else { return }
        isOutsidePanel = outside
        onOutsidePanelChanged?(outside)
    }

    /// Ends the drag. Safe to call more than once: the source view calls it from
    /// `draggingSession(_:endedAt:operation:)` and again from a `defer` after `beginDraggingSession`
    /// returns, in case AppKit ever skips the callback (bug 2). Every call ends with
    /// `appID == nil`, `isOverDock == false`, `isOutsidePanel == false` and `window == nil`, so the
    /// panel's click-through/dim state can never stay latched (bug 3).
    func ended(at screenPoint: NSPoint, operation: NSDragOperation) {
        let wasActive = appID != nil || isOutsidePanel || isOverDock || window != nil
        let droppedOutside = operation != [] && !isInsidePanel(screenPoint)
        // Tell the panel the pointer is back inside before ending, so it restores its alpha even
        // when the last `moved(to:)` was outside (above) and the drag then ended over the panel.
        if isOutsidePanel {
            isOutsidePanel = false
            onOutsidePanelChanged?(false)
        }
        appID = nil
        window = nil
        isOutsidePanel = false
        isOverDock = false
        // One `onEnded` per real drag: a repeated call (the `defer` safety net, or a double
        // callback) must not make the panel hide twice.
        guard wasActive else { return }
        onEnded?(droppedOutside)
    }

    private func isInsidePanel(_ point: NSPoint) -> Bool {
        guard let window else { return true }
        return window.frame.contains(point)
    }

    /// True when `point` (AppKit screen coordinates) is over a visible window of the Dock process
    /// at the Dock window level. Cheap pre-check on the Dock band first (any orientation — the
    /// probe below is authoritative).
    private static func isDockWindow(at point: NSPoint) -> Bool {
        guard DockGeometry.isNearDockForDrag(point) else { return false }
        guard let primary = NSScreen.screens.first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let dockPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .map(\.processIdentifier))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        // CG window bounds are top-left based on the primary screen.
        let cgPoint = CGPoint(x: point.x, y: primary.frame.maxY - point.y)
        return info.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, dockPIDs.contains(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == dockLevel,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return false }
            return bounds.contains(cgPoint)
        }
    }
}

/// Transparent NSView over a tile that turns a mouse drag into an AppKit dragging session.
final class AppDragSourceView: NSView, NSDraggingSource {
    /// The app this view currently represents; SwiftUI rewrites both in `updateNSView` when the
    /// representable is reused (tab switch, search, catalog refresh). Never read these after a
    /// mouse-down: use `pendingID`/`pendingURL`, which freeze the identity for that press (bug 1).
    var appID = ""
    var appURL: URL?

    private var mouseDownEvent: NSEvent?
    /// App identity captured in `mouseDown`. A representable reuse between the press and the 4 pt
    /// drag threshold would otherwise make the drag carry a different app's URL and bundle ID.
    private var pendingID = ""
    private var pendingURL: URL?
    private var isDragging = false
    private static let threshold: CGFloat = 4

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mouse (forward everything that isn't our drag to the hosting view)

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        clearPress()
        if !event.modifierFlags.contains(.control) {
            mouseDownEvent = event
            pendingID = appID
            pendingURL = appURL
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isDragging { return }
        guard let down = mouseDownEvent, let url = pendingURL else {
            super.mouseDragged(with: event)
            return
        }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > Self.threshold else {
            super.mouseDragged(with: event)
            return
        }
        isDragging = true
        cancelPress(after: down)
        startDrag(with: down, appID: pendingID, url: url)
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = mouseDownEvent != nil
        clearPress()
        if !isDragging, wasPressed { super.mouseUp(with: event) }
        isDragging = false
    }

    private func clearPress() {
        mouseDownEvent = nil
        pendingID = ""
        pendingURL = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        nextResponder?.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        nextResponder?.rightMouseUp(with: event)
    }

    /// The drag loop swallows the mouse-up, so end the SwiftUI button's press with a mouse-up far
    /// outside it: the press is cancelled (no launch) and no pressed state stays behind.
    private func cancelPress(after down: NSEvent) {
        guard let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: -10_000, y: -10_000),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: down.windowNumber,
            context: nil,
            eventNumber: down.eventNumber,
            clickCount: down.clickCount,
            pressure: 0
        ) else { return }
        super.mouseUp(with: up)
    }

    /// `appID`/`url` are the identity frozen in `mouseDown`, never the live representable values.
    private func startDrag(with event: NSEvent, appID: String, url: URL) {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(appID, forType: .menuFoldAppID)

        let size = GridMetrics.iconSize
        let point = convert(event.locationInWindow, from: nil)
        let dragItem = NSDraggingItem(pasteboardWriter: item)
        dragItem.setDraggingFrame(
            NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
            contents: MainActor.assumeIsolated { IconCache.shared.icon(appID: appID, url: url) }
        )

        // The session's `ended` is the only place that clears the drag state the panel reacts to
        // (click-through, dimmed alpha). `beginDraggingSession` runs the legacy drag loop and only
        // returns when the session is over, so the `defer` is a guaranteed safety net: if AppKit
        // skipped `draggingSession(_:endedAt:operation:)`, end the session here. `ended` is
        // idempotent and guards on the id, so the normal path is not affected (bug 2, bug 3).
        defer {
            let session = MainActor.assumeIsolated { AppDragSession.shared }
            if session.appID == appID {
                session.ended(at: NSEvent.mouseLocation, operation: [])
            }
            isDragging = false
            clearPress()
        }

        MainActor.assumeIsolated { AppDragSession.shared.began(appID: appID, in: window) }
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return [.move, .generic]
        case .outsideApplication:
            // Never .copy/.move (Finder would copy or move the bundle) and never .delete (Trash).
            // Finder treats .generic like a move, so it is offered only over the Dock.
            // Checked by hand on macOS 27: the Dock's Trash and folder stacks reject this mask
            // (nothing is moved, trashed or aliased), so .generic only enables pinning.
            let overDock = MainActor.assumeIsolated { AppDragSession.shared.isOverDock }
            return overDock ? [.link, .generic] : [.link]
        @unknown default:
            return []
        }
    }

    /// Modifier keys would otherwise filter the mask (Option → copy) down to nothing.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        MainActor.assumeIsolated { AppDragSession.shared.moved(to: screenPoint) }
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        clearPress()
        MainActor.assumeIsolated { AppDragSession.shared.ended(at: screenPoint, operation: operation) }
    }
}

/// SwiftUI wrapper; place it as an overlay on the tile's label (inside the Button).
struct AppDragSource: NSViewRepresentable {
    let appID: String
    let url: URL

    func makeNSView(context: Context) -> AppDragSourceView {
        let view = AppDragSourceView()
        view.appID = appID
        view.appURL = url
        return view
    }

    func updateNSView(_ view: AppDragSourceView, context: Context) {
        view.appID = appID
        view.appURL = url
    }
}

// MARK: Internal drop targets

/// Drop delegate accepting only MenuFold app drags (the private type). Proposes `.move`, which the
/// source allows within the app.
struct AppDropDelegate: DropDelegate {
    var isEnabled: Bool
    /// Validates a dropped bundle ID against the live catalog (see `appDropDestination`).
    var isKnownApp: (String) -> Bool = { _ in true }
    var setTargeted: (Bool) -> Void
    /// Receives the dropped bundle ID; returns whether the drop was handled.
    var perform: (String) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        isEnabled && info.hasItemsConforming(to: [.menuFoldAppID])
    }

    func dragEntered(info: DropInfo) {
        setTargeted(true)
        MainActor.assumeIsolated { DragActivity.shared.setActive(true) }
    }

    func dropEntered(info: DropInfo) {
        setTargeted(true)
        MainActor.assumeIsolated { DragActivity.shared.setActive(true) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) {
        setTargeted(false)
        MainActor.assumeIsolated { DragActivity.shared.setActive(false) }
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        MainActor.assumeIsolated { DragActivity.shared.setActive(false) }
        // The source is in this process: read the ID synchronously from the shared session.
        // `isKnownApp` rejects an id that is not in the catalog (stale drag, foreign pasteboard).
        if let id = MainActor.assumeIsolated({ AppDragSession.shared.appID }) {
            guard MainActor.assumeIsolated({ isKnownApp(id) }) else { return false }
            return MainActor.assumeIsolated { perform(id) }
        }
        // Fallback: load the private type from the pasteboard. This runs asynchronously, so the
        // world can change in between (tab switch, catalog refresh, drag cancelled): re-validate
        // the id against the live state instead of trusting the pasteboard (bug 7).
        guard let provider = info.itemProviders(for: [.menuFoldAppID]).first else { return false }
        // Read the closures out of `self` once (rather than shadowing the property names, which is
        // ambiguous: a local named like a property is "captured before it is declared").
        let apply: (String) -> Bool = perform
        let isLiveApp: (String) -> Bool = isKnownApp
        provider.loadDataRepresentation(forTypeIdentifier: UTType.menuFoldAppID.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                // A newer MenuFold drag is in progress: this stale id must not be applied.
                guard MainActor.assumeIsolated({ AppDragSession.shared.appID == nil }) else { return }
                guard MainActor.assumeIsolated({ isLiveApp(id) }) else { return }
                _ = apply(id)
            }
        }
        return true
    }
}

extension View {
    /// Accepts MenuFold app drags (bundle IDs) dropped on this view.
    /// `isKnownApp` validates a dropped id against the live catalog; pass `model.apps.contains`
    /// so a stale or foreign pasteboard id is ignored instead of applied.
    func appDropDestination(
        isEnabled: Bool = true,
        isKnownApp: @escaping (String) -> Bool = { _ in true },
        isTargeted: @escaping (Bool) -> Void,
        perform: @escaping (String) -> Bool
    ) -> some View {
        onDrop(of: [.menuFoldAppID],
               delegate: AppDropDelegate(isEnabled: isEnabled, isKnownApp: isKnownApp,
                                         setTargeted: isTargeted, perform: perform))
    }
}
