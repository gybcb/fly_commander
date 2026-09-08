import XCTest
import Foundation
@testable import TCCore

final class SelectionModelTests: XCTestCase {
    func testSimpleMoveClearsMarks() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d"])
        s.toggleMark()                       // marks "a"
        s.moveFocus(to: 2, mode: .simple)
        XCTAssertEqual(s.focusID, "c")
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testAdditiveMarksDestination() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d"])
        s.moveFocusBy(delta: 1, mode: .additive)   // focus b, mark b
        XCTAssertEqual(s.focusID, "b")
        XCTAssertEqual(s.markedIDs, ["b"])
        s.moveFocusBy(delta: 1, mode: .additive)   // focus c, mark c
        XCTAssertEqual(s.markedIDs, ["b", "c"])
    }

    func testRangeSelectsInclusive() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c", "d", "e"])
        s.moveFocus(to: 1, mode: .simple)          // focus b, anchor unset
        s.moveFocus(to: 3, mode: .range)           // anchor=b(1), mark b,c,d
        XCTAssertEqual(s.markedIDs, ["b", "c", "d"])
    }

    func testToggleAt() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.toggleMark(at: 1)
        XCTAssertEqual(s.markedIDs, ["b"])
        s.toggleMark(at: 1)
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testOperationIDsFallbackToFocus() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.moveFocus(to: 1, mode: .simple)
        XCTAssertEqual(s.operationIDs, ["b"])
        s.toggleMark()
        XCTAssertEqual(s.operationIDs, ["b"])
    }

    func testSelectAllAndClear() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.selectAll()
        XCTAssertEqual(s.markedIDs, ["a", "b", "c"])
        s.clearMarks()
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testReloadResets() {
        var s = SelectionModel()
        s.reload(with: ["a", "b"])
        s.moveFocus(to: 1, mode: .simple)
        s.reload(with: ["x"])
        XCTAssertEqual(s.focusIndex, 0)
        XCTAssertEqual(s.focusID, "x")
    }

    func testReloadKeepsFocusWhenPreviousFocusStillPresent() {
        var s = SelectionModel()
        s.reload(with: ["x", "a", "b"])
        s.moveFocus(to: 1, mode: .simple)           // focus a
        s.reload(with: ["x", "a", "b"], previousFocusID: "a")
        XCTAssertEqual(s.focusIndex, 1)
        XCTAssertEqual(s.focusID, "a")
    }

    func testReloadMovesFocusToNextWhenPreviousFocusRemoved() {
        var s = SelectionModel()
        s.reload(with: ["x", "a", "b"])
        s.moveFocus(to: 1, mode: .simple)           // focus a
        s.reload(with: ["x", "b"], previousFocusID: "a")
        XCTAssertEqual(s.focusIndex, 1)
        XCTAssertEqual(s.focusID, "b")
    }

    func testReloadMovesFocusToLastWhenLastRemoved() {
        var s = SelectionModel()
        s.reload(with: ["x", "a", "b"])
        s.moveFocus(to: 2, mode: .simple)           // focus b (last)
        s.reload(with: ["x", "a"], previousFocusID: "b")
        XCTAssertEqual(s.focusIndex, 1)
        XCTAssertEqual(s.focusID, "a")
    }

    func testReloadKeepsMarksForSurvivingIDs() {
        var s = SelectionModel()
        s.reload(with: ["x", "a", "b"])
        s.moveFocus(to: 1, mode: .simple)           // focus a
        s.toggleMark()                              // mark a
        s.moveFocusBy(delta: 1, mode: .additive)    // focus+mark b
        XCTAssertEqual(s.markedIDs, ["a", "b"])
        s.reload(with: ["x", "a"], previousFocusID: "a")
        XCTAssertEqual(s.focusID, "a")
        XCTAssertEqual(s.markedIDs, ["a"])
    }

    func testStickyMovesFocusWithoutTouchingMarks() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.moveFocus(to: 1, mode: .simple)           // focus b
        s.toggleMark()                              // mark b
        s.moveFocusBy(delta: 1, mode: .sticky)      // focus c, marks unchanged
        XCTAssertEqual(s.focusID, "c")
        XCTAssertEqual(s.markedIDs, ["b"])
    }

    /// restrictMarks：标记集收窄到给定 id 集（筛选剪枝），其余破坏性丢弃。
    /// items/focusIndex/anchor 一律不动（可见性概念留在 FilePane 侧）。
    /// 变异：把 `formIntersection` 改成 `formUnion` → 本用例红（越剪越多）。
    func testRestrictMarksIntersects() {
        var s = SelectionModel()
        s.reload(with: ["a", "b", "c"])
        s.selectAll()
        s.restrictMarks(to: ["a", "c"])
        XCTAssertEqual(s.markedIDs, ["a", "c"])
        s.restrictMarks(to: [])
        XCTAssertTrue(s.marked.isEmpty)
        XCTAssertEqual(s.items, ["a", "b", "c"], "不得动 items")
        XCTAssertEqual(s.focusID, "a", "不得动 focus")
    }
}
