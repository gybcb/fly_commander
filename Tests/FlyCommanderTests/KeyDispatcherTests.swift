import XCTest
import AppKit
@testable import FlyCommander

final class KeyDispatcherTests: XCTestCase {
    func testUpSticky() {
        // TC 粘性标记：plain 方向键移焦点但标记集不变
        let r = KeyDispatcher.dispatch(KeyInput(keyCode: 126, modifiers: []))
        XCTAssertEqual(r?.command, .up)
        XCTAssertEqual(r?.moveMode, .sticky)
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
    func testCtrlTabNextTab() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 48, modifiers: [.control]))?.command, .nextTab)
    }
    func testCtrlShiftTabPrevTab() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 48, modifiers: [.control, .shift]))?.command, .prevTab)
    }
    func testCtrlRightSwitchesPane() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 124, modifiers: [.control]))?.command, .switchPane)
    }
    func testRightActivatesCommandLine() {
        // 无修饰右箭头 = 激活命令栏（TC 行为）；进入目录只剩 Return/双击
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 124, modifiers: []))?.command, .activateCommandLine)
    }
    func testLeftIsParent() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 123, modifiers: []))?.command, .parent)
    }
    func testF3View() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 99, modifiers: []))?.command, .viewFile)
    }
    func testF4Edit() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 118, modifiers: []))?.command, .editFile)
    }
    func testF5Copy() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 96, modifiers: []))?.command, .copy)
    }
    func testF6Move() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 97, modifiers: []))?.command, .move)
    }
    func testF7MakeDirectory() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 98, modifiers: []))?.command, .makeDirectory)
    }
    func testF8Delete() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 100, modifiers: []))?.command, .delete)
    }
    func testCmdFSearch() {
        // Cmd+F 由菜单 keyEquivalent 接管，不再经 dispatcher
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 3, modifiers: [.command])))
    }
    func testBareFIsUnbound() {
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 3, modifiers: [])))
    }
    func testCmdASelectAll() {
        // Cmd+A 由菜单 keyEquivalent 接管，不再经 dispatcher
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 0, modifiers: [.command])))
    }
    func testOptionQToggle() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 12, modifiers: [.option]))?.command, .toggleMark)
    }
    func testF2Favorite() {
        XCTAssertEqual(KeyDispatcher.dispatch(KeyInput(keyCode: 120, modifiers: []))?.command, .favoriteDirectory)
    }
    func testUnknownReturnsNil() {
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 50, modifiers: [])))
    }
}
