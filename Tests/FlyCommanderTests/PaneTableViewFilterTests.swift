import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// Task 2：视图筛选管线——`PaneTableView` 的显示投影来自 `pane.visibleItemIDs`
/// （筛选态 = 命中项，无筛选 = 全量），排序照旧由视图层叠加。
/// 与 `PaneTableViewTests` 同范式：真实 tmp 目录 + `LocalFileSource` + 无窗口离屏表。
/// 本文件不涉及筛选行 UI（Task 3），只驱动 `pane.setFilter(_:)` + `paneView.reload()`。
final class PaneTableViewFilterTests: XCTestCase {
    private var dir: URL!
    private var pane: FilePane!
    private var workspace: Workspace!
    private var router: CommandRouter!
    private var paneView: PaneTableView!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ptvfilter_\(UUID().uuidString)")
        dir = base.appendingPathComponent("L")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("a.txt", bytes: 1)
        try write("b.dat", bytes: 100)
        try write("z.txt", bytes: 1)

        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: dir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: dir))
        pane = left
        workspace = Workspace(left: left, right: right, active: .left)
        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        paneView = PaneTableView(pane: left, workspace: workspace, router: router, id: .left)
        pane.load()
        paneView.reload()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func write(_ name: String, bytes: Int) throws {
        try String(repeating: "x", count: bytes).write(to: dir.appendingPathComponent(name),
                                                       atomically: true, encoding: .utf8)
    }

    private func rowCount() -> Int { paneView.numberOfRows(in: paneView.tableView!) }

    private func rowNames() -> [String] {
        (0..<rowCount()).compactMap {
            (paneView.tableView!.view(atColumn: 0, row: $0, makeIfNecessary: true) as? FileCellView)?
                .nameLabel.stringValue
        }
    }

    /// 1. 筛选收窄行数：`txt` 命中 a.txt/z.txt，b.dat 被投影掉。
    /// 变异：`reload()` 的输入改回 `pane.selection.items` → 行数 3、行名含 b.dat，本用例红。
    func testFilterNarrowsRows() {
        pane.setFilter("txt")
        paneView.reload()
        XCTAssertEqual(rowCount(), 2, "筛选后应只显示 2 行")
        XCTAssertEqual(Set(rowNames()), ["a.txt", "z.txt"], "只应显示命中项")
    }

    /// 2. 筛选与排序叠加：排序作用于**命中集**，行序仍是排序结果而非存储序。
    /// 夹具 a.txt(1) b.dat(50) z.txt(100)，存储序 a/b/z；筛选 txt → {a,z}。
    /// 按 size 降序 → z.txt(100) 在 a.txt(1) 之前，与存储序相反。
    /// 变异：`reload()` 忽略 `sortKey/sortDirection`（直接取 visibleItemIDs）→ 行序变 a,z，本用例红。
    func testFilterComposesWithSort() throws {
        try write("z.txt", bytes: 100)      // 覆盖：z.txt 比 a.txt 大
        try write("b.dat", bytes: 50)
        pane.load()
        paneView.reload()
        paneView.sortByColumnIdentifier("size")   // size 升序
        paneView.sortByColumnIdentifier("size")   // 再点 → size 降序
        pane.setFilter("txt")
        paneView.reload()
        XCTAssertEqual(rowCount(), 2)
        XCTAssertEqual(rowNames(), ["z.txt", "a.txt"],
                       "降序下大文件 z.txt 应在 a.txt 之前（存储序是 a,b,z）")
    }

    /// 3. 空命中：可见集为空 → 视图零行；`navigate(delta:)` 必须 no-op（不得把焦点
    /// 改到被筛掉的 items[0]）。焦点先置于 z.txt（存储索引 2），故"改到 0"可被断言捕获。
    /// 变异：删掉 `navigate` 首行 guard → `targetSelectionIndex` 空表返回 0，
    /// focusID 变成 a.txt 的 id，本用例红。
    func testEmptyVisibleSetNavigateDeltaIsNoOp() {
        pane.setFocus(to: 2)                 // 焦点 z.txt（会被 "nope" 筛掉）
        pane.setFilter("nope")
        paneView.reload()
        XCTAssertEqual(rowCount(), 0, "零命中应显示 0 行")
        XCTAssertTrue(pane.operationTargets.isEmpty, "可见集为空 → 无操作目标")
        XCTAssertNil(pane.focusedItem, "隐藏焦点项不得成为 focusedItem")

        let focusBefore = pane.selection.focusID
        XCTAssertNotNil(focusBefore, "前置条件：焦点仍在（隐藏项）")
        paneView.navigate(delta: 1, mode: .simple)
        XCTAssertEqual(pane.selection.focusID, focusBefore,
                       "空可见集下 navigate 不得改焦点（否则落到隐藏的 items[0]）")
        XCTAssertEqual(rowCount(), 0, "显示集不得被 navigate 改动")
    }

    /// 3b. 空命中 + `navigate(toEdge:)` 同样 no-op（同一坑的第二处守卫）。
    /// 变异：删掉 `navigate(toEdge:)` 首行 guard → focusID 变成 items[0]，本用例红。
    func testEmptyVisibleSetNavigateToEdgeIsNoOp() {
        pane.setFocus(to: 2)
        pane.setFilter("nope")
        paneView.reload()
        XCTAssertEqual(rowCount(), 0)
        let focusBefore = pane.selection.focusID
        XCTAssertNotNil(focusBefore)
        paneView.navigate(toEdge: .home, mode: .simple)
        XCTAssertEqual(pane.selection.focusID, focusBefore, "空可见集下 Home 不得改焦点")
        paneView.navigate(toEdge: .end, mode: .simple)
        XCTAssertEqual(pane.selection.focusID, focusBefore, "空可见集下 End 不得改焦点")
        XCTAssertEqual(rowCount(), 0)
    }

    /// 4. 清空筛选复原：`setFilter("")` 后可见集回到全量（3 行）。
    /// 变异：`clearFilter`/`recomputeVisibility` 清空文本时不清缓存 → 仍 2 行，本用例红。
    func testClearingFilterRestoresAllRows() {
        pane.setFilter("txt")
        paneView.reload()
        XCTAssertEqual(rowCount(), 2)
        pane.setFilter("")
        paneView.reload()
        XCTAssertEqual(rowCount(), 3, "清空筛选应恢复全量")
        XCTAssertEqual(Set(rowNames()), ["a.txt", "b.dat", "z.txt"])
    }

    /// 5. 无筛选回归：显示集与既有 `PaneTableViewTests` 一致（名称序 a/b/z，3 行）。
    /// 变异：`reload()` 输入换成 `[]`（或任何恒空集）→ 本用例红。
    func testNoFilterKeepsExistingRowsAndOrder() {
        XCTAssertEqual(rowCount(), 3, "无筛选应显示全量 3 行")
        XCTAssertEqual(rowNames(), ["a.txt", "b.dat", "z.txt"], "默认名称序与既有测试一致")
    }
}
