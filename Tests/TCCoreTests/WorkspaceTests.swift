import XCTest
import TCCore

/// Workspace 活动窗格切换：左右翻转、重复激活幂等、回调触发次数。
final class WorkspaceTests: XCTestCase {
    private func pane(_ id: PaneID) -> FilePane {
        FilePane(id: id, source: LocalFileSource(), startPath: TCPath("~"))
    }

    func testSwitchActiveToggles() {
        let ws = Workspace(left: pane(.left), right: pane(.right), active: .left)
        XCTAssertEqual(ws.active, .left)
        ws.switchActive()
        XCTAssertEqual(ws.active, .right)
        ws.switchActive()
        XCTAssertEqual(ws.active, .left)
    }

    func testActivateIsIdempotentAndCallbackFiresOncePerChange() {
        let ws = Workspace(left: pane(.left), right: pane(.right), active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }

        ws.activate(.left)   // 同侧重复激活
        XCTAssertEqual(fired, 0, "重复激活同侧不应触发回调")
        ws.switchActive()
        XCTAssertEqual(fired, 1, "切到右应触发一次")
        ws.activate(.right)  // 同侧重复激活
        XCTAssertEqual(fired, 1, "重复激活同侧不应再次触发")
        ws.switchActive()
        XCTAssertEqual(fired, 2, "切回左应再触发一次")
    }

    func testActiveAndInactivePaneTrackActive() {
        let ws = Workspace(left: pane(.left), right: pane(.right), active: .left)
        XCTAssertTrue(ws.activePane === ws.left)
        XCTAssertTrue(ws.inactivePane === ws.right)
        ws.switchActive()
        XCTAssertTrue(ws.activePane === ws.right)
        XCTAssertTrue(ws.inactivePane === ws.left)
    }
}
