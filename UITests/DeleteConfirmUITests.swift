import XCTest
import Carbon

/// 删除确认框的 Tier 2（真实窗口）回归——对应用户两症状：
/// ①「单文件删除不弹确认框」→ doTrashDelete 去掉了 `targets.count > 1` 包裹；
/// ②「默认焦点不在确定按钮」→ NSAlert.setDefaultConfirmCancel 给删除键挂 ⏎、取消键挂 Esc。
///
/// 可证伪性：
/// - 回退 count>1 条件 → testSingleFileDeleteShowsConfirm 红（弹窗永不出现，waitForExistence 超时）。
/// - 回退 keyEquivalent="\r" → testEnterConfirmsDelete 红（⏎ 无触发对象，文件不消失超时）。
/// - 回退取消键 "\u{1b}" → testEscapeCancelsDelete 红（Esc 被命令行/表格吞掉或无事发生，
///   弹窗不关 → 「文件仍在」断言前弹窗仍存在，按 exists 判定红）。
///
/// 夹具沿用 ContextMenuUITests：多文件目录 + FLY_START_DIR 启动。触发走菜单
/// File →「Move to Trash」（⌘⌫，MainMenu.swift:32 → menuTrashDelete:462 →
/// doTrashDelete——与 F8/命令行/右键共享同一挂点；裸 F8 的 typeKey 在 XCUITest
/// 不可靠，菜单 AX 可靠且覆盖面等价）。
final class DeleteConfirmUITests: XCTestCase {
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

    /// 3 个文件 → 焦点默认第 1 行（目录优先排序，无目录时按名）→ 删**单个**文件。
    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_del_uitest_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for n in ["aa.txt", "bb.txt", "cc.txt"] {
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

    private func fileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fixture.appendingPathComponent(name).path)
    }

    /// NSAlert(runModal) 的 AX 角色可能是 alert / sheet / dialog：谁先存在谁赢。
    private func waitForPrompt(timeout: TimeInterval = 3) -> XCUIElement? {
        for kind in [app.alerts.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch] {
            if kind.waitForExistence(timeout: timeout) { return kind }
        }
        return nil
    }

    /// 触发删除：菜单 File →「Move to Trash」→ menuTrashDelete → doTrashDelete。
    /// （裸 F8 的 typeKey 在 XCUITest 不稳定；菜单项 AX 点击可靠且共享同一挂点。）
    private func triggerDelete() {
        app.menuBarItems.matching(NSPredicate(format: "title == 'File'")).firstMatch.click()
        app.menuItems.matching(NSPredicate(format: "title == 'Move to Trash'")).firstMatch.click()
    }

    /// 症状①主断言：焦点在单行触发删除 → 必须弹出「Move 1 item(s) to Trash?」确认框。
    /// 变异：恢复 `if targets.count > 1` → 弹窗不出现 → waitForPrompt 返回 nil → 红。
    func testSingleFileDeleteShowsConfirm() throws {
        let target = rowName(0)
        XCTAssertFalse(target.isEmpty)
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        triggerDelete()

        let alert = waitForPrompt()
        XCTAssertNotNil(alert, "单文件删除必须弹确认框（症状①）")
        let text = (alert?.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? "" }.joined(separator: " ")) ?? ""
        XCTAssertTrue(text.contains("1"), "确认文案应含计数 1，实际: \(text)")
        XCTAssertTrue(fileExists(target), "弹框期间文件不得已被删除")
    }

    /// 症状②主断言（删除键）：弹框后直接按 ⏎ → 文件进废纸篓。
    /// 默认焦点没挂在删除键上时 ⏎ 无触发对象 → 文件不消失 → 红。
    func testEnterConfirmsDelete() throws {
        let target = rowName(0)
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        triggerDelete()
        guard waitForPrompt() != nil else {
            return XCTFail("确认框未出现，无法测默认按钮")
        }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        let deadline = Date().addingTimeInterval(5)   // recycle 异步 + 列表刷新
        while fileExists(target) && Date() < deadline { usleep(100_000) }
        XCTAssertFalse(fileExists(target), "⏎ 应确认删除（焦点在删除键上）")
    }

    /// 症状②副断言（取消键）：弹框后按 Esc → 框关、文件仍在。
    func testEscapeCancelsDelete() throws {
        let target = rowName(0)
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        triggerDelete()
        guard let alert = waitForPrompt() else {
            return XCTFail("确认框未出现，无法测取消键")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        usleep(500_000)   // 等框关闭
        XCTAssertFalse(alert.exists, "Esc 后确认框应关闭")
        XCTAssertTrue(fileExists(target), "取消后文件必须仍在")
    }

    /// 显式点「Delete」按钮路径（不依赖 keyEquivalent）：确认删除成功。
    func testClickDeleteButtonConfirms() throws {
        let target = rowName(0)
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        triggerDelete()
        guard let alert = waitForPrompt() else {
            return XCTFail("确认框未出现")
        }
        alert.buttons.matching(NSPredicate(format: "title == 'Delete'")).firstMatch.click()

        let deadline = Date().addingTimeInterval(5)
        while fileExists(target) && Date() < deadline { usleep(100_000) }
        XCTAssertFalse(fileExists(target), "点 Delete 按钮应删除文件")
    }

    /// 显式点「取消」按钮路径：文件仍在（回归确认框接线本身）。
    func testClickCancelButtonKeepsFile() throws {
        let target = rowName(0)
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        triggerDelete()
        guard let alert = waitForPrompt() else {
            return XCTFail("确认框未出现")
        }
        alert.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
        usleep(300_000)   // 等框关闭的间隙，避免与回收异步竞态误绿
        XCTAssertTrue(fileExists(target), "点取消后文件必须仍在")
    }
}
