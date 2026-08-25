import XCTest
import Foundation
@testable import TCCore

final class TabGroupTests: XCTestCase {
    private func pane(_ id: Int) -> FilePane {
        FilePane(id: .left, source: LocalFileSource(), startPath: TCPath("~"))
    }

    func testInitRequiresAtLeastOne() {
        let g = TabGroup(side: .left, panes: [pane(0)])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g.activeIndex, 0)
    }

    func testAddActivatesNewTab() {
        let g = TabGroup(side: .left, panes: [pane(0)])
        let added = g.add(pane(1))
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.activeIndex, 1)
        XCTAssertTrue(g.activePane === added)
    }

    func testCloseLastTabIsRefused() {
        let g = TabGroup(side: .left, panes: [pane(0)])
        XCTAssertNil(g.close(at: 0), "唯一标签不可关")
        XCTAssertEqual(g.count, 1)
    }

    func testCloseOutOfRangeRefused() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1)])
        XCTAssertNil(g.close(at: 5))
        XCTAssertEqual(g.count, 2)
    }

    func testCloseActiveActivatesRightNeighbor() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1), pane(2)])
        g.activate(index: 0)
        _ = g.close(at: 0)
        XCTAssertEqual(g.count, 2)
        XCTAssertEqual(g.activeIndex, 0, "关活动标签→激活右侧邻居（原 index 1）")
    }

    func testCloseLeftOfActiveDecrementIndex() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1), pane(2)])
        g.activate(index: 2)
        _ = g.close(at: 0)
        XCTAssertEqual(g.activeIndex, 1, "关活动标签左侧→activeIndex 减一")
    }

    func testCloseRightOfActiveKeepsIndex() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1), pane(2)])
        g.activate(index: 1)
        _ = g.close(at: 2)
        XCTAssertEqual(g.activeIndex, 1, "关活动标签右侧→activeIndex 不变")
    }

    func testStepNextWraps() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1), pane(2)])
        g.activate(index: 2)
        XCTAssertTrue(g.step(1))
        XCTAssertEqual(g.activeIndex, 0, "末尾 next 环绕回首")
    }

    func testStepPrevWraps() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1), pane(2)])
        g.activate(index: 0)
        XCTAssertTrue(g.step(-1))
        XCTAssertEqual(g.activeIndex, 2, "首部 prev 环绕至末")
    }

    func testStepSingleTabNoOp() {
        let g = TabGroup(side: .left, panes: [pane(0)])
        XCTAssertFalse(g.step(1), "单标签 step 不变")
        XCTAssertFalse(g.step(-1))
    }

    func testActivateClamps() {
        let g = TabGroup(side: .left, panes: [pane(0), pane(1)])
        g.activate(index: 99)
        XCTAssertEqual(g.activeIndex, 1)
        g.activate(index: -5)
        XCTAssertEqual(g.activeIndex, 0)
    }
}
