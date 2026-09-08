import XCTest
import Carbon

/// Task 4：窗格内筛选的 Tier 2（真实窗口）回归。
///
/// 前三个任务的内核/视图投影/接线已由 SPM 层覆盖（PaneTableViewFilterTests /
/// FilterBarWiringTests 等）。本类只验证 **真实 AX 树** 下的可达性与端到端行为：
/// 标签条常驻 🔍 按钮展开 28pt 筛选行、键入收窄左表、计数标签、Esc/清空按钮/⌘⇧F
/// 菜单入口、通配符语义。SPM 测不到真实 AX 暴露，故这些事实都在此以真窗断言锁定。
///
/// 真实 AX 事实（本机 dump 实证，2026-09-09；沿用 FlyCommanderUITests 的既有结论）：
/// - 行名 = 行内 x 最小的 StaticText 的 **`value`**（每行 AX 暴露 3 个 Cell，每 Cell
///   都含整行 3 个 StaticText）。
/// - 左右表消歧 = 两个 table 中 `frame.minX` 最小者为左表。
/// - 左右窗格各有一份 AX 标识相同的筛选控件（每侧一个 TabBarView / PaneTableView）；
///   未展开侧 `filterRow.isHidden = true` → **不在 AX 树中**（实测收起时
///   `staticTexts["paneFilterCount"]` 计数为 0、`paneFilterInput` 不存在）→ 一律取左。
/// - 计数标签（`NSTextField(labelWithString:)`）的文案在 **`value`**（`label` 为空）。
/// - `paneFilterButton` 的开关态（`NSButton.state`）**AX 不可读**：`value` 恒为空串、
///   `isSelected` 恒 false（momentaryPushIn 按钮不暴露 AXValue）→ R7 的"按钮态同步"
///   在本层无法断言，由 Tier 1 `FilterBarWiringTests` 的 `tabBar.isFilterActive` /
///   `button.state == .on` 覆盖；本层改以"菜单展开后按钮仍作用于真实可见性"佐证。
///
/// 夹具：`alpha.txt` / `beta.dat` / `gamma.txt` + 目录 `subdir`（共 4 行，默认序
/// 目录优先 → subdir 在最前）。左右窗格同目录（FLY_START_DIR）。
final class PaneFilterUITests: XCTestCase {
    var app: XCUIApplication!
    var fixture: URL!

    // MARK: - 夹具 / 生命周期

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()   // 键入类断言须英文输入法（中文 IME 下 typeKey flaky）
        fixture = makeFixture()
        app = XCUIApplication()
        app.terminate()   // 清掉上一用例可能残留的进程
        // 与既有 UI 测试同款：强制英文（UI 定位符按英文标题匹配）+ 关会话恢复
        // （防将来新增用例漏设 FLY_START_DIR 时把夹具目录写进开发者真实 UserDefaults）。
        app.launchArguments = ["-appLanguage", "en", "-flyDisableSessionRestore", "YES"]
        app.launchEnvironment = ["FLY_START_DIR": fixture.path]
        app.launch()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 20), "主窗表格未出现")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    /// 把输入源切到英文 ABC（若可用）。中文输入法激活时 XCUITest 的 typeKey 字母会进
    /// IME 组合层、提交不出预期 ASCII（既有 UI 测试同因；XCUITest 类之间不共享 helper）。
    private func switchToEnglishInputSource() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        for s in cf {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id == "com.apple.keylayout.ABC" {
                TISSelectInputSource(s)
                return
            }
        }
    }

    /// 4 项夹具：3 个普通文件 + 1 个子目录（子目录用于验证通配符 `*.txt` 把目录也筛掉）。
    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_uitest_filter_\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        for name in ["alpha.txt", "beta.dat", "gamma.txt"] {
            try! "x".write(to: base.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try! fm.createDirectory(at: base.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        return base
    }

    // MARK: - 定位助手

    /// 左栏表格 = 两个 table 中 x 最小者（split 左侧）。
    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    /// 右栏表格 = 两个 table 中 x 最大者。
    private func rightTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }!
    }

    /// 左栏各行名称（按行序；行名 = 行内 x 最小的 StaticText 的 value）。
    private func leftRowNames() -> [String] {
        leftTable().tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    /// 按 AX 标识取元素；同标识多份（左右窗格各一）时取 x 最小者 = 左窗格。
    /// 无匹配时返回该查询的 firstMatch（`.exists == false`），**不** force-unwrap——
    /// 收起筛选行后输入框会离开 AX 树，断言"不存在"必须能安全求值。
    /// 断言只走 `setAccessibilityIdentifier`（`paneFilterButton`/`paneFilterInput`/
    /// `paneFilterClear`/`paneFilterCount`），绝不按标题或位置猜。
    private func leftElement(_ type: XCUIElement.ElementType, _ id: String) -> XCUIElement {
        let matches = app.descendants(matching: type).matching(identifier: id)
        return matches.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX } ?? matches.firstMatch
    }

    private var filterInput: XCUIElement { leftElement(.textField, "paneFilterInput") }
    private var filterButton: XCUIElement { leftElement(.button, "paneFilterButton") }
    private var filterClear: XCUIElement { leftElement(.button, "paneFilterClear") }
    private var filterCount: XCUIElement { leftElement(.staticText, "paneFilterCount") }

    /// 点 🔍 展开筛选行并等输入框出现（展开后输入框自动成为第一响应者）。
    private func openFilterRow() {
        filterButton.click()
        XCTAssertTrue(filterInput.waitForExistence(timeout: 5), "点 🔍 后筛选行未展开（paneFilterInput 不可见）")
    }

    /// 在筛选输入框键入。typeText 是**追加**输入；本类每个用例的输入框都从空开始。
    private func typeInFilter(_ text: String) {
        XCTAssertTrue(filterInput.waitForExistence(timeout: 5), "筛选输入框不可见，无法键入")
        filterInput.typeText(text)
    }

    /// 轮询等左表行数（AX 刷新有延迟；不用 Thread.sleep 定长赌）。
    @discardableResult
    private func waitForLeftRowCount(_ expected: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if leftRowNames().count == expected { return true }
            usleep(100_000)
        }
        return leftRowNames().count == expected
    }

    /// 轮询等元素离开 AX 树（收起筛选行后输入框不应再存在）。
    @discardableResult
    private func waitForGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(100_000)
        }
        return !element.exists
    }

    /// AX 可能把值桥成 String / NSNumber，统一成字符串比较。
    private func stringValue(_ element: XCUIElement) -> String {
        if let s = element.value as? String { return s }
        if let n = element.value as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: - 1. 点 🔍 展开筛选行

    /// 变异：`setFilterRowVisible` 不设 `filterRowHeight.constant = 28`（或漏
    /// `filterRow.isHidden = false`）→ 输入框不在 AX 树 / 不可 hittable → 本用例红。
    func testFilterButtonExpandsFilterRow() {
        XCTAssertFalse(filterInput.exists, "前置：启动时筛选行应收起（输入框不在 AX 树）")
        openFilterRow()
        XCTAssertTrue(filterInput.isHittable, "展开后输入框应可见可点")
    }

    // MARK: - 2. 键入子串收窄左表（右表不受影响）

    /// 变异：`PaneTableView.reload()` 的输入改回 `pane.selection.items`（而非
    /// `pane.visibleItemIDs`）→ 左表仍 4 行 → 本用例红；`controlTextDidChange` 不调
    /// `pane.setFilter` → 同样红。
    func testTypingSubstringNarrowsLeftTableOnly() {
        XCTAssertEqual(leftRowNames().count, 4, "前置：夹具 4 项")
        openFilterRow()
        typeInFilter("txt")
        XCTAssertTrue(waitForLeftRowCount(2), "键入 txt 后左表应收窄到 2 行，实际：\(leftRowNames())")
        let names = leftRowNames()
        XCTAssertTrue(names.allSatisfy { $0.contains("txt") },
                      "子串筛选：可见行名都应含 txt，实际：\(names)")
        XCTAssertEqual(rightTable().tableRows.count, 4, "筛选只作用于左窗格，右表行数不应变")
    }

    // MARK: - 3. 计数标签 = 可见数/总数

    /// 变异：`refreshFilterCount` 的两个参数写反（总数/可见数）→ "4/2" → 红；
    /// 或 `reload()` 末尾不调 `refreshFilterCount()` → 标签为空 → 红。
    func testCountLabelShowsMatchOverTotal() {
        openFilterRow()
        typeInFilter("txt")
        XCTAssertTrue(waitForLeftRowCount(2), "前置：txt 命中 2 行")
        XCTAssertTrue(filterCount.waitForExistence(timeout: 5), "计数标签未出现")
        XCTAssertEqual(stringValue(filterCount), "2/4", "计数应为 可见数/总数（AX value）")
    }

    // MARK: - 4. Esc 复原：收起行 + 列表回全量

    /// 变异：`cancelFilterEditing` 不调 `setFilterRowVisible(false)` → 行不收起、输入框仍在
    /// AX 树 → 红；`setFilterRowVisible` 收起分支不 `pane.setFilter("")` → 行数不回 4 → 红。
    func testEscapeCollapsesRowAndRestoresFullList() {
        openFilterRow()
        typeInFilter("txt")
        XCTAssertTrue(waitForLeftRowCount(2), "前置：txt 命中 2 行")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(waitForGone(filterInput), "Esc 后筛选行应收起（输入框应离开 AX 树）")
        XCTAssertTrue(waitForLeftRowCount(4), "Esc 后左表应回全量 4 行，实际：\(leftRowNames())")
    }

    // MARK: - 5. ⌘⇧F 菜单入口（与 🔍 按钮同一入口）

    /// 变异：`MainMenu` 删掉筛选项 / 改错 selector → 行不展开 → 红；
    /// `SidePaneContainer` 去掉 `onFilterRowVisibilityChange` 回写 → 菜单展开后点 🔍
    /// 仍能收起（按钮作用于真实可见性）这条断言不受影响，但 R7 的按钮**态**同步在
    /// AX 层本就不可读（见类注释）——该收口由 Tier 1 `FilterBarWiringTests` 第 8/11 条覆盖。
    func testViewMenuFilterItemExpandsRowAndButtonStaysInSync() {
        app.menuBarItems.matching(NSPredicate(format: "title == 'View'")).firstMatch.click()
        app.menuBarItems.matching(NSPredicate(format: "title == 'View'")).firstMatch
            .menuItems.matching(NSPredicate(format: "title == 'Filter'")).firstMatch.click()
        XCTAssertTrue(filterInput.waitForExistence(timeout: 5), "⌘⇧F 菜单项应展开筛选行")
        // 菜单与按钮是同一入口：展开后再点 🔍 应收起——若按钮做乐观翻转/状态脱钩，
        // 这次点击就会把"已展开"再展开（行不收起）而露馅。
        filterButton.click()
        XCTAssertTrue(waitForGone(filterInput), "⌘⇧F 展开后点 🔍 应收起（按钮须作用于真实可见性）")
    }

    // MARK: - 6. 清空按钮：清筛选但行保持展开

    /// 变异：`filterClearClicked` 误调 `setFilterRowVisible(false)`（而非只清筛选）→
    /// 行收起、输入框离开 AX 树 → 本用例红。
    func testClearButtonEmptiesFilterAndKeepsRowOpen() {
        openFilterRow()
        typeInFilter("txt")
        XCTAssertTrue(waitForLeftRowCount(2), "前置：txt 命中 2 行")
        filterClear.click()
        XCTAssertTrue(waitForLeftRowCount(4), "清空后左表应回全量 4 行，实际：\(leftRowNames())")
        XCTAssertTrue(filterInput.exists, "清空按钮只清筛选，筛选行须保持展开")
    }

    // MARK: - 7. 通配符：`*.txt` 全串锚定（目录也被筛掉）

    /// 变异：`NameFilter` 把含 `*`/`?` 的输入仍按子串处理 → 目录 `subdir`（不含 `.txt`）
    /// 也会被留下 / 或 `*.txt` 不锚定全串 → 行集不等于两个 .txt 文件 → 本用例红。
    func testWildcardFiltersByAnchoredPattern() {
        openFilterRow()
        typeInFilter("*.txt")
        XCTAssertTrue(waitForLeftRowCount(2), "*.txt 应命中 2 行（alpha/gamma），实际：\(leftRowNames())")
        XCTAssertEqual(leftRowNames(), ["alpha.txt", "gamma.txt"],
                       "通配符 *.txt 全串锚定：只剩两个 .txt 文件（目录 subdir 被筛掉）")
    }
}
