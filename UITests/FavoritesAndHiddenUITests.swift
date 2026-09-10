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
/// ④ 查看菜单「Show Hidden Files」→ dotfile 探针从表格消失/再点恢复；
/// ⑤ 编号收藏项：typeKey 数字 → type-select 高亮 → 回车跳转（**B 档定档**，见下）；
/// ⑥ 弹出菜单无默认高亮（回车空操作）的行为合同；
/// ⑦ 关菜单后按数字不触发收藏跳转/弹菜单（keyEquivalent 不外泄的负向锁；
///    窗格焦点裸数字实为 type-ahead 字母导航，非命令行栏——命令栏只由右箭头激活）。
///
/// **数字跳转档位 spike 定档（2026-09-10 真窗实测）**：弹出 NSMenu 的 tracking loop 对裸键
/// 走 type-select（标题 "N." 前缀匹配→高亮），**不触发** keyEquivalent（A 案判负）；子类化
/// NSMenu 覆写 performKeyEquivalent 在 tracking 中**根本不被调用**（C 案判负，探针零日志）；
/// 默认高亮三路全灭（`_setHighlightedItem:`/`setHighlightedItem:` 不 responds、KVC 抛
/// NSUnknownKeyException、popUp(positioning: 项) 不产生高亮）→ 需求「回车=切换项」降级为
/// 合同⑥。故交互定为 **按数字高亮 + 回车跳转**（数字同时显示在菜单右列作视觉提示）。
///
/// **为何不测 F2 真按键**：缩减 SDK 无 `XCUIKeyboardKey.functionF2` 常量，且本机 F 键在
/// charactersIgnoringModifiers 报 PUA 码点（CLAUDE.md 环境节 + 记忆 uitest_english_inputmethod），
/// typeKey 键入类断言本就 flaky。F2 现语义=弹活动侧收藏下拉（2026-09 决策变更：不再直切收藏，
/// 切换收进菜单内建项）；「F2→弹对侧菜单」由 Tier-1 `FavoritesWiringTests
/// .testF2HookOpensFavoritesDropdownOnActiveSide`（假呈现器）锁定，「切换项→store 往返+回显」
/// 由 `.testToggleItemRoundTripsStoreWithStatusEcho` 锁定，键位映射 120→openFavoritesMenu
/// 由 KeyDispatcherTests 锁定。本层走**点 🔽** 触发同一弹菜单路径（确定性）。
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
/// 夹具：`visible.txt` + dotfile 探针 `.hidden_probe`（默认隐藏 → ⌘⇧. 后现身）
/// + 子目录 `fav_target/in_target.txt`（数字跳转用例的落点特征）。
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

    /// 1 普通文件 + 1 dotfile 探针 + 1 子目录（内含特征文件，供数字跳转用例观测落点）。
    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_favhidden_uitest_\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        try! "x".write(to: base.appendingPathComponent("visible.txt"), atomically: true, encoding: .utf8)
        try! "x".write(to: base.appendingPathComponent(".hidden_probe"), atomically: true, encoding: .utf8)
        let target = base.appendingPathComponent("fav_target")
        try! fm.createDirectory(at: target, withIntermediateDirectories: true)
        try! "x".write(to: target.appendingPathComponent("in_target.txt"), atomically: true, encoding: .utf8)
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
        let entry = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH '1. '")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5),
                      "新收藏项应以「1. 」编号开头（标题=序号+当前目录名）")
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

    // MARK: - 5. 数字选条跳转（B 档：type-select 高亮 + 回车确认）

    /// 真窗 spike 定档（2026-09-10）：弹出菜单 tracking loop 对裸数字走 **type-select**
    /// （按标题 "N." 前缀匹配 → 高亮该条），keyEquivalent 不自动触发（A 案负）；子类化
    /// NSMenu 覆写 performKeyEquivalent 拿不到裸键（C 案负）。最终交互=「按数字高亮 → 回车跳」。
    ///
    /// 端到端：进子目录收藏之（=2 号，新在前变 1 号前先做）→ 回根收藏根（1 号）→ 弹菜单
    /// 输 "2"+回车 → 左表须显示 2 号目录（子目录）的内容。
    /// 变异：编号 off-by-one（"2." 指向根）→ 表格显示根内容红；jump 分派坏 → 表格不变红。
    /// 注：mask 忘清的守卫在 Tier-1 testNumberingAndBareKeyEquivalents（mask==[] 断言）——
    /// UI 层杀不掉该变异：mask=⌘ 时裸 "2" 修饰符不匹配 keyEquivalent，照样落 type-select。
    func testNumberTypingHighlightsAndReturnJumps() {
        // 1) 进子目录收藏 → store=["1. fav_target"]
        XCTAssertTrue(tapRowAndEnter("fav_target"), "前置：应能进入子目录")
        favoriteCurrentViaMenu()
        // 2) 回根目录再收藏 → store=["1. <根名>", "2. fav_target"]（新在前）。
        // 点 🔽/菜单项后 firstResponder 可能滞留按钮，而 Backspace→parent 走
        // PaneTableView.keyDown（guard firstResponder===self）——先显式回焦窗格。
        focusLeftPane()
        app.typeKey(.delete, modifierFlags: [])   // Backspace → parent（KeyDispatcher 51）
        XCTAssertTrue(waitForRow("fav_target", present: true), "前置：应回到根目录")
        favoriteCurrentViaMenu()

        // 3) 弹菜单 → 输 "2" → 回车 → 应跳 fav_target
        favoritesButton.click()
        XCTAssertTrue(waitForMenuItem(prefix: "2. "), "前置：菜单里有 2 号收藏")
        app.typeKey("2", modifierFlags: [])       // type-select 高亮 "2. fav_target"
        app.typeKey(.return, modifierFlags: [])   // 确认跳转
        XCTAssertTrue(waitForRow("in_target.txt", present: true),
                      "回车后须跳到 2 号目录（其内容 in_target.txt 现身）")
        XCTAssertFalse(leftRowNames().contains("visible.txt"), "确已离开根目录")
    }

    // MARK: - 6. 无默认高亮的负向锁（S3a 判负后的行为合同）

    /// spike 实证：popUp(positioning: 切换项) 不产生默认高亮（回车空操作）。本用例把这个
    /// 结论钉成合同：弹菜单立刻回车 **不得** 触发任何项（收藏态不变、不误跳第一条）。
    /// 变异：若未来有人接上任何「预置高亮」机制导致回车误触切换项 → Unfavorite 被点 →
    /// 再开菜单回「Favorite」态 → 本用例红（合同破坏必须显式改这条测试）。
    func testReturnWithNoHighlightIsNoop() {
        favoriteCurrentViaMenu()               // 当前目录已收藏
        favoritesButton.click()
        XCTAssertTrue(waitForMenuItem(title: "Unfavorite Current Directory"), "前置：切换项=Unfavorite")
        app.typeKey(.return, modifierFlags: [])   // 无高亮直接回车

        favoritesButton.click()
        XCTAssertTrue(waitForMenuItem(title: "Unfavorite Current Directory"),
                      "回车空操作 → 收藏态必须保持 Unfavorite")
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - 7. 负向锁：编号快捷键不外泄（关菜单后按数字无跳转副作用）

    /// 结构论证 + 行为锁：收藏项的 keyEquivalent="1"（mask 空）只在菜单打开的 tracking
    /// loop 里可达——keyEquivalent 的全局扫描（NSApplication.sendEvent）只扫主菜单，
    /// popUp 出去的游离菜单不在其列。若该论证被破坏（菜单被并入主菜单、游离菜单也被
    /// 全局扫描命中），关菜单后的裸数字会触发 jump（窗格换目录）或弹菜单 → 本用例红。
    /// **夹具要点**：收藏的目标必须是**别的目录**（fav_target），不能是当前根目录——否则
    /// 泄漏跳转落回原目录、表格零变化，本负向锁结构性空转（评审订正）。
    /// 注：mask 误设为 ⌘ 的变异**本用例杀不掉**（裸 "1" 修饰符不匹配 ⌘1，全局扫描也扫不到
    /// 游离菜单），其守卫在 Tier-1 `testNumberingAndBareKeyEquivalents` 的 mask==[] 断言。
    /// 现实现窗格焦点可打印键走 type-ahead 字母导航（PaneTableView.typeAheadChar），
    /// 命令栏仅右箭头激活——「数字进命令行栏」不成立（旧计划文案有误）。
    func testDigitsAfterMenuClosedDoNotTriggerJump() {
        // 1 号收藏 = fav_target（≠ 当前根目录）
        XCTAssertTrue(tapRowAndEnter("fav_target"), "前置：应能进入子目录")
        favoriteCurrentViaMenu()
        focusLeftPane()
        app.typeKey(.delete, modifierFlags: [])   // Backspace → parent，回根目录
        XCTAssertTrue(waitForRow("visible.txt", present: true), "前置：应回到根目录")

        favoritesButton.click()
        XCTAssertTrue(waitForMenuItem(prefix: "1. "), "前置：编号项在菜单里")
        app.typeKey(.escape, modifierFlags: [])   // 关菜单（既有 3 处先例路）

        focusLeftPane()
        app.typeKey("1", modifierFlags: [])
        app.typeKey("2", modifierFlags: [])
        // 负锁①：不弹/不留收藏菜单（泄漏若是「弹菜单」形态在此现形）。
        XCTAssertFalse(app.menuItems
            .matching(NSPredicate(format: "title BEGINSWITH '1. '")).firstMatch.exists,
            "关菜单后按数字不得弹/留收藏菜单")
        // 负锁②：没跳到 1 号（泄漏跳走则 1 号内容现身、根内容消失）。
        XCTAssertFalse(leftRowNames().contains("in_target.txt"),
                       "关菜单后按数字不得跳转到 1 号收藏（实际：\(leftRowNames())）")
        XCTAssertTrue(waitForRow("visible.txt", present: true),
                      "关菜单后按数字不得离开根目录（实际：\(leftRowNames())）")
    }

    // MARK: - 助手

    /// 显式把焦点交回左窗格：点 🔽（NSButton）/菜单项后 firstResponder 常滞留在按钮上，
    /// 而裸键（Backspace/数字）经 PaneTableView.keyDown 捕获，其 guard 要求
    /// firstResponder===self——不点表格则键入落空（实测 cmdBar 值恒 ""）。
    private func focusLeftPane() {
        let row = leftTable().tableRows.firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "前置：左表有行可点")
        row.click()
    }

    /// 双击左表指定名字的行进入该目录。不用谓词匹配行（嵌套 staticTexts 查询会挂死
    /// AX 求值，121s 超时实证）——沿 leftRowNames 同款逐行扫描取行句柄。
    private func tapRowAndEnter(_ name: String) -> Bool {
        let rows = leftTable().tableRows.allElementsBoundByIndex
        for row in rows {
            let texts = row.staticTexts.allElementsBoundByIndex
            guard let first = texts.min(by: { $0.frame.minX < $1.frame.minX }) else { continue }
            if (first.value as? String) == name {
                row.doubleClick()
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline {
                    if leftRowNames().contains("in_target.txt") { return true }
                    usleep(100_000)
                }
                return leftRowNames().contains("in_target.txt")
            }
        }
        return false
    }

    /// 经菜单切换项把当前目录收藏进 store（复用用例 3 的确定性路径）。
    private func favoriteCurrentViaMenu() {
        favoritesButton.click()
        let add = app.menuItems.matching(NSPredicate(format: "title == 'Favorite Current Directory'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "前置：切换项应可点")
        add.click()
    }

    /// 等弹出菜单里出现指定 title（精确）或 prefix（BEGINSWITH）的项。
    @discardableResult
    private func waitForMenuItem(title: String? = nil, prefix: String? = nil, timeout: TimeInterval = 5) -> Bool {
        let pred: NSPredicate
        if let title { pred = NSPredicate(format: "title == %@", title) }
        else { pred = NSPredicate(format: "title BEGINSWITH %@", prefix!) }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.menuItems.matching(pred).firstMatch.exists { return true }
            usleep(100_000)
        }
        return app.menuItems.matching(pred).firstMatch.exists
    }

    /// 点查看菜单下的某项（先开菜单条，再点子项；沿用 PaneFilterUITests ⌘⇧F 菜单路数）。
    private func openViewMenuItem(_ title: String) {
        let view = app.menuBarItems.matching(NSPredicate(format: "title == 'View'")).firstMatch
        view.click()
        view.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch.click()
    }
}
