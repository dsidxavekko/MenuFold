import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Auto-scroll while dragging an app tile near the top/bottom edge of a ScrollView.
//
// Hot zones are thin overlays at the scroll view's edges with an `.onDrop` delegate that runs a
// 60 Hz timer while the pointer is inside. SwiftUI only routes drops to hit-testable views, so
// drop hit-testing is off by default (clicks/hover reach the tiles underneath) and is switched on
// by `DragActivity`, whose ONLY signal is a real drag session: `AppDropDelegate` reports when a
// MenuFold drag enters/leaves the tile grid, and the session reports when the drag ends. A generic
// "mouse is down and moved" detector must NOT arm the zones (bug 5): it would hijack the
// scrollbar drag, text selection in the search field and folder-title editing, because this whole
// technique also consumes pointer events in the strip, not just drop routing.
// A zone also switches off once its edge is reached, so a tile in the first/last row stays
// droppable.

/// The per-drag state that decides whether the auto-scroll zones take hit-testing.
///
/// Deliberately NOT a mouse-drag detector: it is set only around a MenuFold tile drag
/// (`AppDropDelegate` calls `setActive(true)` when the drag enters the grid and `setActive(false)`
/// when it leaves or drops), so a scrollbar drag or a text selection never arms it.
///
/// `isActive` is observed by the edge zones; the end of the drag is confirmed by watching
/// `AppDragSession.shared.appID` (`watchSession`) and, as a last resort, by a button-state poll.
@MainActor
@Observable
final class DragActivity {
    static let shared = DragActivity()

    /// True while a MenuFold tile drag is alive (set by the drop delegate, cleared as soon as the
    /// shared session ends — see `watchSession`).
    private(set) var isActive = false

    /// Safety net for the case where parsing a session end is missed: clears a dangling "active"
    /// state. Does no work at all while `isActive` is false.
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var isWatchingSession = false

    private init() {}

    func setActive(_ active: Bool) {
        if active == isActive { return }
        isActive = active
        poll?.invalidate()
        poll = nil
        if active {
            startPoll()
            watchSession()
        }
    }

    /// Arms exactly when the drop delegate arms the zones, instead of during every mouse drag.
    private func watchSession() {
        guard !isWatchingSession else { return }
        isWatchingSession = true
        withObservationTracking {
            _ = AppDragSession.shared.appID
        } onChange: { [weak self] in
            // `onChange` fires before the change lands; re-check on the next main-actor turn.
            Task { @MainActor in
                guard let self else { return }
                self.isWatchingSession = false
                if AppDragSession.shared.appID == nil { self.setActive(false) }
                else if self.isActive { self.watchSession() }
            }
        }
    }

    /// Only used by the edge zones; the drag end is normally reported by the session.
    private func startPoll() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Drag ended without a report (drag loop cancelled, app switched): stop.
                if NSEvent.pressedMouseButtons & 1 == 0 { self.setActive(false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }
}

/// Owns the scroll position and the repeating scroll timer for one ScrollView.
@MainActor
@Observable
final class EdgeAutoScroller {
    var position = ScrollPosition()
    /// Only flip when the value changes, so per-tick offset updates don't invalidate views.
    private(set) var canScrollUp = false
    private(set) var canScrollDown = false

    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var minOffset: CGFloat = 0
    @ObservationIgnored private var maxOffset: CGFloat = 0
    /// Signed points per tick (negative = up).
    @ObservationIgnored private var velocity: CGFloat = 0
    @ObservationIgnored private var timer: Timer?

    static let zoneHeight: CGFloat = 44
    private static let minSpeed: CGFloat = 4
    private static let maxSpeed: CGFloat = 20

    func update(_ metrics: ScrollMetrics) {
        offset = metrics.offset
        minOffset = metrics.minOffset
        maxOffset = metrics.maxOffset
        let up = offset > minOffset + 0.5
        let down = offset < maxOffset - 0.5
        if up != canScrollUp { canScrollUp = up }
        if down != canScrollDown { canScrollDown = down }
    }

    /// `distance` = pointer distance from the scroll view's edge, 0…zoneHeight.
    func drive(up: Bool, distance: CGFloat) {
        let t = 1 - min(max(distance / Self.zoneHeight, 0), 1)
        let speed = Self.minSpeed + (Self.maxSpeed - Self.minSpeed) * t
        velocity = up ? -speed : speed
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // `.common` so it keeps firing in the event-tracking run loop mode used by drag sessions.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        velocity = 0
    }

    private func tick() {
        // Drag released anywhere (including outside the window) → stop.
        guard NSEvent.pressedMouseButtons & 1 != 0, velocity != 0 else { return stop() }
        let target = min(max(offset + velocity, minOffset), maxOffset)
        guard target != offset else { return stop() }
        offset = target
        position.scrollTo(y: target)
    }
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var minOffset: CGFloat
    var maxOffset: CGFloat

    init(_ g: ScrollGeometry) {
        offset = g.contentOffset.y
        minOffset = -g.contentInsets.top
        maxOffset = max(minOffset, g.contentSize.height + g.contentInsets.bottom - g.containerSize.height)
    }
}

/// Drop delegate for one hot zone. Never accepts the drop.
private struct EdgeScrollDropDelegate: DropDelegate {
    let scroller: EdgeAutoScroller
    let up: Bool
    let height: CGFloat
    /// `allowsHitTesting(false)` does not stop SwiftUI drop routing, so gate drops explicitly.
    let isActive: Bool

    /// Only MenuFold app drags: a foreign drop is left for the views underneath (bug 6).
    func validateDrop(info: DropInfo) -> Bool {
        isActive && info.hasItemsConforming(to: [.menuFoldAppID])
    }

    func dropEntered(info: DropInfo) { drive(info) }

    /// Never propose `.move` while inactive: a proposal that is not followed by a successful
    /// `performDrop` makes the tile fly back, i.e. the drop is silently swallowed (bug 6).
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isActive, info.hasItemsConforming(to: [.menuFoldAppID]) else { return nil }
        drive(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { scroller.stop() }

    /// The strip is only a scroll trigger: not accepting keeps the drag alive.
    func performDrop(info: DropInfo) -> Bool {
        scroller.stop()
        return false
    }

    private func drive(_ info: DropInfo) {
        scroller.drive(up: up, distance: Self.distance(from: info.location, height: height, up: up))
    }

    /// Distance from the edge the zone sits on, 0…`height`, where 0 = at the edge = fastest
    /// (`EdgeAutoScroller.drive` contract).
    ///
    /// `DropInfo.location` is expressed in the zone view's own coordinate space, and the zone is a
    /// plain `Color.clear.frame(height:)` pinned by `.overlay(alignment:)`, so its space has NO
    /// offsets or flips of its own: y = 0 is the zone's leading (top) edge and y grows downward.
    /// That makes the mapping independent of the undocumented parts of `DropInfo`'s space — only
    /// which physical edge y = 0 is on matters, and that is the zone's own top edge in both cases:
    /// - top zone: its top edge IS the scroll view's top edge, so the distance to that edge is `y`
    ///   (0 at the edge, `height` at the inner boundary);
    /// - bottom zone: its top edge is the inner boundary and its bottom edge (y = height) is the
    ///   scroll view's bottom edge, so the distance to that edge is `height - y`
    ///   (`height` inside, 0 at the very edge).
    /// Checked numerically for height = 44 (zone = 44, speed 4…20 px/s):
    ///   top    y = 0 → 0 (20 px/s up) … y = 44 → 44 (4 px/s up)
    ///   bottom y = 0 → 44 (4 px/s down) … y = 44 → 0 (20 px/s down)
    /// i.e. monotonic toward each edge, never inverted. Clamping guards against the drop location
    /// briefly leaving the 0…height band between events, which would otherwise invert the speed
    /// for a tick.
    static func distance(from location: NSPoint, height: CGFloat, up: Bool) -> CGFloat {
        let y = min(max(location.y, 0), height)
        return up ? y : height - y
    }
}

private struct EdgeAutoScrollModifier: ViewModifier {
    var isEnabled: Bool
    @State private var scroller = EdgeAutoScroller()
    private let drag = DragActivity.shared
    /// The real signal: a MenuFold tile drag. `isActive` is armed only by the tile drop delegate
    /// (never by a plain mouse drag), and the shared session holds the dragged app id; both are
    /// observed, so a missed drag-end report still disarms the zones.
    private var dragInProgress: Bool {
        drag.isActive && AppDragSession.shared.appID != nil
    }

    /// The private type put on the pasteboard by `AppDragSourceView`.
    private static let types: [UTType] = [.menuFoldAppID]

    func body(content: Content) -> some View {
        content
            .scrollPosition($scroller.position)
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { _, metrics in
                scroller.update(metrics)
            }
            // While a tile drag is in progress the zones become hit-testable (only if their edge
            // can still scroll). Outside a tile drag every condition is false, so a scroller drag
            // or a text selection in the strip goes to the real controls (bug 5).
            .overlay(alignment: .top) { zone(up: true, active: isEnabled && dragInProgress && scroller.canScrollUp) }
            .overlay(alignment: .bottom) { zone(up: false, active: isEnabled && dragInProgress && scroller.canScrollDown) }
            .onChange(of: dragInProgress) { _, dragging in
                if !dragging { scroller.stop() }
            }
            .onDisappear { scroller.stop() }
    }

    private func zone(up: Bool, active: Bool) -> some View {
        let height = EdgeAutoScroller.zoneHeight
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(Rectangle())
            .onDrop(of: Self.types, delegate: EdgeScrollDropDelegate(
                scroller: scroller, up: up, height: height, isActive: active))
            .allowsHitTesting(active)
            .onChange(of: active) { _, isActive in
                if !isActive { scroller.stop() }
            }
    }
}

extension View {
    /// Apply to a vertical `ScrollView`: scrolls automatically while an app is dragged near its edges.
    func autoScrollsWhileDragging(isEnabled: Bool = true) -> some View {
        modifier(EdgeAutoScrollModifier(isEnabled: isEnabled))
    }
}
