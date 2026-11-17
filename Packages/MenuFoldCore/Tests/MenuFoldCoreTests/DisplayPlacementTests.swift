import CoreGraphics
import Testing
@testable import MenuFoldCore

@Suite struct DisplayPlacementTests {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let side = CGRect(x: 1440, y: 0, width: 1920, height: 1080)

    @Test func cursorPicksScreenUnderPointer() {
        let i = DisplayPlacement.screenIndex(policy: .cursor, screenFrames: [main, side], cursor: CGPoint(x: 2000, y: 500))
        #expect(i == 1)
    }

    @Test func cursorOutsideFallsBackToPrimary() {
        let i = DisplayPlacement.screenIndex(policy: .cursor, screenFrames: [main, side], cursor: CGPoint(x: -500, y: 500))
        #expect(i == 0)
    }

    @Test func primaryIgnoresCursor() {
        let i = DisplayPlacement.screenIndex(policy: .primary, screenFrames: [side, main], primaryIndex: 1,
                                             cursor: CGPoint(x: 2000, y: 500))
        #expect(i == 1)
    }

    @Test func activeWindowUsesLargestOverlap() {
        let window = CGRect(x: 1300, y: 100, width: 800, height: 600) // mostly on `side`
        let i = DisplayPlacement.screenIndex(policy: .activeWindow, screenFrames: [main, side],
                                             cursor: CGPoint(x: 10, y: 10), activeWindowFrame: window)
        #expect(i == 1)
    }

    @Test func activeWindowWithoutWindowUsesCursor() {
        let i = DisplayPlacement.screenIndex(policy: .activeWindow, screenFrames: [main, side], cursor: CGPoint(x: 10, y: 10))
        #expect(i == 0)
    }

    @Test func noScreens() {
        #expect(DisplayPlacement.screenIndex(policy: .cursor, screenFrames: [], cursor: .zero) == nil)
    }

    @Test func fittedGridKeepsWhenRoomy() {
        let g = DisplayPlacement.fittedGrid(columns: 7, rows: 4, available: CGSize(width: 1400, height: 800))
        #expect(g.columns == 7 && g.rows == 4)
    }

    @Test func fittedGridShrinksOnSmallScreen() {
        let g = DisplayPlacement.fittedGrid(columns: 10, rows: 7, available: CGSize(width: 800, height: 500))
        #expect(g.columns == 6) // 844 - 108 = 736 <= 800
        #expect(g.rows == 3)    // 577 - 116 = 461 <= 500
    }

    @Test func fittedGridHasFloor() {
        let g = DisplayPlacement.fittedGrid(columns: 7, rows: 4, available: CGSize(width: 100, height: 100))
        #expect(g.columns == 3 && g.rows == 2)
    }
}
