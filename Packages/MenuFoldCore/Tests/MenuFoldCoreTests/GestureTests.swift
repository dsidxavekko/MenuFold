import Testing
@testable import MenuFoldCore

@Suite struct GestureTests {
    @Test func swipeFiresOncePerGesture() {
        var s = SwipeAccumulator(threshold: 60)
        #expect(s.add(dx: -30, dy: 2) == nil)
        #expect(s.add(dx: -40, dy: 2) == 1)
        #expect(s.add(dx: -80, dy: 0) == nil)
        s.reset()
        #expect(s.add(dx: 70, dy: 0) == -1)
    }

    @Test func verticalScrollIsIgnored() {
        var s = SwipeAccumulator(threshold: 60)
        #expect(s.add(dx: 5, dy: 40) == nil)
        #expect(s.add(dx: 100, dy: 0) == nil)  // gesture already rejected
        #expect(s.isFinished)
    }

    @Test func diagonalBelowDominanceDoesNotFire() {
        var s = SwipeAccumulator(threshold: 60)
        #expect(s.add(dx: 70, dy: 50) == nil)
    }

    @Test func pinchStepsPerThreshold() {
        var p = PinchAccumulator(threshold: 0.25)
        #expect(p.add(0.1) == nil)
        #expect(p.add(0.2) == 1)
        #expect(p.add(0.1) == nil)
        #expect(p.add(-0.4) == -1)
    }
}
