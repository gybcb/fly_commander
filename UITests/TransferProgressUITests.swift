import XCTest
import Carbon

/// T3 进度面板 Tier 2（真窗）回归：真 TransferEngine 后台跑 + 真面板上屏 + 真取消旗。
///
/// 触发路（生产代码，非替身）：`FLY_UI_DEMO=crossCopy` 把右窗格换成 isRemote 的
/// 本地夹具源（UICrossCopyDemo.swift，#if DEBUG）→ router.handleTransfer 见远端端
/// → onRemoteTransfer → presentTransfer + transferEngine.run（跨 sourceID → 真 pump）。
///
/// 可证伪性：
/// - 断 onRemoteTransfer → presentTransfer 接线 → 三个用例面板永不出现，全红。
/// - 删 cancelPressed 的 cancel?.cancel() → 取消/转义两用例红：旗不置位 → pump 跑满
///   16MB（~25s），面板走 done 自关——exists 轮询最长 10s 内面板可能已关，但目标文件
///   写满 16MB → 「目标不应写满」断言红。
/// - 删 onFinished 的 finishCancelled 收口 → 旗置位后引擎报 .idle（无裁决），面板
///   永无 done/failed → 不关 → 「面板应关闭」断言红。
///
/// 断言降级为**窗口+按钮级**（历史坑：accessoryView 内文本 AX 可达性不稳）；
/// 文本正确性由 SPM TransferProgressPanelTests 覆盖。
final class TransferProgressUITests: XCTestCase {
    var app: XCUIApplication!

    /// src 目录 = 左窗格（真本地）；dst 目录 = 右窗格假远端根。分离避免自覆盖。
    var srcDir: URL!
    var dstDir: URL!

    /// delayMs=每 64KB 块休眠毫秒（取消用例=传输可点窗口）；size=夹具字节数。
    private func launch(delayMs: Int, sizeMB: Int) {
        switchToEnglishInputSource()
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_t3_uitest_\(UUID().uuidString)")
        srcDir = base.appendingPathComponent("src")
        dstDir = base.appendingPathComponent("dst")
        try! FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let data = Data(repeating: 0x41, count: sizeMB * 1024 * 1024)
        try! data.write(to: srcDir.appendingPathComponent("blob.bin"))
        app = XCUIApplication()
        app.terminate()   // 清残留进程（同 bundle id 抢占 → activate 超时假红）
        app.launchArguments = ["-appLanguage", "en", "-flyDisableSessionRestore", "YES"]
        app.launchEnvironment = [
            "FLY_START_DIR": srcDir.path,
            "FLY_UI_DEMO": "crossCopy",
            "FLY_UI_DEMO_DIR": dstDir.path,
            "FLY_UI_DEMO_DELAYMS": "\(delayMs)",
        ]
        app.launch()
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 20), "主窗表格未出现")
    }

    override func tearDown() {
        app?.terminate()
        let base = srcDir?.deletingLastPathComponent()
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func switchToEnglishInputSource() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        for s in cf {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id == "com.apple.keylayout.ABC" { TISSelectInputSource(s); return }
        }
    }

    private func destFile() -> URL { dstDir.appendingPathComponent("blob.bin") }

    private func panel() -> XCUIElement { app.windows["Transferring…"] }
    private func cancelButton() -> XCUIElement { panel().buttons["Cancel"] }

    /// 取消：16MB + 250ms/64KB（256 块 → 传输窗 ≥60s，且 10s 取消等待期内绝无 done
    /// 竞态——若 done 先到，面板会自关且目标写满，双断言必红）→ 点 Cancel →
    /// 面板关闭 + 目标文件被截断（远小于 16MB——取消在块边界生效，残缺文件维持现状不删）。
    func testCancelPressClosesPanel() {
        launch(delayMs: 250, sizeMB: 16)
        XCTAssertTrue(panel().waitForExistence(timeout: 10), "进度面板未出现")
        XCTAssertTrue(cancelButton().waitForExistence(timeout: 5), "取消按钮未出现")
        cancelButton().click()
        // 关面板 = orderOut；用 !exists（wait 到消失）而非等标题变化。
        let deadline = Date().addingTimeInterval(10)
        while panel().exists && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(panel().exists, "取消后面板应关闭")
        let size = (try? Data(contentsOf: destFile())).map { $0.count } ?? -1
        XCTAssertLessThan(size, 16 * 1024 * 1024, "取消后目标不应写满（pump 已停）")
    }

    /// Esc 与按钮同路（cancelOperation → cancelPressed）。
    func testEscapeCancelsTransfer() {
        launch(delayMs: 250, sizeMB: 16)
        XCTAssertTrue(panel().waitForExistence(timeout: 10), "进度面板未出现")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        let deadline = Date().addingTimeInterval(10)
        while panel().exists && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(panel().exists, "Esc 后面板应关闭")
    }

    /// 完成路：1MB + 100ms/64KB（16 块 ≈ 1.6s pump + 0.8s done 驻留 ≈ 2.4s 可见窗）
    /// → 跑完 done 收口自关，目标文件写满。
    /// 断言**结果**（面板消失+目标完整）而非瞬时 "Done" 文本——历史 AX 文本坑 + 竞态；
    /// 延迟太小会让传输在 XCUITest 首次 AX 轮询前就结束（面板永不可见，waitForExistence 红）。
    func testCompletedTransferClosesPanelAndWritesAllBytes() {
        launch(delayMs: 100, sizeMB: 1)
        XCTAssertTrue(panel().waitForExistence(timeout: 10), "进度面板未出现")
        let deadline = Date().addingTimeInterval(30)
        while panel().exists && Date() < deadline { usleep(50_000) }
        XCTAssertFalse(panel().exists, "完成后面板应自关")
        let size = (try? Data(contentsOf: destFile())).map { $0.count } ?? -1
        XCTAssertEqual(size, 1024 * 1024, "完成传输目标应完整")
    }
}
