import XCTest
import Carbon

/// 底部状态栏 ↔ 命令栏同槽互换的 XCUITest 合同（默认隐藏、右箭头唤出、回焦收回）。
/// 断言准则（记忆在案）：① 隐藏视图不进 AX 树 → 用 `exists` 判在位性；
/// ② 窗口可见性必须查 `frame.width > 100`——0 宽塌陷时子控件在 AX 里照样查得到；
/// ③ 回显镜像 label 常驻、空串也"存在"→ 判内容须轮询值，不是 waitForExistence。
/// 夹具/输入法切换/杀残留沿用 DeleteConfirmUITests 先例。
final class BottomStatusBarUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()
        fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_bottomstatus_uitest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try String(repeating: "a", count: 100).write(
            to: fixture.appendingPathComponent("aa.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 200).write(
            to: fixture.appendingPathComponent("bb.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: fixture.appendingPathComponent("cc.txt"), atomically: true, encoding: .utf8)

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

    private var mainWindow: XCUIElement { app.windows.element(boundBy: 0) }
    private var statusLine: XCUIElement {
        mainWindow.staticTexts.matching(NSPredicate(format: "identifier == 'bottomStatus'")).firstMatch
    }
    private var echoLine: XCUIElement {
        mainWindow.staticTexts.matching(NSPredicate(format: "identifier == 'bottomStatusMessage'")).firstMatch
    }
    private var cmdInput: XCUIElement {
        mainWindow.textFields.matching(NSPredicate(format: "identifier == 'cmdBarInput'")).firstMatch
    }

    private func typeCommand(_ s: String) {
        for ch in Array(s) { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
    }

    /// 轮询回显镜像直到含指定子串（镜像 label 常驻、空串也"存在"，等存在没有意义）。
    private func waitEcho(containing needle: String, timeout: TimeInterval = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = ""
        repeat {
            text = (echoLine.value as? String) ?? ""
            if text.contains(needle) { return text }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return text
    }

    /// 启动态：命令行隐藏（其输入框不在 AX 树）、状态栏在位且写着焦点文件、窗口真的可见。
    func testLaunchShowsStatusBarHidingCommandLine() {
        // 0 宽塌陷盲区守卫（AX 子控件存在 ≠ 窗口可见）。
        XCTAssertGreaterThan(mainWindow.frame.width, 100, "窗口宽度异常（塌陷盲区）")
        XCTAssertFalse(cmdInput.exists, "命令行默认应隐藏（cmdBarInput 不在 AX 树）")
        XCTAssertTrue(statusLine.waitForExistence(timeout: 5), "状态栏焦点行应在启动即在位")
        let text = (statusLine.value as? String) ?? ""
        XCTAssertFalse(text.isEmpty, "状态栏焦点行不应为空")
        XCTAssertTrue(text.contains("·"), "焦点行是 名·大小·日期 三段，实际：\(text)")
    }

    /// 右箭头唤出 → 状态栏让位（同槽互换，两者不同时在位）。
    func testRightArrowSwapsStatusBarForCommandLine() {
        XCTAssertTrue(statusLine.waitForExistence(timeout: 5), "前置：状态栏在位")
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(cmdInput.waitForExistence(timeout: 3), "右箭头应唤出命令栏")
        XCTAssertFalse(statusLine.exists, "命令栏占槽时状态栏应让位")
    }

    /// Return 执行后自动收回：命令栏消失、状态栏回位、回显镜像留驻（TC 语义）。
    func testReturnExecutesAndRetracts() {
        XCTAssertTrue(statusLine.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(cmdInput.waitForExistence(timeout: 3), "前置：命令栏已唤出")
        typeCommand("ls")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let echo = waitEcho(containing: "3 items")
        XCTAssertTrue(echo.contains("3 items"), "执行回显应镜像到状态栏，实际：\(echo)")
        XCTAssertFalse(cmdInput.exists, "回车执行后命令栏应收回")
        XCTAssertTrue(statusLine.exists, "收回后状态栏应回位")
    }

    /// Esc 取消后自动收回，且连回显镜像一起清空。
    func testEscapeRetractsAndClearsEcho() {
        XCTAssertTrue(statusLine.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(cmdInput.waitForExistence(timeout: 3), "前置：命令栏已唤出")
        typeCommand("ls")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitEcho(containing: "3 items").contains("3 items"), "前置：ls 已回显")
        // 再唤出 → Esc：回显清空 + 收回。
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(cmdInput.waitForExistence(timeout: 3), "前置：命令栏已再次唤出")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual((echoLine.value as? String) ?? "", "", "Esc 应连回显镜像一起清空")
        XCTAssertFalse(cmdInput.exists, "Esc 后命令栏应收回")
        XCTAssertTrue(statusLine.exists, "收回后状态栏应回位")
    }

    /// 点表格行（焦点回窗格的其他路径之一）也必须收回命令栏、状态栏回位。
    func testRowClickRetractsCommandLine() {
        XCTAssertTrue(statusLine.waitForExistence(timeout: 5))
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
        XCTAssertTrue(cmdInput.waitForExistence(timeout: 3), "前置：命令栏已唤出")
        let table = app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
        let row = table.tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "前置：有行可点")
        row.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(cmdInput.exists, "点行后命令栏应收回")
        XCTAssertTrue(statusLine.exists, "点行收回后状态栏应回位")
    }
}
