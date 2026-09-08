import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// Task 3：筛选行 UI 与入口接线——标签条常驻筛选按钮、展开的 28pt 筛选行
/// （输入框/清空/计数）、Esc/回车/清空行为、语言切换重刷、状态栏计数可见感知。
/// headless 范式与 `PaneTableViewTests`/`ResidentWindowRepaintTests` 一致（离屏视图 + 视图树遍历）。
final class FilterBarWiringTests: XCTestCase {
    private var dir: URL!
    private var pane: FilePane!
    private var workspace: Workspace!
    private var router: CommandRouter!
    private var paneView: PaneTableView!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.current = .en
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("filterbar_\(UUID().uuidString)")
        dir = base.appendingPathComponent("L")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("a.txt")
        try write("b.dat")
        try write("z.txt")

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
        L10n.current = .en
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func write(_ name: String) throws {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - 视图树助手

    /// 按 AX 标识在子树内找控件（不依赖属性访问级别）。
    private func findByAX(_ root: NSView, _ id: String) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for s in root.subviews {
            if let hit = findByAX(s, id) { return hit }
        }
        return nil
    }

    private func filterRow() -> NSView? { findByAX(paneView, "paneFilterRow") }
    private var filterInput: NSTextField! { findByAX(paneView, "paneFilterInput") as? NSTextField }
    private var filterClear: NSButton! { findByAX(paneView, "paneFilterClear") as? NSButton }
    private var filterCount: NSTextField! { findByAX(paneView, "paneFilterCount") as? NSTextField }

    /// 筛选行高度约束（行内唯一的高度约束，由 PaneTableView 建在行自身）。
    private func filterRowHeightConstant() -> CGFloat? {
        filterRow()?.constraints.first { $0.firstAttribute == .height && $0.secondItem == nil }?.constant
    }

    private func rowCount() -> Int { paneView.numberOfRows(in: paneView.tableView!) }

    /// 断言「我们自己约束布局」的整棵子树都关掉了 autoresizing 转约束。
    /// NSScrollView 内部（clip/scroller）由 AppKit 以 autoresizing 管理，本就为 true，不下降；
    /// 但文档视图若是自建视图（TabBarView 的 stack）仍须走约束——NSTableView 文档视图除外
    /// （同样由 AppKit 管理）。
    private func assertProgrammaticSubviewsUseConstraints(_ root: NSView,
                                                          file: StaticString = #filePath,
                                                          line: UInt = #line) {
        func walk(_ v: NSView) {
            XCTAssertFalse(v.translatesAutoresizingMaskIntoConstraints,
                           "\(type(of: v)) 漏设 translatesAutoresizingMaskIntoConstraints = false",
                           file: file, line: line)
            for s in v.subviews {
                if let sv = s as? NSScrollView {
                    XCTAssertFalse(sv.translatesAutoresizingMaskIntoConstraints,
                                   "NSScrollView 漏设 translates = false", file: file, line: line)
                    if let doc = sv.documentView, !(doc is NSTableView) { walk(doc) }
                } else {
                    walk(s)
                }
            }
        }
        walk(root)
    }

    // MARK: - 1. 默认收起

    /// 变异：构造时把 `filterRowHeight` 初值改成 28（或漏设 `frow.isHidden = true`）→ 本用例红。
    func testFilterRowStartsCollapsed() {
        XCTAssertFalse(paneView.isFilterRowVisible)
        XCTAssertEqual(filterRowHeightConstant(), 0, "默认应收起（高度 0）")
        XCTAssertEqual(filterRow()?.isHidden, true, "默认应隐藏")
    }

    // MARK: - 2. 展开/收起

    /// 变异：`setFilterRowVisible` 不写 `filterRowHeight.constant`（或写反）→ 本用例红。
    func testToggleFilterRowExpandsAndCollapses() {
        paneView.toggleFilterRow()
        XCTAssertTrue(paneView.isFilterRowVisible)
        XCTAssertEqual(filterRowHeightConstant(), 28, "展开应 28pt")
        XCTAssertEqual(filterRow()?.isHidden, false)

        paneView.toggleFilterRow()
        XCTAssertFalse(paneView.isFilterRowVisible)
        XCTAssertEqual(filterRowHeightConstant(), 0, "再 toggle 应收回 0")
        XCTAssertEqual(filterRow()?.isHidden, true)
    }

    // MARK: - 3. 约束卫生

    /// 变异：去掉 `filterRow`/`filterInput`/`filterClearButton`/`filterCountLabel`/`filterButton`
    /// 任一处 `translatesAutoresizingMaskIntoConstraints = false` → 本用例红。
    func testAllProgrammaticSubviewsDisableAutoresizingTranslation() {
        assertProgrammaticSubviewsUseConstraints(paneView)
        let bar = TabBarView()
        bar.rebuild(titles: ["a", "b"], activeIndex: 0, isActiveSide: true)
        assertProgrammaticSubviewsUseConstraints(bar)
    }

    // MARK: - 4. 展开行 + 输入过滤

    /// 变异：`controlTextDidChange` 不调 `pane.setFilter` → 行数仍 3；不调 `refreshFilterCount`
    /// （或计数参数顺序写成 总数/可见数）→ 计数断言红。
    func testTypingFiltersAndShowsCount() {
        paneView.setFilterRowVisible(true)
        filterInput.stringValue = "txt"
        paneView.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                   object: filterInput))
        XCTAssertEqual(rowCount(), 2, "txt 命中 a.txt/z.txt")
        XCTAssertEqual(filterCount.stringValue, "2/3", "计数为 可见数/总数")
    }

    // MARK: - 5. 语言切换重刷

    /// 变异：`retitleColumns()` 末尾不重刷 placeholder/清空按钮标题 → 切 zh 后仍英文 → 本用例红。
    func testRetitleColumnsRefreshesFilterTexts() {
        let enPlaceholder = filterInput.placeholderString
        let enClear = filterClear.title
        XCTAssertEqual(enPlaceholder, L10n.t(.filterPlaceholder))
        XCTAssertEqual(enClear, L10n.t(.filterClearTip))

        L10n.current = .zh
        paneView.retitleColumns()
        XCTAssertEqual(filterInput.placeholderString, L10n.t(.filterPlaceholder), "输入框占位应随语言")
        XCTAssertNotEqual(filterInput.placeholderString, enPlaceholder, "zh 文案须与 en 不同（否则断言无意义）")
        XCTAssertEqual(filterClear.title, L10n.t(.filterClearTip), "清空按钮标题应随语言")
        XCTAssertEqual(filterClear.toolTip, L10n.t(.filterClearTip), "清空按钮 tooltip 应随语言")

        L10n.current = .en
        paneView.retitleColumns()
        XCTAssertEqual(filterInput.placeholderString, enPlaceholder, "切回 en 应复原")
        XCTAssertEqual(filterClear.title, enClear)
    }

    // MARK: - 6. TabBarView 常驻按钮

    /// 变异：把 `filterButton` 改成 `stack.addArrangedSubview` → rebuild 清空 stack 后按钮消失
    /// （`findByAX` 为 nil / superview 不再是 bar）→ 本用例红。
    func testFilterButtonSurvivesRebuildAndFiresCallback() {
        let bar = TabBarView()
        bar.rebuild(titles: ["a", "b"], activeIndex: 0, isActiveSide: true)
        guard let button = findByAX(bar, "paneFilterButton") as? NSButton else {
            return XCTFail("标签条缺少常驻筛选按钮")
        }
        XCTAssertTrue(button.superview === bar, "筛选按钮应是 scroll 的兄弟视图，不在 stack 里")

        // 再次 rebuild（导航会频繁触发）后仍在。
        bar.rebuild(titles: ["c"], activeIndex: 0, isActiveSide: false)
        guard let again = findByAX(bar, "paneFilterButton") as? NSButton else {
            return XCTFail("rebuild 后筛选按钮被销毁")
        }
        XCTAssertTrue(again.superview === bar)

        var fired = 0
        bar.onToggleFilter = { fired += 1 }
        again.performClick(nil)
        XCTAssertEqual(fired, 1, "点击应触发 onToggleFilter")

        // 开关态同步（SidePaneContainer 用它反映活动窗格的筛选行可见性）。
        bar.isFilterActive = true
        XCTAssertEqual(again.state, .on)
        bar.isFilterActive = false
        XCTAssertEqual(again.state, .off)
    }

    // MARK: - 7. updateBars 用 operationTargets（carry-forward）

    /// 变异：把 `updateBars()` 的 `a.operationTargets.count` 改回 `a.selection.operationIDs.count`
    /// → 空可见集时 operationIDs 回退成 [focusID] → 状态栏显示「1 selected」→ 本用例红。
    func testUpdateBarsIgnoresHiddenFocusWhenFilterHasNoMatch() throws {
        let suiteName = "fly.test.filterbar.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dir.path,
                                            rightPath: dir.path, active: "left"))

        let vc = MainViewController(sessionStore: store)
        _ = vc.view   // 强制 loadView（按快照恢复到夹具目录）
        XCTAssertEqual(vc.workspace.active, .left)
        let active = vc.workspace.activePane
        XCTAssertNotNil(active.selection.focusID, "前置：目录非空 → 焦点落在首项")
        XCTAssertEqual(active.itemCount, 3)

        active.setFilter("no-such-name-xyz")   // 零命中：可见集空
        XCTAssertEqual(active.operationTargets.count, 0, "前置：无命中 → 操作目标为空")
        XCTAssertEqual(active.selection.operationIDs.count, 1,
                       "前置：selection 回退成 [focusID]，旧写法正是被它骗到")

        let label = NSTextField(labelWithString: "")
        vc.attachStatusLabel(label)   // 内部调 updateBars()
        XCTAssertTrue(label.stringValue.isEmpty,
                      "筛选无命中时状态栏不得显示已选计数，实际：\(label.stringValue)")
    }

    // MARK: - 8. 标签条按钮 → 活动窗格筛选行的接线

    /// 变异：`SidePaneContainer.init` 里去掉 `tabBar.onToggleFilter = …` → 点击后
    /// `pv.isFilterRowVisible` 仍 false → 本用例红。
    func testTabBarButtonTogglesActivePaneFilterRow() {
        let container = SidePaneContainer(side: .left)
        let pv = container.addTab(pane: pane, workspace: workspace, router: router)
        container.show(tabGroup: workspace.leftTabs, isActiveSide: true)
        XCTAssertFalse(pv.isFilterRowVisible)
        XCTAssertFalse(container.tabBar.isFilterActive, "初始应与窗格实际状态一致")

        container.tabBar.onToggleFilter?()
        XCTAssertTrue(pv.isFilterRowVisible, "点击应展开活动窗格的筛选行")
        XCTAssertTrue(container.tabBar.isFilterActive, "按钮开关态须同步为展开")

        container.tabBar.onToggleFilter?()
        XCTAssertFalse(pv.isFilterRowVisible)
        XCTAssertFalse(container.tabBar.isFilterActive)
    }

    // MARK: - 9. ⌘⇧F 菜单项

    /// 变异：删掉 `MainMenu` 的筛选项（或改错 selector/键）→ 本用例红。
    func testViewMenuHasFilterItemBoundToCommandShiftF() {
        let menu = MainMenu.build(target: NSObject())
        let view = menu.items.first { $0.submenu?.title == L10n.t(.menuView) }?.submenu
        guard let item = view?.items.first(where: { $0.title == L10n.t(.filterButtonTip) }) else {
            return XCTFail("查看菜单缺少筛选项")
        }
        XCTAssertEqual(item.keyEquivalent, "f")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item.action, #selector(MainViewController.menuFilter(_:)))
    }
}
