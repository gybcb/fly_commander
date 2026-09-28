import XCTest
import Carbon

/// ⌃1/⌃2/⌃3 拷贝路径三件套的 XCUITest 合同：真键盘注入 → 真 NSPasteboard。
///
/// Tier 1 已锁 CommandRouter 产出语义（CopyPathTests：三粒度/多标记/空目标），
/// 本锁补的是 UI 端端到端：keyCode+⌃ → CommandID 映射、菜单键等价接线（MainMenu
/// "1"/"2"/"3"+.control）、onCopyPaths → 剪贴板落盘。三链路 Tier 1 都不经过。
///
/// 剪贴板读法：runner 与 app 同用户会话 → NSPasteboard.general 是同一份系统剪贴板，
/// 测试进程直接轮询即可（无沙盒：project.yml 无 entitlements/App Sandbox）。
/// 夹具/输入法切换/杀残留沿用 BottomStatusBarUITests 先例。
final class CopyPathUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()
        fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_copypath_uitest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        try "a".write(to: fixture.appendingPathComponent("aa.txt"), atomically: true, encoding: .utf8)
        try "b".write(to: fixture.appendingPathComponent("bb.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)

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

    // MARK: - 助手

    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    private func leftRowNames() -> [String] {
        leftTable().tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    /// 点击 name 行把焦点移过去（无标记 → 拷贝目标 = 焦点单项）。
    private func focusRowNamed(_ name: String) {
        let names = leftRowNames()
        guard let idx = names.firstIndex(of: name) else {
            return XCTFail("夹具行不存在：\(name)，现有：\(names)")
        }
        let row = leftTable().tableRows.allElementsBoundByIndex[idx]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// 清空剪贴板 → ⌃+digit → 轮询到非空内容返回（app 侧写板有毫秒级延迟）。
    private func copyWithControl(_ digit: String) -> String {
        let pb = NSPasteboard.general
        pb.clearContents()
        app.typeKey(XCUIKeyboardKey(rawValue: digit), modifierFlags: .control)
        let deadline = Date().addingTimeInterval(3)
        var text = ""
        repeat {
            text = pb.string(forType: .string) ?? ""
            if !text.isEmpty { return text }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return text
    }

    /// 期望值 = TCPath.displayString 的 home→~ 替换（TCPath.swift:55-60）。
    /// home 必须取真实家目录：runner 是沙盒进程，NSHomeDirectory()/
    /// homeDirectoryForCurrentUser 都被重定向进 xctrunner 容器，与被测 app（无沙盒，
    /// home=真实家目录）不一致会误替换前缀。getpwuid 走目录服务，不受沙盒重定向影响。
    private func display(_ url: URL) -> String {
        var p = url.path
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            let home = String(cString: dir)
            if p == home { return "~" }
            if p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        }
        return p
    }

    // MARK: - 用例

    /// ⌃1 全路径 / ⌃2 所在目录（文件条目=父目录，不含文件名）。
    func testCtrl1CopiesFullPathCtrl2CopiesParentDir() {
        focusRowNamed("bb.txt")
        let full = copyWithControl("1")
        XCTAssertEqual(full, display(fixture.appendingPathComponent("bb.txt")),
                       "⌃1 应为焦点条目全路径")
        let dir = copyWithControl("2")
        XCTAssertEqual(dir, display(fixture), "⌃2 文件的所在目录应为父目录")
        XCTAssertFalse(dir.hasSuffix("bb.txt"), "⌃2 不得含文件名本身")
    }

    /// ⌃2 目录条目 → 自身路径（"这个目录"的路径，非其父）。
    func testCtrl2OnDirectoryCopiesItself() {
        focusRowNamed("sub")
        let dir = copyWithControl("2")
        XCTAssertEqual(dir, display(fixture.appendingPathComponent("sub")),
                       "⌃2 目录条目应为自身路径")
    }

    /// ⌃3 仅名称：无路径前缀。
    func testCtrl3CopiesBareName() {
        focusRowNamed("aa.txt")
        let name = copyWithControl("3")
        XCTAssertEqual(name, "aa.txt", "⌃3 应只有文件名")
    }
}
