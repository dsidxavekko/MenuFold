import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

// Auto-scroll while dragging an app tile near the top/bottom edge of a ScrollView.
//
// Hot zones are thin overlays at the scroll view's edges with an `.onDrop` delegate that runs a
// 60 Hz timer while the pointer is inside. SwiftUI only routes drops to hit-testable views, so the
// zones are hit-testable *only while a mouse drag is in progress* (`DragActivity`); the rest of the
// time they are `allowsHitTesting(false)` and clicks/hover reach the tiles underneath. A zone also
// switches off once its edge is reached, so a tile in the first/last row stays droppable.

/// Tracks whether the left mouse button is down and has moved (i.e. a drag may be in progress).
/// Observes events through a local monitor without consuming them. The end of a drag session is
/// detected by polling the button state, because AppKit's drag loop swallows the mouse-up.
@MainActor
@Observable
final class DragActivity {
    static let shared = DragActivity()

    private(set) var isDragging = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var downLocation: NSPoint?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downLocation = NSEvent.mouseLocation
        case .leftMouseDragged:
            guard !isDragging, let start = downLocation else { return }
            let now = NSEvent.mouseLocation
            // Ignore click jitter; SwiftUI's own drag threshold is in the same range.
            if hypot(now.x - start.x, now.y - start.y) > 3 { begin() }
        case .leftMouseUp:
            end()
        default:
            break
        }
    }

    private func begin() {
        isDragging = true
        poll?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.end() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    private func end() {
        downLocation = nil
        poll?.invalidate()
        poll = nil
        if isDragging { isDragging = false }
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

    func validateDrop(info: DropInfo) -> Bool { isActive }

    func dropEntered(info: DropInfo) { drive(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        drive(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { scroller.stop() }

    func performDrop(info: DropInfo) -> Bool {
        scroller.stop()
        return false
    }

    private func drive(_ info: DropInfo) {
        let distance = up ? info.location.y : height - info.location.y
        scroller.drive(up: up, distance: distance)
    }
}

private struct EdgeAutoScrollModifier: ViewModifier {
    var isEnabled: Bool
    @State private var scroller = EdgeAutoScroller()
    private let drag = DragActivity.shared
    /// The private type put on the pasteboard by `AppDragSourceView`.
    private static let types: [UTType] = [.menuFoldAppID]

    func body(content: Content) -> some View {
        content
            .scrollPosition($scroller.position)
            .onScrollGeometryChange(for: ScrollMetrics.self, of: ScrollMetrics.init) { _, metrics in
                scroller.update(metrics)
            }
            .overlay(alignment: .top) { zone(up: true, active: isEnabled && drag.isDragging && scroller.canScrollUp) }
            .overlay(alignment: .bottom) { zone(up: false, active: isEnabled && drag.isDragging && scroller.canScrollDown) }
            .onChange(of: drag.isDragging) { _, dragging in
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
            .onDrop(of: Self.types, delegate: EdgeScrollDropDelegate(scroller: scroller, up: up, height: height, isActive: active))
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
