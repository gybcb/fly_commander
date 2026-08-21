import XCTest
import AppKit
@testable import FlyCommander

final class KeyDispatcherTests: XCTestCase {
    func testUpSimple() {
        let r = KeyDispatcher.dispatch(KeyInput(keyCode: 126, modifiers: []))
        XCTAssertEqual(r?.command, .up)
        XCTAssertEqual(r?.moveMode, .simple)
    }
    func testDownCtrlAdditive() {
        let r = KeyDispatcher.dispatch(KeyInput(keyCode: 125, modifiers: [.control]))
        XCTAssertEqual(r?.command, .down)
        XCTAssertEqual(r?.moveMode, .additive)
    }
    func testUpShiftRange() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 126, modifiers: [.shift]))?.moveMode, .range)
    }
    func testTabSwitchesPane() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 48, modifiers: []))?.command, .switchPane)
    }
    func testCtrlRightSwitchesPane() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 124, modifiers: [.control]))?.command, .switchPane)
    }
    func testLeftIsParent() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 123, modifiers: []))?.command, .parent)
    }
    func testF5Copy() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 96, modifiers: []))?.command, .copy)
    }
    func testF6Move() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 97, modifiers: []))?.command, .move)
    }
    func testF8Delete() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 99, modifiers: []))?.command, .delete)
    }
    func testCmdASelectAll() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 0, modifiers: [.command]))?.command, .selectAll)
    }
    func testOptionQToggle() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 12, modifiers: [.option]))?.command, .toggleMark)
    }
    func testUnknownReturnsNil() {
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 50, modifiers: [])))
    }
}
