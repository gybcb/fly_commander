import XCTest
import Carbon

/// 目录外部变更自动刷新（FSEvents）+ 手动刷新 ⌃R 的 Tier 2（真实窗口）回归。
///
/// 协调器逻辑（注册/注销/去抖/过滤/保焦点重载）与手动刷新全链（refresh case →
/// 路由 → 菜单键位 → 命令栏）已由 SPM 层锁死（DirectoryWatcherCoordinatorTests /
/// CommandRouterTests / MainMenuTests / InternalCommandExecutorTests）。本类只补
/// SPM 测不到的**真 FSEvents 跨进程语义 + 真窗可见性变化**：
/// ① 外部进程（=测试进程本身）建文件 → 行自动现身；
/// ② 外部进程删文件 → 行自动消失；
/// ③ View 菜单含「Refresh」项 + ⌃R 按下无副作用（**S2 键路定档探针** + 弱负锁）；
/// ④ 外部变更后焦点行不变（opportunistic：AX 焦点态不可达则 skip，SPM 已锁）。
///
/// **S2 定档说明**：⌃R 走菜单 keyEquivalent 路（MainMenu.swift `add(..., "r", ...,
/// .control)`）。真实效果（触发 reload）在自动刷新存在后**不可单独观测**——任何 ⌃R
/// 能刷出的变化，FSEvents 也会自己刷出来。故本用例是**弱锁**：⌃R 必须 (a) 不 crash、
/// (b) 不误落 ⌘R 重命名（弹出编辑/新窗即红）、(c) 菜单项存在。键位值本身
/// （"r" + [.control]、⌘R 仍是重命名）的强锁在 Tier-1 MainMenuTests。
///
/// 时序合同：FSEvents latency 0.5s（内核合帧）+ 去抖 0.3s → 外部变更 ~1s 内可见；
/// waitForRow 5s 窗绰绰有余（AX 刷新延迟同池）。
///
/// 隔离：`-flyDisableSessionRestore YES`（TestIsolation 抑制偏好落盘）+
/// `-appLanguage en`（英文标题定位）。FLY_START_DIR=夹具目录（双侧同目录）。
/// 测试进程 terminate 清残留实例（记忆 uitest_kill_stale_instance_first）；
/// 输入法切 ABC（记忆 uitest_english_inputmethod）。
final class AutoRefreshUITests: XCTestCase {
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
        XCTAssertTrue(waitForRow("seed.txt", present: true), "前置：夹具文件在表格")
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
            .appendingPathComponent("fly_autorefresh_uitest_\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        try! "x".write(to: base.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        try! "x".write(to: base.appendingPathComponent("doomed.txt"), atomically: true, encoding: .utf8)
        return base
    }

    // MARK: - 定位助手（沿用 FavoritesAndHiddenUITests 实证形态）

    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    private func leftRowNames() -> [String] {
        leftTable().tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    @discardableResult
    private func waitForRow(_ name: String, present: Bool, timeout: TimeInterval = 8) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if leftRowNames().contains(name) == present { return true }
            usleep(100_000)
        }
        return leftRowNames().contains(name) == present
    }

    // MARK: - 1. 外部 create → 行自动现身

    /// 测试进程 = 外部进程（跨进程真 FSEvents 路，非假 fire）。
    /// 变异：删 wirePaneCallbacks 的 noteReloaded 挂点 → 永不现身 → 8s 超时红；
    /// 删事件路径过滤里的「父目录==被监听目录」比较 → 恒不刷 → 红（过滤写反路）。
    func testExternalCreateAppearsAutomatically() throws {
        XCTAssertFalse(leftRowNames().contains("made_by_outside.txt"), "前置：新文件不在表格")
        try "hello".write(to: fixture.appendingPathComponent("made_by_outside.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertTrue(waitForRow("made_by_outside.txt", present: true),
                      "外部建文件后 ~1s 内须自动现身（实际：\(leftRowNames())）")
    }

    // MARK: - 2. 外部 delete → 行自动消失

    /// 变异：relevant 只认 create 系 flag（删 ItemRemoved 路径覆盖——删除事件的父目录
    /// 比较与 create 同路，此断言锁住删除语义本身）→ 行滞留 → 红。
    func testExternalDeleteDisappearsAutomatically() throws {
        XCTAssertTrue(leftRowNames().contains("doomed.txt"), "前置：待删文件在表格")
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("doomed.txt"))
        XCTAssertTrue(waitForRow("doomed.txt", present: false),
                      "外部删文件后行须自动消失（实际：\(leftRowNames())）")
    }

    // MARK: - 3. View 菜单「Refresh」项 + ⌃R 无副作用（S2 键路探针，弱锁——见类注释）

    /// 变异：删 MainMenu 的 refresh 项 → 菜单不见「Refresh」红；
    /// ⌃R 若误落 ⌘R 重命名（修饰符位写错/双路互踩）→ 弹出编辑态/新窗 → windows 计数红。
    func testRefreshMenuItemExistsAndControlRHarmless() throws {
        let view = app.menuBarItems.matching(NSPredicate(format: "title == 'View'")).firstMatch
        view.click()
        let refresh = view.menuItems.matching(NSPredicate(format: "title == 'Refresh'")).firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 5), "View 菜单须含「Refresh」项")
        app.typeKey(.escape, modifierFlags: [])   // 收菜单（菜单条保持高亮时 Esc 只关下拉）

        // S2：⌃R 经菜单 keyEquivalent 触发（键路可达性弱证：不 crash、不误触重命名）。
        focusLeftPane()
        app.typeKey("r", modifierFlags: [.control])
        // 等一拍让潜在 action 落地（保焦点重载幂等 → 列表内容不变）。
        XCTAssertTrue(waitForRow("seed.txt", present: true),
                      "⌃R 后列表须仍在（幂等重载），不得弹重命名/换目录")
        XCTAssertLessThanOrEqual(app.windows.count, 1, "⌃R 不得弹出额外窗口（误落重命名编辑态）")
        XCTAssertTrue(waitForRow("seed.txt", present: true))
    }

    // MARK: - 4. 外部变更后焦点行不变（opportunistic——AX 焦点态不可达则 skip）

    /// 自动刷新的核心合同：内容刷新、焦点原地不动。SPM 层已强锁
    /// （testRelevantEventTriggersDebouncedFocusPreservingReload 断 focusID）；
    /// 本用例只验真窗 AX 焦点投影同事实。PaneTableView 若未把 focus 投为 AX
    /// selected 属性，前置就取不到焦点行 → XCTSkip（计划批准的取舍）。
    func testFocusedRowSurvivesExternalChange() throws {
        focusLeftPane()   // 点首行（seed.txt）= 焦点
        let focused1 = focusedRowName()
        try XCTSkipIf(focused1 == nil,
                      "PaneTableView 焦点未投影为 AX selected——SPM 层已锁焦点保留，跳过真窗重复断言")
        try "hello".write(to: fixture.appendingPathComponent("arrived.txt"),
                          atomically: true, encoding: .utf8)
        XCTAssertTrue(waitForRow("arrived.txt", present: true), "前置：自动刷新已发生")
        let focused2 = focusedRowName()
        XCTAssertEqual(focused2, focused1, "自动刷新不得移动焦点行")
    }

    // MARK: - 助手

    private func focusLeftPane() {
        let row = leftTable().tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "前置：左表有行可点")
        row.click()
    }

    /// 焦点行的名字：行级 AX `selected`（点击行 = selectedRows）。无任何行报 selected
    /// → nil（调用侧决定 skip）。
    private func focusedRowName() -> String? {
        let rows = leftTable().tableRows.matching(NSPredicate(format: "selected == 1"))
            .allElementsBoundByIndex
        guard let row = rows.first else { return nil }
        return row.staticTexts.allElementsBoundByIndex
            .min { $0.frame.minX < $1.frame.minX }?.value as? String
    }
}
