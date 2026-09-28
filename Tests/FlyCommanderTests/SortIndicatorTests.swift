import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 视觉 polish 一期：列头排序指示器 + 列头点击接线。
/// 盘点实证：sortByColumnIdentifier 原本只有测试在调，无生产调用点
/// （ClickForwardingTableView 覆写 mouseDown 掐断了原生头点击路）——
/// 本文件把「点头列 → 排序 → 箭头可见」的合同一次锁死。
final class SortIndicatorTests: XCTestCase {
    private var dir: URL!
    private var paneView: PaneTableView!

    override func setUpWithError() throws {
        L10n.current = .en
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sortind_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["b.txt", "a.txt", "c.txt"] {
            try "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: dir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: dir))
        left.load()
        let ws = Workspace(left: left, right: right, active: .left)
        paneView = PaneTableView(pane: left, workspace: ws,
                                 router: CommandRouter(workspace: ws), id: .left)
    }

    override func tearDownWithError() throws {
        L10n.current = .en
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func ascending(of columnID: String) -> Bool? {
        let col = try! XCTUnwrap(paneView.tableView.tableColumns.first {
            $0.identifier.rawValue == columnID
        })
        return (col.headerCell as? SortableHeaderCell)?.sortAscending
    }

    /// 初始态：name 升序箭头，其余列无箭头。
    func testInitialIndicatorOnNameColumn() {
        XCTAssertEqual(ascending(of: "name"), true)
        XCTAssertNil(ascending(of: "size"))
        XCTAssertNil(ascending(of: "date"))
    }

    /// 点 size 列头（delegate 路）：size 升序箭头、name 清空；再点翻降序。
    func testHeaderClickMovesIndicatorAndToggles() {
        let col = try! XCTUnwrap(paneView.tableView.tableColumns.first {
            $0.identifier.rawValue == "size"
        })
        paneView.tableView(paneView.tableView, mouseDownInHeaderOf: col)
        XCTAssertEqual(ascending(of: "size"), true, "首点=升序")
        XCTAssertNil(ascending(of: "name"))
        paneView.tableView(paneView.tableView, mouseDownInHeaderOf: col)
        XCTAssertEqual(ascending(of: "size"), false, "再点=降序")
    }

    /// 指示器跟 sortByColumnIdentifier 走（既有测试/命令栏路的兼容锁）。
    func testProgrammaticSortUpdatesIndicator() {
        paneView.sortByColumnIdentifier("date")
        paneView.sortByColumnIdentifier("date")
        XCTAssertEqual(ascending(of: "date"), false)
    }
}
