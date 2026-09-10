import XCTest
import Carbon

/// 目录收藏夹 + 隐藏文件开关的 Tier 2（真实窗口）回归。
///
/// 内核闸门（FilePane.showHidden 双闸）与 App 接线（wireFavorites / 菜单键绑定 /
/// toggleFavorite / jump 分派）已由 SPM 层锁死（FilePaneHiddenFilesTests /
/// FavoritesWiringTests / FavoritesMenuBuildTests / HiddenFilesWiringTests）。本类只补
/// SPM 测不到的**真实 AX 树可达性 + 端到端可见性变化**：
/// ① 标签条常驻 🔽 按钮在真窗存在（左右各一）；
/// ② 点 🔽 弹出 NSMenu（含「Favorite Current Directory」切换项）；
/// ③ 经菜单切换项收藏当前目录 → 再开菜单出现该收藏项 + 「Unfavorite」态（同会话内存态）；
/// ④ 查看菜单「Show Hidden Files」→ dotfile 探针从表格消失/再点恢复。
///
/// **为何不测 F2 真按键**：缩减 SDK 无 `XCUIKeyboardKey.functionF2` 常量，且本机 F 键在
/// charactersIgnoringModifiers 报 PUA 码点（CLAUDE.md 环境节 + 记忆 uitest_english_inputmethod），
/// typeKey 键入类断言本就 flaky。F2→favoriteDirectory→store 往返已由 Tier-1
/// `FavoritesWiringTests.testF2HookTogglesStoreWithStatusEcho` 覆盖，故本层改走**菜单切换项**
/// 触发同一 toggleFavorite（确定性），F2 键位绑定由 Tier-1 KeyDispatcherTests 锁定。
///
/// 真实 AX 事实（沿用既有 UI 测试实证）：
/// - 左右表消歧 = 两个 table 中 `frame.minX` 最小者为左表；行名 = 行内 x 最小 StaticText 的 `value`。
/// - 弹出的 NSMenu（含 `menu.popUp`）经 `app.menuItems`（title 匹配）访问（ContextMenuUITests 实证）。
/// - 同标识多份（左右窗格各一 🔽）取 x 最小者 = 左窗格。
///
/// 隔离：launchArguments 带 `-flyDisableSessionRestore YES`（→ TestIsolation 抑制收藏/
/// 隐藏开关落盘，夹具不污染开发者偏好）+ `-showHiddenFiles NO`（argument domain 定「启动即隐藏」，
/// `bool(forKey:)` 读到 NO=false；不写回真实 plist）。`-appLanguage en` 定位符按英文标题匹配。
///
/// 夹具：`visible.txt` + dotfile 探针 `.hidden_probe`（默认隐藏 → ⌘⇧. 后现身）。
final class FavoritesAndHiddenUITests: XCTestCase {
    var app: XCUIApplication!
    var fixture: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()
        fixture = makeFixture()
        app = XCUIApplication()
        app.terminate()   // 清残留进程（同 bundle id 抢占 → activate 超时假红）
        app.launchArguments = ["-appLanguage", "en",
                               "-flyDisableSessionRestore", "YES",
                               "-showHiddenFiles", "NO"]
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

    /// 1 普通文件 + 1 dotfile 探针（+1 子目录保行序稳定）。
    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_favhidden_uitest_\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        try! "x".write(to: base.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try! "x".write(to: base.appendingPathComponent(".hidden_probe"), atomically: true, encoding: .utf8)
        return base
    }

    // MARK: - 定位助手

    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    private func leftRowNames() -> [String] {
        leftTable().tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    /// 同标识多份取 x 最小者 = 左窗格。
    private func leftElement(_ type: XCUIElement.ElementType, _ id: String) -> XCUIElement {
        let m = app.descendants(matching: type).matching(identifier: id)
        return m.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX } ?? m.firstMatch
    }

    private var favoritesButton: XCUIElement { leftElement(.button, "paneFavoritesButton") }

    /// 轮询等左表行名集合含/不含某探针（AX 刷新有延迟）。
    @discardableResult
    private func waitForRow(_ name: String, present: Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if leftRowNames().contains(name) == present { return true }
            usleep(100_000)
        }
        return leftRowNames().contains(name) == present
    }

    // MARK: - 1. 🔽 按钮在真窗存在（左右各一）

    /// 变异：TabBarView init 漏设 AX 标识 / favoritesButton 被塞进 stack（导航后被 rebuild 销毁）
    /// → 计数不足 2 或不存在 → 本用例红。
    func testFavoritesButtonExistsOnBothSides() {
        let all = app.buttons.matching(identifier: "paneFavoritesButton")
        XCTAssertGreaterThanOrEqual(all.count, 2, "左右标签条各有一个常驻 🔽")
        XCTAssertTrue(favoritesButton.exists)
    }

    // MARK: - 2. 点 🔽 弹出收藏菜单（含切换项）

    /// 变异：`favoritesClicked` 不回调 onFavorites / wireTabBar 未接 showFavoritesDropdown
    /// → 菜单不弹 → "Favorite Current Directory" 不出现 → 红。
    func testFavoritesButtonPopsMenuWithToggleItem() {
        favoritesButton.click()
        let toggle = app.menuItems.matching(NSPredicate(format: "title == 'Favorite Current Directory'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "点 🔽 应弹收藏菜单，含「收藏当前目录」切换项（空收藏时仅此一项）")
        app.typeKey(.escape, modifierFlags: [])   // 关菜单
    }

    // MARK: - 3. 菜单切换项收藏当前目录 → 再开见收藏项 + Unfavorite 态

    /// 端到端（同会话内存态）：点切换项 → store 加入当前目录（displayName=夹具末段名）→
    /// 再开菜单出现该收藏项与「Unfavorite Current Directory」。
    /// 变异：toggleFavorite 的 add/remove 分支写反 → 第二次开菜单不见 Unfavorite → 红；
    /// 菜单构建顺序错（收藏项没在前）→ 标志项 title 匹配不到 → 红。
    func testMenuToggleItemFavoritesCurrentDirectoryAndReflectsState() {
        // 第一次开菜单：点「Favorite Current Directory」。
        favoritesButton.click()
        let add = app.menuItems.matching(NSPredicate(format: "title == 'Favorite Current Directory'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "前置：切换项应可点")
        add.click()

        // 第二次开菜单：应见「Unfavorite」（当前目录已收藏）+ 收藏项本身（标题=夹具末段名）。
        favoritesButton.click()
        let unfav = app.menuItems.matching(NSPredicate(format: "title == 'Unfavorite Current Directory'")).firstMatch
        XCTAssertTrue(unfav.waitForExistence(timeout: 5), "收藏当前目录后，切换项须翻成「取消收藏」")
        let entry = app.menuItems.matching(NSPredicate(format: "title == %@", fixture.lastPathComponent)).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5),
                      "新收藏项（标题=当前目录名）应出现在菜单里")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - 4. ⌘⇧. 切换隐藏文件（探针消失/现身）

    /// 启动 showHidden=NO（argument domain）→ 探针不在表格。查看菜单「Show Hidden Files」
    /// → showHidden 翻 true → 探针现身；再点 → 回隐。
    /// 变异：recomputeVisibility 隐藏闸失效 → 初始就可见 → 前置断言红；menuToggleHidden
    /// 不遍历 pane 设值 → 点后行数不变 → 红。走菜单入口（同 ⌘⇧. 的 action，确定性优先于键入）。
    func testShowHiddenFilesMenuRevealsAndHidesProbe() {
        XCTAssertFalse(leftRowNames().contains(".hidden_probe"),
                       "前置：默认隐藏 → 探针不应在表格（实际：\(leftRowNames())）")
        XCTAssertTrue(waitForRow("visible.txt", present: true), "前置：普通文件在表格")

        openViewMenuItem("Show Hidden Files")
        XCTAssertTrue(waitForRow(".hidden_probe", present: true),
                      "开「显示隐藏文件」后探针应现身（实际：\(leftRowNames())）")

        openViewMenuItem("Show Hidden Files")
        XCTAssertTrue(waitForRow(".hidden_probe", present: false),
                      "再点关「显示隐藏文件」后探针应回隐（实际：\(leftRowNames())）")
    }

    /// 点查看菜单下的某项（先开菜单条，再点子项；沿用 PaneFilterUITests ⌘⇧F 菜单路数）。
    private func openViewMenuItem(_ title: String) {
        let view = app.menuBarItems.matching(NSPredicate(format: "title == 'View'")).firstMatch
        view.click()
        view.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch.click()
    }
}
