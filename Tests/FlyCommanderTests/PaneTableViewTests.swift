import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// 远端 fake：isRemote=true，listDirectory 返回预置条目（右键菜单远端禁用测试用）。
private final class RemoteStubFileSource: FileSource {
    let items: [FileItem]
    init(items: [FileItem]) { self.items = items }
    var sourceID: String { "sftp://stub:22" }
    var isRemote: Bool { true }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { items }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { items.first { $0.id == path.pathString } }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

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
        // 名称序：a.txt b.dat z.txt
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "a.txt")
        paneView.sortByColumnIdentifier("size")
        // 大小升序：a(1) z(1) b(100)
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "a.txt")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "b.dat")
        paneView.sortByColumnIdentifier("size")
        // 大小降序：b z a
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "b.dat")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "a.txt")
    }

    /// 列头点击按**稳定 identifier** 选列（与显示语言解耦）：夹具 a.txt(1) z.txt(1)
    /// b.dat(100)，名称序 b.dat 居中、大小序 b.dat 居末——b.dat 落在哪一列即可区分
    /// "点了 size 却按 name 排"的排错列 bug。参数用 identifier "size"/"name"，
    /// 无论 L10n 当前是 en/zh 都成立。
    func testHeaderClickSelectsColumnByIdentifier() {
        // 点 size → 大小升序：a(1) z(1) b(100)，b.dat 居末（若误按名称排则 b.dat 居中）
        paneView.sortByColumnIdentifier("size")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "b.dat",
                       "点 size 列须按大小排（b.dat=100 最大，升序落末行）")
        // 回到名称列：点 name 复位为名称升序（size 键切换后 sortKey=.size，点 name 换键）
        paneView.sortByColumnIdentifier("name")
        // 点 name → 名称升序：a.txt b.dat z.txt，b.dat 居中（若误按大小排则 b.dat 居末）
        XCTAssertEqual(cell(atColumn: 0, row: 0)?.nameLabel.stringValue, "a.txt")
        XCTAssertEqual(cell(atColumn: 0, row: 1)?.nameLabel.stringValue, "b.dat",
                       "点 name 列须按名字排（b.dat 名称居中，非大小居末）")
        XCTAssertEqual(cell(atColumn: 0, row: 2)?.nameLabel.stringValue, "z.txt")
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
        paneView.sortByColumnIdentifier("size")
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
        paneView.sortByColumnIdentifier("size")
        // 焦点对齐到 display 首行 a.txt
        paneView.handleMouseClick(row: 0, event: mouseEvent([]), doubleClick: false)
        XCTAssertEqual(pane.focusedItem?.name, "a.txt")
        paneView.navigate(delta: 1, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "z.txt",
                       "乱序下 +1 应到显示下一行 z.txt，而非 selection 序的 b.dat")
    }

    /// home/end 在乱序下落到 display 首/末行。
    func testNavigateHomeEndInScrambledOrder() {
        paneView.sortByColumnIdentifier("size")
        // 大小升序 display：a.txt z.txt b.dat（首 a.txt 末 b.dat）
        paneView.navigate(toEdge: .end, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "b.dat", "End 应到显示末行 b.dat")
        paneView.navigate(toEdge: .home, mode: .sticky)
        XCTAssertEqual(pane.focusedItem?.name, "a.txt", "Home 应到显示首行 a.txt")
    }

    /// 右键菜单（本地文件）：条目齐全、全部可用；"打开方式"带子菜单。
    func testContextMenuLocalFileItems() {
        let item = pane.page!.items.first { $0.name == "a.txt" }!
        let menu = paneView.contextMenu(for: item)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        XCTAssertEqual(titles, [
            L10n.t(.menuOpen), L10n.t(.openWithMenu), L10n.t(.showInFinder),
            L10n.t(.preview), L10n.t(.editItem),
            L10n.t(.copyToOtherPane), L10n.t(.moveToOtherPane),
            L10n.t(.rename), L10n.t(.moveToTrash),
            L10n.t(.newDirectory), L10n.t(.share),
        ])
        XCTAssertTrue(menu.items.allSatisfy { $0.isEnabled || $0.isSeparatorItem },
                      "本地文件条目应全部可用")
        XCTAssertNotNil(menu.items.first { $0.title == L10n.t(.openWithMenu) }?.submenu,
                        "打开方式须挂子菜单")
    }

    /// 右键菜单（本地目录）：打开方式/预览/编辑/复制/移动禁用；重命名/删除/新建目录可用。
    func testContextMenuDirectoryDisablesFileOnlyItems() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        pane.load(); paneView.reload()
        let item = pane.page!.items.first { $0.name == "sub" }!
        let menu = paneView.contextMenu(for: item)
        func enabled(_ key: L10nKey) -> Bool {
            menu.items.first { $0.title == L10n.t(key) }?.isEnabled ?? false
        }
        XCTAssertFalse(enabled(.preview)); XCTAssertFalse(enabled(.editItem))
        XCTAssertFalse(enabled(.copyToOtherPane)); XCTAssertFalse(enabled(.moveToOtherPane))
        XCTAssertFalse(enabled(.openWithMenu))
        XCTAssertTrue(enabled(.rename)); XCTAssertTrue(enabled(.moveToTrash))
        XCTAssertTrue(enabled(.newDirectory)); XCTAssertTrue(enabled(.menuOpen))
    }

    /// 右键菜单（远端）：打开方式/显示在 Finder/共享禁用（无本地 url）；
    /// 打开/预览/编辑/复制/移动/重命名/删除照常（远端各有后台路径）。
    func testContextMenuRemoteDisablesLocalOnlyItems() {
        let src = RemoteStubFileSource(items: [
            FileItem(id: "/r/f.txt", path: TCPath("/r/f.txt"), name: "f.txt",
                     isDirectory: false, size: 1, modificationDate: .distantPast,
                     isHidden: false, isReadOnly: false, isExecutable: false),
        ])
        let rPane = FilePane(id: .left, source: src, startPath: TCPath("/r"))
        rPane.load()
        let rv = PaneTableView(pane: rPane, workspace: workspace, router: router, id: .left)
        rv.reload()
        let menu = rv.contextMenu(for: rPane.page!.items[0])
        func enabled(_ key: L10nKey) -> Bool {
            menu.items.first { $0.title == L10n.t(key) }?.isEnabled ?? false
        }
        XCTAssertFalse(enabled(.openWithMenu))
        XCTAssertFalse(enabled(.showInFinder))
        XCTAssertFalse(enabled(.share))
        XCTAssertTrue(enabled(.menuOpen))
        XCTAssertTrue(enabled(.rename))
        XCTAssertTrue(enabled(.moveToTrash))
    }

    /// 选择语义①：右键落在**未选**行 → 只选该行（清其余标记，焦点移过去）。
    func testContextMenuSelectsUnselectedRowOnly() {
        pane.moveFocus(to: 1, mode: .simple)                       // 焦点 b.dat
        pane.toggleMark(at: 0)                                     // 再标 a.txt
        let zID = pane.selection.items.first { $0.hasSuffix("z.txt") }!
        let zItem = pane.itemByID[zID]!
        _ = paneView.contextMenu(for: zItem)
        paneView.applyContextMenuSelection(to: zItem)
        XCTAssertEqual(pane.selection.focusID, zID, "右键未选行 → 焦点移过去")
        XCTAssertEqual(pane.selection.markedIDs, [], "清其余标记")
    }

    /// 选择语义②：右键落在**已标记**行 → 保持整组多选原样（标记与焦点都不动；
    /// 单项操作经 representedObject 携带右键项，不依赖焦点）。
    func testContextMenuKeepsMultiSelectionOnMarkedRow() {
        pane.moveFocus(to: 1, mode: .simple)    // b.dat
        pane.toggleMark()                        // mark b.dat
        pane.moveFocus(to: 2, mode: .sticky)     // z.txt（焦点走，b 标记留）
        pane.toggleMark()                        // mark z.txt
        let focusBefore = pane.selection.focusID
        let bItem = pane.itemByID[pane.selection.items[1]]!
        paneView.applyContextMenuSelection(to: bItem)
        XCTAssertEqual(pane.selection.markedIDs.count, 2, "已标记行右键不清多选")
        XCTAssertEqual(pane.selection.focusID, focusBefore, "选择集原样不动")
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

    // MARK: - 右键坐标回归（真窗）

    /// 真窗 + 真右键事件：右键落在**非首行**的显示行 → 菜单非 nil，且焦点（= 菜单目标项）
    /// 落在**被右键的那一行**，不是别的行。
    ///
    /// 根因：`menu(for:)` 须用 `tableView.convert`（tableView 是 flipped + 有滚动偏移，
    /// 坐标系 ≠ 外层 PaneTableView）。旧代码用 `self.convert`（= PaneTableView 坐标系）
    /// 把 window 点解析成**错误的显示行**。
    ///
    /// **参数是探针实证的「黄金分歧配置」**（40 行 / 400 高窗 / targetRow=5）：实测
    /// `tableView.convert` 解析到第 5 行、`self.convert` 解析到第 12 行。参数退化到分歧较小时
    /// 两坐标系会算出同一行、测试失去捕获力——故下方加「前提自检」显式断言二者分歧。
    ///
    /// 变异：把 `tableView.convert(...)` 改回 `convert(...)`（self）→ 焦点断言红（焦点跑到
    /// 别的行）；小目录里还会因解析越界触发 guard 返回 nil（即用户报的「PDF 目录右键不弹」）。
    func testContextMenuTargetsRightClickedRowNotAnother() throws {
        // 造 40 行撑出滚动，对齐探针的黄金配置。
        for i in 0..<40 {
            let nm = String(format: "item%02d.txt", i)
            try "x".write(to: dir.appendingPathComponent(nm), atomically: true, encoding: .utf8)
        }
        pane.load(); paneView.reload()

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        win.contentView = host
        host.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: host.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        win.makeKeyAndOrderFront(nil)
        win.layoutIfNeeded()
        defer { win.orderOut(nil) }

        let tv = paneView.tableView!
        // 焦点先钉在第 0 行，好让「右键第 5 行后焦点移到第 5 行」与 bug 版的「焦点乱跑」区分开。
        pane.setFocus(to: 0)

        let targetRow = 5
        guard let targetName = cell(atColumn: 0, row: targetRow)?.nameLabel.stringValue,
              !targetName.isEmpty else {
            return XCTFail("第 \(targetRow) 显示行未渲染出 cell——布局未就绪")
        }
        // 目标行中心的 window 坐标（与真实右键同一坐标）。
        let rr = tv.rect(ofRow: targetRow)
        let centerInTV = NSPoint(x: rr.midX, y: rr.midY)
        let centerInWindow = tv.convert(centerInTV, to: nil)

        // 前提自检:两坐标系对同一点必须算出**不同**行——否则本配置退化、回归失去捕获力
        // （变异「self.convert」将假绿）。这正是 bug 的全部机理。
        let rowViaCorrect = tv.row(at: tv.convert(centerInWindow, from: nil))
        let rowViaBug = tv.row(at: paneView.convert(centerInWindow, from: nil))
        XCTAssertEqual(rowViaCorrect, targetRow, "正确坐标路须解析到目标行")
        XCTAssertNotEqual(rowViaBug, targetRow,
                          "前提自检:self.convert 必须解析到别的行(否则参数退化,测试假绿)")

        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: centerInWindow,
                                       modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!

        let menu = paneView.menu(for: event)
        XCTAssertNotNil(menu, "右键有效行须弹出菜单（bug 版坐标越界会返回 nil）")
        XCTAssertEqual(pane.focusedItem?.name, targetName,
                       "菜单目标须是被右键的那一行（bug 版 self.convert 会算错行、把焦点带给别的行）")
    }

    /// 真窗 + 真右键：在**小目录**（setUp 的 3 行）右键最后一个可见行 → 菜单须非 nil。
    ///
    /// 对应用户报的第二症状「在 pdf 文件右键不出现」：`self.convert`（非 flipped 的
    /// PaneTableView 坐标系）会把靠下的行解析成**越界行号**，触发 `menu(for:)` 里的
    /// `guard row < displayIDs.count` 直接返回 nil → 菜单不弹。
    ///
    /// 这里的分歧由**翻转方向本身**驱动（tableView flipped、PaneTableView 非 flipped），
    /// 无需滚动偏移即成立：小目录里行数少、可显示区高，`self.convert` 把 y 从底部起算，
    /// 解析到的行号落到首行之上（-1）→ 越界。下方「前提自检」显式断言这一越界，防止参数退化假绿。
    ///
    /// 变异：`menu(for:)` 的 `tableView.convert` 改回 `self.convert` → `XCTAssertNotNil(menu)` 红
    /// （越界 → guard 返回 nil）。
    func testContextMenuAppearsOnLastRowOfSmallDir() throws {
        // setUp 已 load 3 个文件（a.txt / b.dat / z.txt）；直接用这个小目录。
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        win.contentView = host
        host.addSubview(paneView)
        NSLayoutConstraint.activate([
            paneView.topAnchor.constraint(equalTo: host.topAnchor),
            paneView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            paneView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        win.makeKeyAndOrderFront(nil)
        win.layoutIfNeeded()
        defer { win.orderOut(nil) }

        let tv = paneView.tableView!
        let targetRow = 2  // 最后一行（z.txt）；小目录里靠下，self.convert 最易解析越界
        guard let targetName = cell(atColumn: 0, row: targetRow)?.nameLabel.stringValue,
              !targetName.isEmpty else {
            return XCTFail("第 \(targetRow) 显示行未渲染出 cell——布局未就绪")
        }
        let rr = tv.rect(ofRow: targetRow)
        let centerInWindow = tv.convert(NSPoint(x: rr.midX, y: rr.midY), to: nil)

        // 前提自检:bug 坐标系(self.convert)须解析到**越界**行(不在 0..<rowCount 内)——
        // 否则本配置退化、「不弹菜单」这一症状无从复现,回归失去捕获力。
        // 小目录无滚动时实测解析为 -1（y 从底部起算→ 落到首行之上），触发 `guard row >= 0`。
        let rowCount = tv.numberOfRows
        let rowViaCorrect = tv.row(at: tv.convert(centerInWindow, from: nil))
        let rowViaBug = tv.row(at: paneView.convert(centerInWindow, from: nil))
        XCTAssertEqual(rowViaCorrect, targetRow, "正确坐标路须解析到目标行")
        XCTAssertFalse((0..<rowCount).contains(rowViaBug),
                       "前提自检:self.convert 须解析到越界行(否则参数退化,测试假绿)")

        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: centerInWindow,
                                       modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0)!
        let menu = paneView.menu(for: event)
        XCTAssertNotNil(menu, "小目录最后一行右键须弹出菜单（bug 版越界 → guard 返回 nil）")
        XCTAssertEqual(pane.focusedItem?.name, targetName, "菜单目标须是被右键的最后一行")
    }
}
