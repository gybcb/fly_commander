import XCTest
import Carbon

/// 删除确认框的 **F8 入口** 回归（真窗 Tier-2）——补上既有测试的整块盲区。
///
/// 为什么另开一类：`DeleteConfirmUITests` / `DeleteConfirmFocusUITests` 全部**刻意绕开 F8**
/// （注释原文「裸 F8 的 typeKey 在 XCUITest 不可靠」），改走菜单/工具栏/右键/命令行。
/// 但用户**只用 F8**，而 F8 恰好是把 `alert.runModal()` 直接开在 `keyDown` 事件派发栈里的
/// 唯一入口（`PaneTableView.keyDown` → `.delete` → `doTrashDelete`），其余入口都不在那个栈内。
/// 本机 SDK 的 `XCUIKeyboardKeys.h` 导出了 `XCUIKeyboardKeyF8`，故该入口可测。
///
/// 三臂的绿红组合直接指向机制：
/// - A 臂（F8 → 主键盘 ⏎）：红 = 复现用户「回车确认删除也不行」。
/// - B 臂（F8 → 小键盘 ⌤）：红而 A 绿 = 键等价 `"\r"` 不吃小键盘 Enter（用户是 Mac mini，
///   全尺寸键盘手边就是 ⌤）。
/// - C 臂（F8 → Esc ×5）：红 = 复现「Esc 时好时坏」。
final class DeleteConfirmF8UITests: XCTestCase {
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
            .appendingPathComponent("fly_del_f8_\(UUID().uuidString)")
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
    private func waitForPrompt(timeout: TimeInterval = 5) -> XCUIElement? {
        for kind in [app.alerts.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch] {
            if kind.waitForExistence(timeout: timeout) { return kind }
        }
        return nil
    }

    private func anyPromptExists() -> Bool {
        app.alerts.firstMatch.exists || app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists
    }

    /// 用户入口：焦点在文件行 → 裸 F8。返回弹出来的确认框（nil = F8 没送达/没弹框）。
    ///
    /// 注入方式（**实测定的，别乱换**）：
    /// - `XCUIKeyboardKey.f8` 常量在本机 macOS SDK 里**不存在**（`XCUIKeyboardKeys.h` 的
    ///   F1–F19 只出现在 **tvOS** 平台的同名头文件中；`swiftc -typecheck` 实证 `no member 'f8'`）。
    /// - 但用 PUA 字符构造 `XCUIKeyboardKey(rawValue: "\u{F708}")` 交给 `typeKey` **可以送达**：
    ///   F8 的 `charactersIgnoringModifiers` 就是 U+F708，app 侧确实按 keyCode 100 收到
    ///   （2026-09-12 实测：同一条用例一次送达，确认框正常弹出）。
    /// - 曾用系统级 `CGEvent(virtualKey: 100)` 直投 HID：**不可靠**——同一套用例时灵时不灵，
    ///   加"重试"后反而 4/4 全红。已弃用。
    @discardableResult
    private func triggerDeleteWithF8() -> XCUIElement? {
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        app.typeKey(XCUIKeyboardKey(rawValue: "\u{F708}"), modifierFlags: [])
        return waitForPrompt()
    }

    private func waitUntilGone(_ name: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while fileExists(name) && Date() < deadline { usleep(100_000) }
    }

    // MARK: - 注入通道守卫：F8 必须能被 typeKey(PUA) 送达

    /// 这条不测产品行为，测**测试通道**：若哪天 XCUITest/SDK 不再把 U+F708 映射成 kVK_F8，
    /// 下面所有 F8 臂都会以「F8 未弹出确认框」告负——有这条在，就能一眼区分
    /// 「通道坏了」与「产品坏了」，不至于把通道问题误判成回归。
    func testF8InjectionPathDelivers() throws {
        leftTable().tableRows.allElementsBoundByIndex[0].click()
        app.typeKey(XCUIKeyboardKey(rawValue: "\u{F708}"), modifierFlags: [])
        guard waitForPrompt(timeout: 8) != nil else {
            return XCTFail("typeKey(U+F708) 没能把 F8 送到 app —— 测试通道坏了，不是产品回归")
        }
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])   // 收尾，别留给下一条
    }

    // MARK: - A 臂：F8 → 主键盘 ⏎ 确认

    func testF8ThenReturnConfirmsDelete() throws {
        let target = rowName(0)
        XCTAssertFalse(target.isEmpty)
        guard triggerDeleteWithF8() != nil else {
            return XCTFail("F8 未弹出确认框（要么 F8 没送达，要么单文件删除确认被回退）")
        }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

        waitUntilGone(target, timeout: 6)
        XCTAssertFalse(fileExists(target), "F8 入口下 ⏎ 应确认删除")
    }

    // MARK: - B 臂：F8 → 小键盘 ⌤（keyCode 76）确认

    func testF8ThenNumpadEnterConfirmsDelete() throws {
        let target = rowName(0)
        guard triggerDeleteWithF8() != nil else {
            return XCTFail("F8 未弹出确认框")
        }
        app.typeKey(XCUIKeyboardKey.enter, modifierFlags: [])

        waitUntilGone(target, timeout: 6)
        XCTAssertFalse(fileExists(target), "F8 入口下小键盘 ⌤ 应与 ⏎ 等价")
    }

    // MARK: - C 臂：F8 → Esc 取消（跑 5 轮抓「时好时坏」）

    func testF8ThenEscapeCancelsDeleteRepeated() throws {
        let target = rowName(0)
        for round in 1...5 {
            guard let alert = triggerDeleteWithF8() else {
                return XCTFail("第 \(round) 轮 F8 未弹出确认框")
            }
            app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
            usleep(500_000)
            XCTAssertFalse(alert.exists, "第 \(round) 轮 Esc 后确认框应关闭")
            XCTAssertTrue(fileExists(target), "第 \(round) 轮取消后文件必须仍在")
        }
    }

    // MARK: - 关于"点按钮"对照臂

    // 曾有一条「F8 触发后点 Delete 按钮」的对照臂，用于区分「键路由坏」与「框/删除链坏」。
    // **已删除**，原因记在这里免得后人重蹈：本机 AX 树下该查询是竞态的——框元素出现与
    // 其子按钮暴露之间有延迟，同一台机器上实测出现过「dialog 下有 5 个按钮」与
    // 「5 秒都等不到 Delete 按钮」两种结果（`app.dialogs.firstMatch.buttons`、
    // `app.buttons`、`alert.buttons` 三种作用域都试过）。而它的诊断目的已被 A/B 臂覆盖：
    // 那两条用键盘确认后同样断言文件真的消失，框与删除链坏了它们也会红。
    // 另注：本文件在当前机器上**无法区分修前/修后**——把调用点还原成裸 `runModal()` 后
    // A/B/C 三臂同样全绿（2026-09-12 差分实测）。故它是 F8 入口的行为回归锁，不是本次修复的证据。
}
