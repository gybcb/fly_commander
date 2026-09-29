import XCTest
import Carbon

/// Task 5 Tier 2（真窗）：假路由演示模式 `FLY_UI_DEMO=direct` 直接驱动进度面板灌
/// 假 CopyRoute 帧（不经 router/引擎），断言 Task 2 的 route 文案 + 字节/速度文本真上屏。
///
/// 可证伪性：
/// - 删 `apply(route:)` 里 routeLabel.stringValue 赋值 → 两用例 route 文本永不出现，红。
/// - 删 directCrossHost→systemGreen / relayed→systemYellow 色点分支 → 文本侧仍可证 route
///   文案对，色点本身由 SPM TransferProgressPanelTests（probe.routeDotGreen）覆盖。
/// - 删 apply(_:) 速度串拼接 → "/s" 断言红。
///
/// 路由分两个用例各起一次 app（env 选路由），面板泵到终帧后**冻结驻留**（demo 不调 finish）
/// → route + 真字节 + 速度串静态可见，无相位竞态。文本断言用子串匹配（ByteCountFormatter
/// 渲染字节/速度，整串跨 locale/系统版本不稳），且用英文 locale 下实测 EN 串：
/// direct="Direct server-to-server"、needsAuth="…no key trust…"、速度模板含 "/s"。
final class DirectRouteDemoUITests: XCTestCase {
    var app: XCUIApplication!

    private func switchToEnglishInputSource() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        for s in cf {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id == "com.apple.keylayout.ABC" { TISSelectInputSource(s); return }
        }
    }

    private func launch(routeKind: String) {
        switchToEnglishInputSource()
        app = XCUIApplication()
        app.terminate()   // 清残留进程（同 bundle id 抢占 → activate 超时假红）
        app.launchArguments = ["-appLanguage", "en", "-flyDisableSessionRestore", "YES"]
        app.launchEnvironment = [
            "FLY_UI_DEMO": "direct",
            "FLY_UI_DEMO_ROUTE": routeKind,
        ]
        app.launch()
    }

    override func tearDown() {
        app?.terminate()
    }

    private func panel() -> XCUIElement { app.windows["Transferring…"] }

    /// 面板内包含指定子串的静态文本（route/detail 均为 labelWithString → AX staticText）。
    private func textContaining(_ needle: String) -> XCUIElement {
        panel().staticTexts.matching(
            NSPredicate(format: "value CONTAINS[c] %@", needle)).firstMatch
    }

    /// 绿点路由：directCrossHost → "Direct server-to-server" + 速度串（含 "/s"）同屏。
    func testDirectRouteShowsTextAndSpeed() {
        launch(routeKind: "direct")
        XCTAssertTrue(panel().waitForExistence(timeout: 20), "进度面板未出现")
        XCTAssertTrue(textContaining("Direct server-to-server").waitForExistence(timeout: 10),
                      "应显示直传路由文案 'Direct server-to-server'")
        XCTAssertTrue(textContaining("/s").waitForExistence(timeout: 10),
                      "字节进度应带速度串（含 '/s'）")
    }

    /// 黄点路由：relayed(.needsAuth) → "…no key trust…" 文案上屏。
    func testRelayedNeedsAuthShowsText() {
        launch(routeKind: "needsAuth")
        XCTAssertTrue(panel().waitForExistence(timeout: 20), "进度面板未出现")
        XCTAssertTrue(textContaining("no key trust").waitForExistence(timeout: 10),
                      "应显示 needsAuth 回退文案（含 'no key trust'）")
    }
}
