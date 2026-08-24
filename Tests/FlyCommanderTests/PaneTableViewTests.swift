import XCTest
import AppKit
import TCCore
@testable import FlyCommander

final class PaneTableViewTests: XCTestCase {
    private var dir: URL!
    private var pane: FilePane!
    private var workspace: Workspace!
    private var router: CommandRouter!
    private var paneView: PaneTableView!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ptv_\(UUID().uuidString)")
        dir = base.appendingPathComponent("L")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "x", count: 100).write(to: dir.appendingPathComponent("b.dat"),
                                                     atomically: true, encoding: .utf8)
        try "z".write(to: dir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)

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

    private func cell(atColumn col: Int, row: Int) -> FileCellView? {
        paneView.tableView!.view(atColumn: col, row: row, makeIfNecessary: true) as? FileCellView
    }

    private func mouseEvent(_ flags: NSEvent.ModifierFlags, clickCount: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: flags,
                           timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: clickCount, pressure: 1) ?? NSEvent()
    }

    /// 离屏 spike：无窗口、无激活，makeIfNecessary 必须真实执行
    /// data source/viewFor 委托并生成 cell（今天"空行" bug 的回归测试）。
    func testOffscreenCellMaterializes() {
        let tv = paneView.tableView!
        XCTAssertEqual(paneView.numberOfRows(in: tv), 3)
        let cell = cell(atColumn: 0, row: 0)
        XCTAssertNotNil(cell, "makeIfNecessary 离屏未生成 cell")
        XCTAssertEqual(cell?.nameLabel.stringValue, "a.txt")
    }

    /// 图标/内容只在名称列；大小/日期列各自只带本列文案、无图标（回归"每列都显示图标"）。
    func testRowContentSizeAndIcon() {
        let name = cell(atColumn: 0, row: 0)!
        XCTAssertEqual(name.nameLabel.stringValue, "a.txt")
        XCTAssertNotNil(name.iconView.image, "名称列应有图标")
        XCTAssertTrue(name.sizeLabel.stringValue.isEmpty)
        XCTAssertTrue(name.dateLabel.stringValue.isEmpty)

        let size = cell(atColumn: 1, row: 0)!
        XCTAssertEqual(size.sizeLabel.stringValue, ByteCountFormatter().string(fromByteCount: 1))
        XCTAssertNil(size.iconView.image, "大小列不应有图标")
        XCTAssertTrue(size.nameLabel.stringValue.isEmpty)
        XCTAssertTrue(size.dateLabel.stringValue.isEmpty)

        let date = cell(atColumn: 2, row: 0)!
        XCTAssertFalse(date.dateLabel.stringValue.isEmpty)
        XCTAssertNil(date.iconView.image, "日期列不应有图标")
        XCTAssertTrue(date.nameLabel.stringValue.isEmpty)
        XCTAssertTrue(date.sizeLabel.stringValue.isEmpty)
    }

    func testDirectoryRowHasEmptySize() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        pane.load()
        paneView.reload()
        for row in 0..<paneView.numberOfRows(in: paneView.tableView!) {
            if cell(atColumn: 0, row: row)?.nameLabel.stringValue == "sub" {
                XCTAssertEqual(cell(atColumn: 0, row: row)?.sizeLabel.stringValue, "")
                return
            }
        }
        XCTFail("目录行 sub 未出现")
    }

    func testFocusHighlightUsesSystemSelectionColor() {
        paneView.reload()
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.layer?.backgroundColor,
                       NSColor.selectedContentBackgroundColor.cgColor)
        XCTAssertNotEqual(cell(atColumn: 0, row: 1)?.layer?.backgroundColor,
                         NSColor.selectedContentBackgroundColor.cgColor)
    }

    func testMoveFocusMovesHighlight() {
        pane.moveFocusBy(delta: 2, mode: .sticky)   // 焦点到 z.txt（行 2）
        paneView.reload()
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.layer?.backgroundColor,
                       NSColor.selectedContentBackgroundColor.cgColor)
        XCTAssertNotEqual(cell(atColumn: 0, row: 0)?.layer?.backgroundColor,
                         NSColor.selectedContentBackgroundColor.cgColor)
    }

    func testMarkedRowUsesAccentColor() {
        ThemeStore.shared.update(Theme.default)   // 主题驱动：标记底色 = accent 25% 透明
        pane.toggleMark(at: 1)                       // 标记 b.dat（非焦点）
        paneView.reload()
        XCTAssertEqual(cell(atColumn: 0, row: 1)?.layer?.backgroundColor,
                       ThemeStore.shared.accentColor.withAlphaComponent(0.25).cgColor)
    }

    func testFocusWinsOverMark() {
        pane.toggleMark()                            // 标记焦点 a.txt
        paneView.reload()
        // 焦点行取焦点色而非标记色
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.layer?.backgroundColor,
                       NSColor.selectedContentBackgroundColor.cgColor)
    }

    func testSetFocusIsSticky() {
        pane.toggleMark(at: 1)
        pane.setFocus(to: 2)                         // 只移焦点，标记不动
        XCTAssertEqual(Set(pane.selection.markedIDs), [pane.selection.items[1]])
        XCTAssertEqual(pane.selection.focusIndex, 2)
    }

    func testHeaderClickSortsBySizeThenReverses() {
        let tv = paneView.tableView!
        // 名称序：a.txt b.dat z.txt
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "a.txt")
        paneView.tableView(tv, clickOnColumnName: "大小")
        // 大小升序：a(1) z(1) b(100)
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "a.txt")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "b.dat")
        paneView.tableView(tv, clickOnColumnName: "大小")
        // 大小降序：b z a
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "b.dat")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "a.txt")
    }

    func testPlainClickMovesFocus() {
        paneView.handleMouseClick(row: 2, event: mouseEvent([]), doubleClick: false)
        XCTAssertEqual(pane.selection.focusIndex, 2)
        XCTAssertTrue(pane.selection.marked.isEmpty)
    }

    func testOptionClickTogglesMarkWithoutMovingFocus() {
        paneView.handleMouseClick(row: 1, event: mouseEvent([.option]), doubleClick: false)
        XCTAssertEqual(pane.selection.focusIndex, 0)
        XCTAssertEqual(pane.selection.markedIDs, [pane.selection.items[1]])
        paneView.handleMouseClick(row: 1, event: mouseEvent([.option]), doubleClick: false)
        XCTAssertTrue(pane.selection.marked.isEmpty)
    }

    /// 排序后 display 行号 ≠ selection 索引：点击/加标记必须落在该显示行的文件上
    /// （回归 2026-08-22：旧实现把 row 当 selection 索引，排序后错位点错文件）。
    func testClickAfterSortingHitsDisplayedItem() {
        paneView.tableView(paneView.tableView!, clickOnColumnName: "大小")
        // 大小序显示：a.txt(1) z.txt(1) b.dat(100)
        paneView.handleMouseClick(row: 2, event: mouseEvent([]), doubleClick: false)
        XCTAssertEqual(pane.focusedItem?.name, "b.dat")
        // 加标记也落在显示行上（markedIDs 存 id，按名称断言）
        paneView.handleMouseClick(row: 0, event: mouseEvent([.option]), doubleClick: false)
        XCTAssertEqual(pane.operationTargets.map { $0.name }, ["a.txt"])
    }

    func testDoubleClickEntersViaRouter() {
        // 双击目录 → router.execute(.enter) → 进入子目录
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                 withIntermediateDirectories: true)
        pane.load()
        paneView.reload()
        guard let subRow = (0..<paneView.numberOfRows(in: paneView.tableView!)).first(where: {
            cell(atColumn: 0, row: $0)?.nameLabel.stringValue == "sub"
        }) else { return XCTFail("sub 未出现") }
        paneView.handleMouseClick(row: subRow, event: mouseEvent([], clickCount: 2), doubleClick: true)
        XCTAssertEqual(pane.path.url.lastPathComponent, "sub")
    }

    func testSetActiveBorder() {
        ThemeStore.shared.update(Theme.default)   // 主题驱动：活动边框 = accent
        paneView.setActive(true)
        XCTAssertEqual(paneView.layer?.borderColor, ThemeStore.shared.accentColor.cgColor)
        paneView.setActive(false)
        XCTAssertEqual(paneView.layer?.borderColor, NSColor.separatorColor.cgColor)
    }

    // MARK: - 键盘导航按显示顺序走（回归"光标跳来跳去"）

    /// 默认序（目录优先+名称，display==selection）：navigate(+1) 焦点落到显示相邻行。
    /// 含目录：sub 排第一（目录优先）。setUp 已加载 a/b/z 且焦点在 a.txt；
    /// 加 sub 后 load(preserveFocus:) 保留 a.txt 焦点（display[1]）。
    func testNavigateDefaultOrderAdjacent() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        pane.load()
        paneView.reload()
        // 显示序：sub(目录) a.txt b.dat z.txt；焦点保留在 a.txt（display[1]）
        XCTAssertEqual(pane.focusedItem?.name, "a.txt")
        paneView.navigate(delta: 1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "b.dat", "Down 应到显示下一行 b.dat")
        paneView.navigate(delta: 1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "z.txt")
        paneView.navigate(delta: 1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "z.txt", "末行 clamp 不动")
        paneView.navigate(delta: -1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "b.dat", "Up 回显示上一行")
        // 跳到目录：连续 Up 越过文件到 sub（目录优先首行）
        paneView.navigate(delta: -1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "a.txt")
        paneView.navigate(delta: -1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "sub", "Up 到目录优先首行 sub")
    }

    /// 乱序核心回归：按大小列头后 display ≠ selection 存储序（无目录，差异最清晰）。
    /// selection 序（名称）：a.txt, b.dat, z.txt
    /// 大小升序 display：a.txt(1) z.txt(1) b.dat(100) —— 名称 tie-break
    /// 焦点在 a.txt（display[0] = selection[0]），navigate(+1) 必须落到**显示下一行**
    /// z.txt，而非 selection 序的下一项 b.dat。修复前（走 selection±1）此断言必挂。
    func testNavigateInScrambledSizeOrderLandsOnDisplayedNext() {
        paneView.tableView(paneView.tableView!, clickOnColumnName: "大小")
        // 焦点对齐到 display 首行 a.txt
        paneView.handleMouseClick(row: 0, event: mouseEvent([]), doubleClick: false)
        XCTAssertEqual(pane.focusedItem?.name, "a.txt")
        paneView.navigate(delta: 1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "z.txt",
                       "乱序下 +1 应到显示下一行 z.txt，而非 selection 序的 b.dat")
    }

    /// home/end 在乱序下落到 display 首/末行。
    func testNavigateHomeEndInScrambledOrder() {
        paneView.tableView(paneView.tableView!, clickOnColumnName: "大小")
        // 大小升序 display：a.txt z.txt b.dat（首 a.txt 末 b.dat）
        paneView.navigate(toEdge: .end, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "b.dat", "End 应到显示末行 b.dat")
        paneView.navigate(toEdge: .home, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "a.txt", "Home 应到显示首行 a.txt")
    }

    /// 纯函数 targetSelectionIndex：乱序映射 + clamp 边界。
    func testTargetSelectionIndexPure() {
        // selection 存储序（名称）
        let items = ["a.txt", "b.dat", "z.txt"]
        // 大小升序 display：a.txt(1) z.txt(1) b.dat(100)
        let display = ["a.txt", "z.txt", "b.dat"]

        // 焦点 a.txt（display[0]）+1 → z.txt（display[1]）→ selection idx 2
        //   （旧的 selection±1 会从 a.txt 到 b.dat=idx1，故此处锁定新行为）
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display,
                                                          items: items, focusID: "a.txt", delta: 1), 2)
        // 焦点 z.txt（display[1]）+1 → b.dat（display[2]）→ selection idx 1
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display,
                                                          items: items, focusID: "z.txt", delta: 1), 1)
        // 焦点 b.dat（display[2]）+5 → clamp 末行 b.dat → selection idx 1
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display,
                                                          items: items, focusID: "b.dat", delta: 5), 1)
        // 焦点 b.dat -50 → clamp 首行 a.txt → selection idx 0
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display,
                                                          items: items, focusID: "b.dat", delta: -50), 0)
        // 焦点项不在 display（切换中）→ 从首行起算 +2 → display[2]=b.dat → idx 1
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display,
                                                          items: items, focusID: nil, delta: 2), 1)
        // home / end
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display, items: items, edge: .home), 0)
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: display, items: items, edge: .end), 1)
        // 空表
        XCTAssertEqual(PaneTableView.targetSelectionIndex(displayIDs: [], items: [], focusID: nil, delta: 1), 0)
    }
}
