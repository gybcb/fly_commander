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
        XCTAssertTrue(ws.activePane === ws.leftTabs.panes[0])
        XCTAssertTrue(ws.inactivePane === ws.rightTabs.panes[0])
        ws.switchActive()
        XCTAssertTrue(ws.activePane === ws.rightTabs.panes[0])
        XCTAssertTrue(ws.inactivePane === ws.leftTabs.panes[0])
    }

    private func tabGroup(_ side: PaneID, _ n: Int) -> TabGroup {
        let panes = (0..<n).map { _ in FilePane(id: side, source: LocalFileSource(), startPath: TCPath("~")) }
        return TabGroup(side: side, panes: panes)
    }

    func testActivePaneReflectsActiveTab() {
        let lt = tabGroup(.left, 3)
        let rt = tabGroup(.right, 1)
        let ws = Workspace(left: lt, right: rt, active: .left)
        XCTAssertTrue(ws.activePane === lt.panes[0])
        ws.nextTab()
        XCTAssertTrue(ws.activePane === lt.panes[1])
        ws.prevTab()   // 1 → 0
        XCTAssertTrue(ws.activePane === lt.panes[0])
    }

    func testNextTabFiresActiveChangeOncePerRealChange() {
        let lt = tabGroup(.left, 3)
        let ws = Workspace(left: lt, right: tabGroup(.right, 1), active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }
        ws.nextTab()   // 0→1
        XCTAssertEqual(fired, 1)
        ws.nextTab()   // 1→2
        XCTAssertEqual(fired, 2)
    }

    func testNextTabSingleSideNoFire() {
        let ws = Workspace(left: tabGroup(.left, 1), right: tabGroup(.right, 1), active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }
        ws.nextTab()   // 单标签 no-op
        XCTAssertEqual(fired, 0, "单标签 nextTab 不触发回调")
    }

    func testTabSwitchDoesNotChangeActiveSide() {
        let ws = Workspace(left: tabGroup(.left, 3), right: tabGroup(.right, 2), active: .left)
        ws.nextTab()
        XCTAssertEqual(ws.active, .left, "切标签只改标签，不改左右侧重")
    }
}
