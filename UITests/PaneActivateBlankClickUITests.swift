import XCTest
import Carbon

/// 空白处点击激活窗格的 XCUITest 合同（补齐 PaneTableViewTests 真窗 Tier 1 的 UI 层锁）。
///
/// Tier 1 已证 `ClickForwardingTableView.mouseDown` row<0 分支触发 `activateFromClick()`
/// （变异证伪：改回吞事件 → 精确红）。本锁补的是端到端可达性：真鼠标事件经窗口
/// hit-test 确实走到这个分支，而不是只测分支本身被绕过。
///
/// 可观察信号 = 窗口标题（= 活动窗格路径 displayString()，MainViewController.swift:546）。
/// 两侧同起一目录时标题左右不可区分，故先让一侧（默认活动的左栏）cd 进 sub，
/// 造成"左栏在 sub、右栏仍在启动目录"的差异态：
///   点右栏空白 → 活动切右 → 标题应不再是 …/sub；
///   点左栏空白 → 活动切回左 → 标题应重新是 …/sub。
/// 双向切换都过标题可区分，不依赖激活边框等不进 AX 的属性。
/// 夹具/输入法切换/杀残留沿用 BottomStatusBarUITests 先例。
final class PaneActivateBlankClickUITests: XCTestCase {
    private var app: XCUIApplication!
    private var fixture: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()
        fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_blankactivate_uitest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        // 恰好 3 项（2 文件 + 1 空目录）：远少于表格可见高度，下沿必定是空白区。
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

    private var mainWindow: XCUIElement { app.windows.element(boundBy: 0) }
    private var title: String { mainWindow.title }

    private func table(leftmost: Bool) -> XCUIElement {
        let tables = app.tables.allElementsBoundByIndex
        return leftmost ? tables.min { $0.frame.minX < $1.frame.minX }!
                        : tables.max { $0.frame.minX < $1.frame.minX }!
    }

    /// 点某侧表格自身的空白区（下沿 90% 处，夹具仅 3 项必定落在最后一行下方，
    /// hit-test 落进 ClickForwardingTableView.mouseDown 的 row<0 分支）。
    private func clickBlank(in table: XCUIElement) {
        XCTAssertTrue(table.exists, "目标窗格表格不存在")
        let rows = table.tableRows.allElementsBoundByIndex
        if !rows.isEmpty {
            // 前提自检：目标点 Y 必须低于最后一行（否则点到行上，测的不是空白路）。
            let lastRowMaxY = rows.map { $0.frame.maxY }.max() ?? 0
            let targetY = table.frame.minY + table.frame.height * 0.9
            XCTAssertGreaterThan(targetY, lastRowMaxY, "前提：点击点应在最后一行下方")
        }
        table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
            .press(forDuration: 0.1,
                   thenDragTo: table.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
    }

    private func activateCommandBar() {
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
    }

    private func typeCommand(_ s: String) {
        for ch in Array(s) { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
    }

    private func waitTitle(suffix: String, shouldEndWith: Bool, timeout: TimeInterval = 3) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var t = ""
        repeat {
            t = title
            if t.hasSuffix(suffix) == shouldEndWith { return t }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return t
    }

    // MARK: - 用例

    /// 双向：左栏 cd 进 sub 造成左右异目录 → 点右栏空白激活右（标题离开 sub）
    /// → 点左栏空白激活左（标题回到 sub）。任一路径激活失效都会卡在错误的标题上。
    func testBlankClickActivatesEachPane() {
        // 前置：默认活动窗格 = 左栏，cd sub 只导航左栏，右栏仍在启动目录。
        activateCommandBar()
        typeCommand("cd sub")
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(waitTitle(suffix: "sub", shouldEndWith: true).hasSuffix("sub"),
                      "前置：cd sub 后活动窗格（左栏）标题应为 …/sub，实际：\(title)")

        // 点右栏空白 → 活动窗格切右 → 右栏仍在启动目录，标题应离开 sub。
        clickBlank(in: table(leftmost: false))
        let afterRightClick = waitTitle(suffix: "sub", shouldEndWith: false)
        XCTAssertFalse(afterRightClick.hasSuffix("sub"),
                       "点右栏空白后活动窗格应切到右栏（仍在启动目录），标题仍带 sub 说明没激活：\(afterRightClick)")
        XCTAssertTrue(afterRightClick.hasSuffix(fixture.lastPathComponent),
                      "切右后标题应回到启动目录，实际：\(afterRightClick)")

        // 点左栏空白（左栏导航状态不变，仍在 sub）→ 活动切回左 → 标题应重新带 sub。
        clickBlank(in: table(leftmost: true))
        let afterLeftClick = waitTitle(suffix: "sub", shouldEndWith: true)
        XCTAssertTrue(afterLeftClick.hasSuffix("sub"),
                      "点左栏空白后活动窗格应切回左栏（仍在 sub），标题未带 sub 说明没激活回去：\(afterLeftClick)")
    }
}
