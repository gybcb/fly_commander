import XCTest

/// Tier 2 UI 回归：软件更新窗（不联网）。
///
/// 夹具注入口 `-flyUpdateDemoWindow YES`（仅 DEBUG 构建生效）：AppDelegate 在
/// TestIsolation 抑制守卫**之前**检查该参数，直接调 `UpdateFlow.presentDemoWindowForTest()`
/// 呈现假清单（version 99.0.0）的「发现新版本」态——测试全程零网络请求。
/// 真实自动检查（启动 10s 首检 / 24h Timer）在 UI 测试模式下被 TestIsolation 抑制，
/// 但为双保险本类也不给超过 10s 的等待窗口内做联网依赖断言。
final class UpdateWindowUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.terminate()   // 清掉上一用例可能残留的进程（同 bundle-id 残留 = activate 超时坑）
        app.launchArguments = ["-appLanguage", "en",
                               "-flyDisableSessionRestore", "YES",
                               "-flyUpdateDemoWindow", "YES"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// 更新窗（子窗定位惯用法：title == 谓词，仿 Find Files / SFTP Connection）。
    private func updateWindow() -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == 'Software Update'")).firstMatch
    }

    /// 更新窗应自动上屏，三按钮（立即升级/稍后/跳过此版本）AX 可达，正文含假版本号。
    func testDemoUpdateWindowShowsButtons() {
        let win = updateWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 20), "更新窗（Software Update）未出现")

        for id in ["update.upgrade", "update.later", "update.skip"] {
            let btn = win.descendants(matching: .button)
                .matching(NSPredicate(format: "identifier == %@", id)).firstMatch
            XCTAssertTrue(btn.exists, "按钮 \(id) 不可达")
        }
        // 假清单版本 99.0.0 应出现在正文（en：A new version 99.0.0 is available…）。
        XCTAssertTrue(win.staticTexts.matching(
            NSPredicate(format: "value CONTAINS '99.0.0'")).firstMatch.exists,
            "正文应含假清单版本号 99.0.0")
    }

    /// 「稍后」按钮关窗（orderOut），窗从窗口列表消失。
    func testLaterButtonClosesWindow() {
        let win = updateWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 20), "更新窗未出现")
        win.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier == 'update.later'")).firstMatch.click()
        XCTAssertFalse(win.waitForExistence(timeout: 3), "点稍后后更新窗应已关闭")
    }
}
