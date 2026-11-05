import Testing
@testable import MenuFoldCore

@Suite struct GridNavigationTests {
    func mv(_ i: Int?, _ sections: [Int], _ d: MoveDirection, cols: Int = 3) -> Int? {
        GridNavigation.move(from: i, sections: sections, columns: cols, direction: d)
    }

    @Test func nilStartAndEmpty() {
        for d in [MoveDirection.up, .down, .left, .right] {
            #expect(mv(nil, [5], d) == 0)
            #expect(mv(nil, [0, 2], d) == 0)
            #expect(mv(nil, [], d) == nil)
            #expect(mv(nil, [0, 0], d) == nil)
            #expect(mv(3, [0], d) == nil)
            // Out of range → as nil.
            #expect(mv(9, [5], d) == 0)
            #expect(mv(-1, [5], d) == 0)
        }
    }

    @Test func leftRight() {
        // [3] + [7]: rows (0 1 2) | (3 4 5) (6 7 8) (9)
        let s = [3, 7]
        #expect(mv(0, s, .left) == 0)
        #expect(mv(9, s, .right) == 9)
        #expect(mv(1, s, .right) == 2)
        #expect(mv(2, s, .right) == 3) // crosses into the next section
        #expect(mv(3, s, .left) == 2)
        #expect(mv(5, s, .right) == 6) // crosses rows
        #expect(mv(6, s, .left) == 5)
    }

    @Test func upDownKeepColumnAndClamp() {
        // One section of 8, 3 columns: (0 1 2) (3 4 5) (6 7)
        let s = [8]
        #expect(mv(1, s, .down) == 4)
        #expect(mv(4, s, .up) == 1)
        #expect(mv(5, s, .down) == 7) // short last row → clamp
        #expect(mv(6, s, .down) == 6) // bottom: stay
        #expect(mv(2, s, .up) == 2)   // top: stay
        #expect(mv(7, s, .up) == 4)
    }

    @Test func crossingSections() {
        // [2] + [7]: (0 1) | (2 3 4) (5 6 7) (8)
        let s = [2, 7]
        #expect(mv(1, s, .down) == 3)  // same column
        #expect(mv(0, s, .down) == 2)
        #expect(mv(4, s, .up) == 1)    // column 2 clamped to last of the short row
        #expect(mv(3, s, .up) == 1)
        #expect(mv(2, s, .up) == 0)
        // Up into a multi-row section lands on its LAST row.
        // [5] + [3]: (0 1 2) (3 4) | (5 6 7)
        #expect(mv(5, [5, 3], .up) == 3)
        #expect(mv(7, [5, 3], .up) == 4) // clamped
        #expect(mv(4, [5, 3], .down) == 6)
        #expect(mv(2, [5, 3], .down) == 4) // short next row in the same section → clamp
    }

    @Test func emptySectionSkipped() {
        // [2] + [] + [4]: (0 1) | | (2 3 4) (5)
        let s = [2, 0, 4]
        #expect(mv(1, s, .down) == 3)
        #expect(mv(3, s, .up) == 1)
        #expect(mv(1, s, .right) == 2)
        #expect(mv(2, s, .left) == 1)
        // Leading empty section.
        #expect(mv(0, [0, 4], .up) == 0)
        #expect(mv(3, [0, 4], .down) == 3)
    }
}
