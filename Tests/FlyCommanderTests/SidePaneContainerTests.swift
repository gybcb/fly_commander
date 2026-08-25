import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// SidePaneContainer/TabBarView 的可单测纯函数（视图行为由 UI 测试覆盖）。
final class SidePaneContainerTests: XCTestCase {
    func testTabTitleLocalDirName() {
        let p = TCPath(url: URL(fileURLWithPath: "/Users/x/Documents"))
        XCTAssertEqual(SidePaneContainer.tabTitle(p), "Documents")
    }
    func testTabTitleLocalRoot() {
        XCTAssertEqual(SidePaneContainer.tabTitle(TCPath(url: URL(fileURLWithPath: "/"))), "/")
    }
    func testTabTitleRemoteShowsHost() {
        let p = TCPath("sftp://myhost:2222/some/dir")
        XCTAssertEqual(SidePaneContainer.tabTitle(p), "myhost:2222/some/dir")
    }
    func testTabTitleRemoteRootShowsHost() {
        let p = TCPath("sftp://myhost:2222")   // 无路径
        XCTAssertEqual(SidePaneContainer.tabTitle(p), "myhost:2222")
    }
    func testTruncateShortUnchanged() {
        XCTAssertEqual(TabBarView.truncate("abc", max: 10), "abc")
    }
    func testTruncateLongAppendsEllipsis() {
        let out = TabBarView.truncate(String(repeating: "a", count: 20), max: 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertTrue(out.hasSuffix("…"), "got: \(out)")
    }
}
