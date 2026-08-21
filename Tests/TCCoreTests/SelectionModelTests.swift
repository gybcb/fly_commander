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
}
