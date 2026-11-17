import Foundation

/// Turns a two-finger horizontal scroll gesture into at most one tab step.
/// Feed it the precise deltas of one gesture (reset on `began`); it answers once, the moment the
/// horizontal travel passes `threshold` while the motion is still mostly horizontal.
public struct SwipeAccumulator: Equatable, Sendable {
    public var threshold: Double
    /// Horizontal travel must exceed vertical travel by this factor.
    public var dominance: Double
    private var sumX = 0.0
    private var sumY = 0.0
    private var finished = false

    public init(threshold: Double = 60, dominance: Double = 2) {
        self.threshold = threshold
        self.dominance = dominance
    }

    /// Forget the current gesture.
    public mutating func reset() { sumX = 0; sumY = 0; finished = false }

    /// - Returns: `+1` (next tab: content swiped left), `-1` (previous), or nil. Fires once per gesture.
    public mutating func add(dx: Double, dy: Double) -> Int? {
        guard !finished else { return nil }
        sumX += dx
        sumY += dy
        let ax = abs(sumX), ay = abs(sumY)
        // Clearly vertical: this gesture belongs to the grid's scrolling.
        if ay > threshold / 2, ay >= ax { finished = true; return nil }
        guard ax >= threshold, ax >= ay * dominance else { return nil }
        finished = true
        return sumX < 0 ? 1 : -1
    }

    /// True once the gesture was decided (fired or rejected as vertical).
    public var isFinished: Bool { finished }
}

/// Turns a pinch (magnification deltas) into discrete size steps, one per `threshold`.
public struct PinchAccumulator: Equatable, Sendable {
    public var threshold: Double
    private var sum = 0.0

    public init(threshold: Double = 0.25) { self.threshold = threshold }

    public mutating func reset() { sum = 0 }

    /// - Returns: `+1` for a pinch out (zoom in), `-1` for a pinch in, nil otherwise. The sum restarts
    ///   after each step, so a long pinch gives several steps, one per threshold.
    public mutating func add(_ magnification: Double) -> Int? {
        sum += magnification
        if sum >= threshold { sum = 0; return 1 }
        if sum <= -threshold { sum = 0; return -1 }
        return nil
    }
}
