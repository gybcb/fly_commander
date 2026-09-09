import XCTest
import Carbon

/// 右键上下文菜单的 Tier 2（真实窗口 + 真实右键事件）回归。
///
/// SPM 层 `PaneTableViewTests.testContextMenu*` 用**直接调用 `paneView.menu(for:)`**
/// 锁定坐标解析（症状①算错行、症状②越界返回 nil）——但那绕过了真实事件路由。本类
/// 补上路由这一环：`ClickForwardingTableView.rightMouseDown` → `onRightClick` →
/// `menu(for:)` → `NSMenu.popUpContextMenu` 全链在真 AX 树下是否真的弹出菜单、菜单
/// 是否作用在**被右键那一行**。
///
/// 对应用户所报「右键乱跳选中 / 在 pdf 文件右键不出现」——菜单不弹（本类断言）与选错
/// 行（SPM 层坐标断言 + 本类 Rename 目标断言）各有一证。
///
/// 真实 AX 事实（沿用 FlyCommanderUITests 既有实证 + 本机 SDK swiftinterface 核对）：
/// - 左右表消歧 = 两个 table 中 `frame.minX` 最小者为左表；行用 `.tableRows`（非 `.rows`）。
/// - 行名 = 行内 x 最小 StaticText 的 `value`。
/// - `XCUIElement.rightClick()` 存在（本机 XCUIElement.h 实证），发真实右键。
/// - 弹出的 NSMenu 经 `popUpContextMenu` → `app.menuItems`（title 匹配）。
/// - NSAlert(runModal) 的 AX 角色可能是 alert / sheet / dialog，依次查。
///
/// 夹具：`adir/`（目录优先排最前）+ aa..ee.txt 5 文件 → 共 6 行，右键 index 2 那行。
final class ContextMenuUITests: XCTestCase {
    var app: XCUIApplication!
    var fixture: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()
        fixture = makeFixture()
        app = XCUIApplication()
        app.terminate()   // 清残留进程（同 bundle id 抢占 → activate 超时假红）
        app.launchArguments = ["-appLanguage", "en", "-flyDisableSessionRestore", "YES"]
        app.launchEnvironment = ["FLY_START_DIR": fixture.path]
        app.launch()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 20), "主窗表格未出现")
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    private func switchToEnglishInputSource() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        for s in cf {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id == "com.apple.keylayout.ABC" { TISSelectInputSource(s); return }
        }
    }

    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_ctxmenu_uitest_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base.appendingPathComponent("adir"),
                                                 withIntermediateDirectories: true)
        for n in ["aa.txt", "bb.txt", "cc.txt", "dd.txt", "ee.txt"] {
            try! "x".write(to: base.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        return base
    }

    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    private func rowName(_ index: Int) -> String {
        let row = leftTable().tableRows.allElementsBoundByIndex[index]
        return row.staticTexts.allElementsBoundByIndex
            .min { $0.frame.minX < $1.frame.minX }?.value as? String ?? ""
    }

    /// NSAlert(runModal) 的 AX 角色可能是 alert / sheet / dialog：谁先存在谁赢。
    /// （`firstMatch` 返回的是惰性元素代理、恒非 nil，故必须用 waitForExistence 判定，
    /// 不能 `if kind.exists`——点完菜单项弹窗有延迟，直接查存在会假阴。）
    private func waitForPrompt(timeout: TimeInterval = 2) -> XCUIElement? {
        for kind in [app.alerts.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch] {
            if kind.waitForExistence(timeout: timeout) { return kind }
        }
        return nil
    }

    /// 右键可见行 → 上下文菜单经**真实事件路由**（rightMouseDown → onRightClick →
    /// `menu(for:)` → popUpContextMenu）真的弹出，且含标志项 "Rename"。
    ///
    /// 本条锁的是 SPM 层的空白：SPM 测直接调 `menu(for:)`，不经过事件路由。真窗实测
    /// （3 次变异跑校准）：本布局下 6 行夹具占不满窗高，bug 坐标系（非 flipped 镜像）
    /// 把各行解析成**别的界内行**（实测右键第 2 行 → 解析成第 0 行），越界分支在此打不出
    /// （「越界→不弹」由 SPM 的
    /// `testContextMenuAppearsOnLastRowOfSmallDir` 双向证伪锁定）。本条的捕获力在
    /// **路由链本身**：若 `rightMouseDown` 转发 / `popUpContextMenu` 挂掉，菜单永不出现
    /// → 本断言红；也直接回归用户「菜单不出现」的主观症状（菜单在任何行都必须弹）。
    func testRightClickPopsContextMenuOnTargetRow() throws {
        let rows = leftTable().tableRows.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(rows.count, 4, "夹具应至少 4 行")
        let targetIndex = 1
        XCTAssertTrue(rows[targetIndex].waitForExistence(timeout: 10))
        XCTAssertFalse(rowName(targetIndex).isEmpty, "目标行名须可读")

        rows[targetIndex].rightClick()

        let renameItem = app.menuItems.matching(NSPredicate(format: "title == 'Rename'")).firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5),
                      "右键有效行须弹出上下文菜单（含 Rename 项）；bug 版越界 → menu(for:) 返 nil → 不弹")
        app.typeKey(.escape, modifierFlags: [])   // 关菜单
    }

    /// 右键某行 → 菜单弹出 → 点 Rename → 重命名框回填的名字须 = **被右键那一行**的名字。
    ///
    /// 症状①（「选中乱跳」= 焦点跑到别的行）的端到端复现：`promptRename` 回填
    /// `focusedItem.name`，而 `applyContextMenuSelection` 把焦点设成被右键的行。bug 版
    /// 坐标算错行 → 焦点落在别的行 → 回填成别的名字 → 断言红。修复后回填目标行名 → 绿。
    ///
    /// 变异：`tableView.convert` 改回 `self.convert` → 回填名字 ≠ 目标行名（红）。
    func testRightClickThenRenameTargetsThatRow() throws {
        let rows = leftTable().tableRows.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        let targetIndex = 2   // 中间行：真窗实测 bug 坐标系在此解析成别的**有效**行（不越界），
                              // 正对「乱跳」症状；越界→不弹 的症状由上一条用例（末行）覆盖。
        XCTAssertTrue(rows[targetIndex].waitForExistence(timeout: 10))
        let targetName = rowName(targetIndex)
        XCTAssertFalse(targetName.isEmpty)

        rows[targetIndex].rightClick()
        let renameItem = app.menuItems.matching(NSPredicate(format: "title == 'Rename'")).firstMatch
        XCTAssertTrue(renameItem.waitForExistence(timeout: 5), "菜单须弹出")
        renameItem.click()

        // 重命名弹窗（NSAlert）——角色可能是 alert/sheet/dialog；其字段回填 = focusedItem.name。
        let alert = waitForPrompt()
        XCTAssertNotNil(alert, "点 Rename 须弹出重命名框")
        let field = alert?.textFields.firstMatch ?? app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 3), "重命名框须有输入字段")
        let v = (field.value as? String) ?? ""
        XCTAssertEqual(v, targetName,
                       "重命名框须回填被右键那一行的名字（回填成别的行 = 症状①焦点乱跳）")
        app.typeKey(.escape, modifierFlags: [])
    }
}
