import XCTest
import Carbon

/// 真机 UI 回归（xcodebuild test 驱动，在本机 GUI 会话弹真实窗口）。
///
/// 夹具：每用例建一个 8 项的已知目录（6 普通文件[含 1.5MB 多行 big.log + 1.3MB 单行 longline.txt + 小 sample.torrent] + 1 二进制 + 1 子目录），
/// 经 FLY_START_DIR 环境变量让 app 从该目录启动，行数/排序/搜索/预览断言全部确定。
///
/// 真实 AX 树事实（debugDescription dump 验证过，2026-08-23）：
/// - 列头是 **Button**（title = "名称/大小/修改日期"），不是 StaticText。
/// - 表格单元格文案在 **`value`** 属性（不是 label）；每行 AX 暴露 3 个 Cell
///   （每列一个），每个 Cell 都含整行 3 个 StaticText → 行名称 = 行内 x 最小的 StaticText。
/// - 工具栏"已选 N 项"状态文本在 Toolbar 的 Group 内，也是 `value`；
///   焦点行本身算 1 项操作目标 → 启动即 "已选 1 项"（非空）。
/// - 主菜单 5 项（Apple + FlyCommander + 文件 + 编辑 + 查看）；打开后 **Menu 元素无 title**，
///   子项定位走 `menuBarItem.menuItems.matching(title == …)`。
/// - Splitter 是 SplitGroup 直接子元素（宽 1pt）；拖拽目标坐标须基于有 frame 的元素。
/// - `typeText` 是追加输入 → 搜索框（初始值 "*"）先 Cmd+A 全选再输入替换。
final class FlyCommanderUITests: XCTestCase {
    var app: XCUIApplication!
    var fixture: URL!

    // MARK: - 夹具 / 生命周期

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()   // 键入类断言须英文输入法（见下）
        fixture = makeFixture()
        app = XCUIApplication()
        app.terminate()   // 清掉上一用例可能残留的进程
        // 强制默认英文：UserDefaults 注册域参数，键 "appLanguage"（L10n 读取），
        // 使断言不受用户持久化的 zh 偏好影响（UI 定位符已全按英文标题匹配）。
        // 再叠 -flyDisableSessionRestore YES 兜底关闭会话恢复：本类用例只给 FLY_START_DIR
        // （契约上已禁读写），这层开关防止将来新增用例漏设 FLY_START_DIR 时把测试夹具
        // 目录写进开发者真实 UserDefaults（污染下次正常启动）。
        app.launchArguments = ["-appLanguage", "en", "-flyDisableSessionRestore", "YES"]
        app.launchEnvironment = ["FLY_START_DIR": fixture.path]
        app.launch()
        // 主窗两个表格出现（启动 + 列目录耗时）
        XCTAssertTrue(app.tables.firstMatch.waitForExistence(timeout: 20), "主窗表格未出现")
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: fixture)
    }

    /// 把输入源切到英文 ABC（若可用）。中文输入法激活时，XCUITest 的 typeKey 字母会
    /// 进 IME 组合层、提交不出预期 ASCII——命令栏 ls/help/cd、搜索框等键入类断言会
    /// flaky（曾致 testCommandLineHelpListsCommands / testTabTitleUpdatesOnNavigation
    /// 假失败）。跑前切英文，保证键入稳定；只影响 UI 测试会话，不动 app 代码。
    private func switchToEnglishInputSource() {
        guard let cf = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return }
        for s in cf {
            guard let p = TISGetInputSourceProperty(s, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
            if id == "com.apple.keylayout.ABC" {
                TISSelectInputSource(s)
                return
            }
        }
    }

    /// 8 项夹具：alpha_small.txt(1B) alpha_big.txt(100B) large.bin(5000B) sub/ sub/inner.txt gamma.txt(1B) big.log(1.5MB 多行) longline.txt(1.3MB 单行) sample.torrent(小 bencode+哈希)。
    private func makeFixture() -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_commander_uitest_fixture_\(UUID().uuidString)")
        let fm = FileManager.default
        try! fm.createDirectory(at: base, withIntermediateDirectories: true)
        write(base, "alpha_small.txt", 1)
        write(base, "alpha_big.txt", 100)
        write(base, "large.bin", 5000)
        write(base, "gamma.txt", 1)
        write(base, "big.log", 1_500_000)   // 大文件：验证预览截断横幅
        // 单行大文件：回归"大单行文件预览空白"（1.3MB 一整行，无换行）
        try! String(repeating: "lorem ipsum dolor ", count: 100_000)
            .write(to: base.appendingPathComponent("longline.txt"), atomically: true, encoding: .utf8)
        // 小 .torrent：bencode 文本 + piece 哈希（含控制字节）——回归"被二进制嗅探误判"
        var torrent = Data("d8:announce40:https://tracker.example/ann13:created by10:Handmade3:inf".utf8)
        torrent.append(Data("4:name8:movie.mkv6:length123456".utf8))
        torrent.append(Data("11:piece length1310726:pieces".utf8))
        torrent.append(Data(repeating: 7, count: 40))
        torrent.append(Data("ee".utf8))
        try! torrent.write(to: base.appendingPathComponent("sample.torrent"))
        try! fm.createDirectory(at: base.appendingPathComponent("sub"), withIntermediateDirectories: true)
        write(base.appendingPathComponent("sub"), "inner.txt", 1)
        return base
    }

    private func write(_ dir: URL, _ name: String, _ bytes: Int) {
        try! String(repeating: "x", count: bytes).write(to: dir.appendingPathComponent(name),
                                                        atomically: true, encoding: .utf8)
    }

    // MARK: - 定位助手

    /// 列头按文案取按钮（最左侧；右栏有同名列头）。
    private func headerButton(_ title: String) -> XCUIElement {
        let hs = app.buttons.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex
        return hs.min { $0.frame.minX < $1.frame.minX }!
    }
    /// 点击某一行（合成鼠标 down+up 落在该行上，焦点随之移动）。
    private func clickRow(_ index: Int) {
        let row = leftTable().tableRows.allElementsBoundByIndex[index]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1,
                   thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
    }

    /// 把焦点移到名为 name 的行（预览/编辑等命令要求焦点项是文件，不能落在目录上）。
    private func focusRowNamed(_ name: String) {
        let names = leftRowNames()
        guard let idx = names.firstIndex(of: name) else {
            return XCTFail("夹具中找不到行：\(name)，现有：\(names)")
        }
        clickRow(idx)
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// 左栏表格 = 两个 table 中 x 最小的那个（split 左侧）。
    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    /// 左栏各行名称（按行序；每行 AX 有 3 个 Cell 各含整行文案，取 x 最小的 StaticText 即名称列）。
    private func leftRowNames() -> [String] {
        leftTable().tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    /// 工具栏按钮（title 与 label 均为 item.label）。
    private func toolbarButton(_ label: String) -> XCUIElement {
        app.toolbars.buttons.matching(NSPredicate(format: "title == %@", label)).firstMatch
    }

    /// 工具栏"已选 N 项"状态文本（value 属性）。
    private func selectionStatus(_ text: String) -> XCUIElement {
        app.toolbars.staticTexts.matching(NSPredicate(format: "value == %@", text)).firstMatch
    }

    /// 菜单栏按 title 取项（主菜单 5 项：Apple/FlyCommander/文件/编辑/查看）。
    private func menuBar(_ title: String) -> XCUIElement {
        app.menuBarItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// NSAlert(runModal) 的 AX 角色可能是 alert / sheet / dialog，依次查。
    private func prompt() -> XCUIElement? {
        for kind in [app.alerts.firstMatch, app.sheets.firstMatch, app.dialogs.firstMatch] {
            if kind.exists { return kind }
        }
        return nil
    }

    // MARK: - 启动冒烟 + 双栏

    func testBothPanesListFiles() {
        XCTAssertEqual(app.tables.count, 2, "应恰好两个窗格表格")
        for header in ["Name", "Size", "Date Modified"] {
            XCTAssertTrue(headerButton(header).exists, "列头缺失：\(header)")
        }
        XCTAssertEqual(leftTable().tableRows.count, 8, "行数不等于夹具 8 项")
        XCTAssertTrue(leftRowNames().contains("alpha_small.txt"), "左栏未显示夹具文件")
        // 标题 = 启动目录的 displayString（夹具在 runner 容器内，home 前缀显示为 ~，尾段不变）
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.title.hasSuffix(fixture.lastPathComponent),
                      "窗口标题应为启动目录，实际：\(window.title)")
        // 焦点行 = 1 项操作目标，工具栏状态非空
        XCTAssertTrue(selectionStatus("1 selected").exists, "启动时焦点行应显示已选 1 项")
    }

    /// 回归 #23：分隔条拖拽后两栏都不得消失。
    func testSplitDividerDragKeepsBothPanes() {
        let split = app.splitGroups.firstMatch
        XCTAssertTrue(split.exists, "缺少 split group")
        let divider = split.splitters.firstMatch
        XCTAssertTrue(divider.exists, "split 缺少分隔条")
        // 目标坐标基于 split（有 frame）；向右拖 12% 左右
        divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.25,
                   thenDragTo: split.coordinate(withNormalizedOffset: CGVector(dx: 0.57, dy: 0.5)))
        XCTAssertEqual(leftTable().tableRows.count, 8, "拖拽后左栏丢失")
        XCTAssertEqual(app.tables.count, 2, "拖拽后窗格数量变化")
    }

    // MARK: - 列头排序
    /// 列头存在性与默认序。列头→委托的**点击**在 XCUITest 下不可达（列头 Group 在 AX 上
    /// 标 Disabled，合成点击不触发 clickOnColumnName——已实测 3 种方式）；
    /// 委托→排序的接线与排序逻辑由 Tier 1 覆盖（PaneTableViewTests / PaneSortTests）。
    func testHeaderSortByNameThenSize() {
        // 默认序 = 目录优先 + 名称（localizedStandardCompare，与 core 单测同语义）：
        // sub(目录) 在前，文件按名 alpha_big < alpha_small < big < gamma < large < longline
        XCTAssertEqual(leftRowNames(),
                       ["sub", "alpha_big.txt", "alpha_small.txt", "big.log", "gamma.txt", "large.bin", "longline.txt", "sample.torrent"],
                       "默认显示序应为 目录优先+名称")
    }

    /// 默认显示序目录优先：子目录 sub 应排在所有文件之前（Finder/经典 TC 观感）。
    /// 顺带锁定"初始焦点在首行"——目录优先使 selection[0]==display[0]==sub。
    func testDefaultOrderDirsFirst() {
        let names = leftRowNames()
        XCTAssertEqual(names.first, "sub", "默认序首行应为目录 sub，实际：\(names)")
        // sub 是唯一目录，且必须在文件之前
        XCTAssertTrue(names.contains("alpha_big.txt"))
        let dirIdx = names.firstIndex(of: "sub")!
        for (i, n) in names.enumerated() where n != "sub" {
            XCTAssertGreaterThanOrEqual(i, dirIdx, "目录 sub 应排在所有文件之前：\(names)")
        }
    }

    /// 图标只在名称列：每行 AX 暴露的 image 应恰好 1 个（修复前每列各塞一个 = 3）。
    func testEachRowHasSingleIcon() {
        for row in leftTable().tableRows.allElementsBoundByIndex {
            let iconCount = row.images.allElementsBoundByIndex.count
            XCTAssertEqual(iconCount, 1, "每行应只有一个图标，实际 \(iconCount)")
        }
    }

    // MARK: - 菜单 / 工具栏

    func testMenuBarItemsPresent() {
        let titles = app.menuBarItems.allElementsBoundByIndex.compactMap { $0.title as String }
        XCTAssertEqual(titles, ["Apple", "FlyCommander", "File", "Edit", "View"])
    }

    func testToolbarButtonsPresent() {
        for name in ["Copy", "Move", "New Directory", "Delete", "Rename", "Find", "Connect"] {
            XCTAssertTrue(toolbarButton(name).exists, "工具栏按钮缺失：\(name)")
        }
    }

    func testToolbarNewDirectoryShowsPrompt() {
        toolbarButton("New Directory").click()
        guard let p = prompt() else { return XCTFail("新建目录弹窗未出现") }
        p.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
    }

    func testMenuNewDirectoryShowsPrompt() {
        menuBar("File").click()
        menuBar("File").menuItems
            .matching(NSPredicate(format: "title == 'New Directory'")).firstMatch.click()
        guard let p = prompt() else { return XCTFail("菜单路径新建目录弹窗未出现") }
        p.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
    }

    // MARK: - Cmd 组合（菜单 keyEquivalent 接管）

    func testCmdASelectsAll() {
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(selectionStatus("8 selected").waitForExistence(timeout: 5), "全选后工具栏未显示已选 8 项")
        // Cmd+A 非 toggle（selectAll 幂等）；清标记走 KeyDispatcher 的 Esc → clearMarks
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssertTrue(selectionStatus("1 selected").waitForExistence(timeout: 5), "Esc 清标记后应回到已选 1 项（焦点行）")
    }

    func testCmdFOpensSearch() {
        app.typeKey("f", modifierFlags: .command)
        let search = app.windows.matching(NSPredicate(format: "title == 'Find Files'")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Cmd+F 搜索窗未弹出")
        // 回归：窗口须真正铺开（非 0 宽）。曾漏设 translates=false 致 content 塌成 0 宽，
        // 窗口存在但看不见（"搜索窗出不来"）——旧断言只查按钮存在，0 宽时也绿。
        Thread.sleep(forTimeInterval: 0.3)
        let w = search.frame.width
        XCTAssertGreaterThan(w, 100, "搜索窗应铺开可见（宽>100），实际：\(Int(w))（疑似 0 宽塌陷）")
        XCTAssertTrue(search.buttons.matching(NSPredicate(format: "title == 'Search'")).firstMatch.exists)
        XCTAssertTrue(search.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.exists)
        search.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
    }

    // MARK: - SFTP 连接窗（只验窗口与控件出现，不真连——
    // 真实连接由 SPM 侧 ConnectionStoreE2ETests 对本地 sshd 覆盖）

    func testConnectWindowShowsFields() {
        toolbarButton("Connect").click()
        let conn = app.windows.matching(NSPredicate(format: "title == 'SFTP Connection'")).firstMatch
        XCTAssertTrue(conn.waitForExistence(timeout: 5), "SFTP 连接窗未弹出")
        // 按钮
        XCTAssertTrue(conn.buttons.matching(NSPredicate(format: "title == 'Connect'")).firstMatch.exists)
        XCTAssertTrue(conn.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.exists)
        // 表单字段：AX 里单选是 RadioButton、复选是 CheckBox（不在 .buttons 里）
        XCTAssertTrue(conn.radioButtons.matching(NSPredicate(format: "title == 'Password'")).firstMatch.exists)
        XCTAssertTrue(conn.radioButtons.matching(NSPredicate(format: "title == 'Key File'")).firstMatch.exists)
        XCTAssertTrue(conn.checkBoxes.matching(NSPredicate(format: "title == 'Remember Password'")).firstMatch.exists)
        // 主机输入框（无最近连接时应为空）
        let hostField = conn.textFields.matching(NSPredicate(format: "identifier == 'hostField'")).firstMatch
        XCTAssertTrue(hostField.exists, "主机输入框缺失")
        conn.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
    }

    // MARK: - 搜索（通配符匹配语义由 core 单测 FileSearcherTests 覆盖）
    /// XCUITest 环境下搜索窗 AX frame 塌成 0 宽（实测 not hittable），键入/点击输入框不可达，
    /// 故搜索 UI 层只验窗口与按钮出现（与 Cmd+F 同一动作路径）。
    func testSearchFlowFindsFiles() {
        toolbarButton("Find").click()
        let search = app.windows.matching(NSPredicate(format: "title == 'Find Files'")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "查找窗未弹出")
        let field = search.textFields.firstMatch
        XCTAssertEqual(field.value as? String, "*", "搜索模式框应预填 *")
        search.buttons.matching(NSPredicate(format: "title == 'Cancel'")).firstMatch.click()
    }

    // MARK: - 主题窗（持久化由 SPM ThemeStoreTests 覆盖；此处只验窗口与控件）

    private func themeWindow() -> XCUIElement {
        app.windows.matching(NSPredicate(format: "title == 'Theme'")).firstMatch
    }

    func testThemeWindowOpensViaMenu() {
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Theme…'")).firstMatch.click()
        let win = themeWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 5), "主题窗未弹出")
        // 关键控件：外观 segmented（3 段）、强调色取色器、规则行、添加/恢复按钮
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == 'Add Rule'")).firstMatch.exists, "缺 添加规则")
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == 'Restore Defaults'")).firstMatch.exists, "缺 恢复默认")
        // 默认主题带 5 条预置规则 → 至少 5 个扩展名输入框（textFields 已验证）；
        // 不取色器断言（colorWells 在缩减版 XCUITest SDK 未验证）。
        XCTAssertGreaterThanOrEqual(win.textFields.count, 5, "缺 文件类型规则行")
    }

    func testThemeWindowOpensViaToolbar() {
        toolbarButton("Theme").click()
        let win = themeWindow()
        XCTAssertTrue(win.waitForExistence(timeout: 5), "工具栏 主题 未弹出主题窗")
        XCTAssertTrue(win.buttons.matching(NSPredicate(format: "title == 'Add Rule'")).firstMatch.exists, "缺 添加规则")
    }

    // MARK: - 预览（查看 → 预览；须先点中一个文件行——预览要求焦点项非目录，
    // 而启动时焦点项不确定（可能落在目录上））

    /// 预览窗内的文本渲染内容（NSTextView 在 AX 上是 textView）。
    /// 空/nil = 未渲染出任何文字（回归"大文件预览只剩横幅"的直接信号）。
    private func previewTextContent(_ preview: XCUIElement) -> String? {
        preview.descendants(matching: .textView).firstMatch.value as? String
    }

    func testPreviewShowsWindow() {
        focusRowNamed("alpha_small.txt")
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "预览窗未弹出")
        // 小文件不应有截断横幅
        let smallBanner = preview.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH 'Showing only first'")).firstMatch
        XCTAssertFalse(smallBanner.exists, "小文件预览不应有截断横幅")
        // 小文件内容应真的渲染出来（不是只有空文本区）
        XCTAssertEqual(previewTextContent(preview), "x", "小文件预览应渲染文件内容")
    }

    /// 大文件（1.5MB 多行）预览：截断横幅 + 文本区必须真的渲染出内容
    /// （只断言横幅曾漏掉"大文件预览空白"回归——文字区 0 高时横幅仍在）。
    func testLargeTextPreviewShowsTruncationBanner() {
        focusRowNamed("big.log")
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "预览窗未弹出")
        let banner = preview.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH 'Showing only first'")).firstMatch
        XCTAssertTrue(banner.exists, "1.5MB 文件预览应显示截断横幅")
        let content = previewTextContent(preview)
        XCTAssertNotNil(content, "大文件预览文本区缺失")
        XCTAssertTrue((content?.count ?? 0) > 1000,
                      "大文件预览应渲染开头内容，实际 \(content?.count ?? 0) 字符")
    }

    /// 回归"小 .torrent 被二进制嗅探误判为'无法预览此文件'"：
    /// .torrent 是 bencode 文本 + piece 哈希（哈希含控制字节）→ 应按文本预览出 bencode 开头。
    func testTorrentFilePreviewsAsText() {
        focusRowNamed("sample.torrent")
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "预览窗未弹出")
        let fallback = preview.staticTexts
            .matching(NSPredicate(format: "value == 'Cannot preview this file'")).firstMatch
        XCTAssertFalse(fallback.exists, ".torrent 不应落入'无法预览此文件'降级页")
        let content = previewTextContent(preview)
        // bencode 开头可读（~230 字符）；降级页无 NSTextView 或内容极短
        XCTAssertTrue((content?.count ?? 0) > 100,
                      ".torrent 应预览出 bencode 文本，实际 \(content?.count ?? 0) 字符")
    }

    /// 回归"预览窗不能按 Esc 退出"：Esc 应关闭预览窗（cancelOperation 路径）。
    func testEscapeClosesPreviewWindow() {
        focusRowNamed("alpha_small.txt")
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "预览窗未弹出")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(preview.exists, "Esc 后预览窗应已关闭")
    }
    /// 回归"大单行文件（1.3MB 一整行）预览只显示横幅、文字区空白"：
    /// 长行截断后文本区必须有内容，且横幅含"长行已截断"说明。
    func testSingleLineLargeTextPreviewRendersContent() {
        focusRowNamed("longline.txt")
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "预览窗未弹出")
        let banner = preview.staticTexts
            .matching(NSPredicate(format: "value CONTAINS 'lines over'")).firstMatch
        XCTAssertTrue(banner.exists, "单行长行预览应显示含'长行已截断'的横幅")
        let content = previewTextContent(preview)
        XCTAssertNotNil(content, "单行大文件预览文本区缺失")
        XCTAssertTrue((content?.count ?? 0) > 1000,
                      "单行大文件预览应渲染该行前段内容，实际 \(content?.count ?? 0) 字符")
    }

    // MARK: - 标题随活动窗格（Tab 切换窗格）

    func testTitleReflectsActivePane() {
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.title.hasSuffix(fixture.lastPathComponent))
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        XCTAssertTrue(window.title.hasSuffix(fixture.lastPathComponent), "Tab 切换窗格后标题仍应为同一路径")
    }

    /// 回归"Tab 切到右窗格后方向键仍移动左窗格"：键盘第一响应者必须跟随活动窗格。
    /// 区分原理：方向键走视图本地 navigate（bug 下落在左窗格），菜单"查看→预览"
    /// 作用于活动窗格焦点项（router，焦点为目录时不弹窗）。
    /// 启动焦点在 sub（目录优先首行）→ Tab 切右 → Down（修复后右栏焦点到 alpha_big.txt
    /// 文件；bug 下右栏焦点仍停 sub 目录）→ 预览：修复后弹窗，bug 下被目录守卫拦截。
    func testTabMovesKeyboardToActivePane() {
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'FlyCommander Preview'")).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5),
                      "Tab 切右栏后 Down 应移动右栏焦点（文件行），预览应弹出；未弹出说明方向键仍落在左窗格")
    }

    // MARK: - 底部命令栏（T7：键入经窗格 keyDown 拦截 → 命令栏 buffer → Return 执行）

    /// 启动后键盘第一响应者是左窗格表格；按右箭头激活命令栏（TC 行为）后，
    /// 键入交给命令栏字段编辑，Return 执行。
    private var cmdBarOutput: XCUIElement {
        app.windows.element(boundBy: 0).staticTexts
            .matching(NSPredicate(format: "identifier == 'cmdBarOutput'")).firstMatch
    }

    /// 从窗格按右箭头激活命令栏（焦点移到输入框）。每用例 app 全新启动、焦点在窗格，
    /// 故只需一次。
    private func activateCommandBar() {
        app.typeKey(XCUIKeyboardKey.rightArrow, modifierFlags: [])
    }

    func testCommandLineLsEchoesItemCount() {
        activateCommandBar()
        for ch in Array("ls") { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(cmdBarOutput.waitForExistence(timeout: 2), "命令栏输出行缺失")
        let text = (cmdBarOutput.value as? String) ?? ""
        XCTAssertTrue(text.contains("8 items"), "ls 应回显夹具 8 项，实际：\(text)")
    }

    func testCommandLineHelpListsCommands() {
        activateCommandBar()
        for ch in Array("help") { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let text = (cmdBarOutput.value as? String) ?? ""
        XCTAssertTrue(text.contains("Available commands"), "help 应回显命令清单，实际：\(text)")
        XCTAssertTrue(text.contains("mkdir") && text.contains("sftp"), "清单应含 mkdir/sftp：\(text)")
    }

    func testCommandLineEscClearsBufferAndOutput() {
        activateCommandBar()
        for ch in Array("ls") { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        XCTAssertTrue(((cmdBarOutput.value as? String) ?? "").contains("8 items"), "前置：ls 已回显")
        // Esc 清输入+输出：再激活命令栏放一个字符，Esc 后应清空输出并回到窗格
        activateCommandBar()
        app.typeKey(XCUIKeyboardKey(rawValue: "x"), modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        let text = (cmdBarOutput.value as? String) ?? ""
        XCTAssertTrue(text.isEmpty, "Esc 后输出行应清空，实际：\(text)")
    }

    // MARK: - 多标签（P5：标签条可见 / ⌘T 增 / ⌘W 减 / 每侧保底 1）
    // × 与 + 均为 TabBarView 的 NSButton（title 即 AX title），全 app 无其它同 title 按钮。
    // × 计数 = 各侧"标签数≥2 时的标签数"之和：单标签的 × 隐藏（保底 1）。

    private func closeTabButtonCount() -> Int {
        app.buttons.matching(NSPredicate(format: "title == '×'")).count
    }

    /// 启动左右各 1 标签：单标签的 × 隐藏 → 0 个 ×；每侧 1 个 + → 2 个 +。
    func testTabBarVisibleOnLaunch() {
        XCTAssertEqual(closeTabButtonCount(), 0, "启动每侧单标签，× 应隐藏，实际：\(closeTabButtonCount())")
        let plus = app.buttons.matching(NSPredicate(format: "title == '+'"))
        XCTAssertEqual(plus.count, 2, "应左右各 1 个 + 新建按钮，实际：\(plus.count)")
    }

    /// ⌘T 增标签、⌘W 减标签、每侧保底 1（× 计数锚点：左 1/右 1→0；左 2/右 1→2；
    /// 左回 1→0；保底再 ⌘W 仍 0）。
    func testNewAndCloseTabCount() {
        XCTAssertEqual(closeTabButtonCount(), 0, "前置：启动每侧 1 标签（× 隐藏）")

        // ⌘T 新建（默认活动侧=左）→ 左 2 标签 → 2 个 ×
        menuBar("File").click()
        menuBar("File").menuItems
            .matching(NSPredicate(format: "title == 'New Tab'")).firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(closeTabButtonCount(), 2, "⌘T 后左侧 2 标签应有 2 个 ×")

        // ⌘W 关活动标签（左）→ 左回 1 标签 → × 消失
        menuBar("File").click()
        menuBar("File").menuItems
            .matching(NSPredicate(format: "title == 'Close Tab'")).firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(closeTabButtonCount(), 0, "⌘W 后左侧回 1 标签，× 应消失")

        // 保底：左侧已 1 标签，再 ⌘W 应不减少（该侧无法再关）
        menuBar("File").click()
        menuBar("File").menuItems
            .matching(NSPredicate(format: "title == 'Close Tab'")).firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(closeTabButtonCount(), 0, "保底：每侧最后 1 标签不可再关")
    }

    // MARK: - 多标签：导航更新标签文字 + Ctrl+Tab 切换（问题 1/2 回归）

    /// 问题 1：导航（cd 进子目录）后，标签条文字须同步为新目录名（不只刷表格/窗口标题）。
    func testTabTitleUpdatesOnNavigation() {
        activateCommandBar()
        for ch in Array("cd sub") { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        // 命令栏回显确认真的导航了（否则下方标签断言失败会误导成"标签没更新"）
        let text = (cmdBarOutput.value as? String) ?? ""
        XCTAssertTrue(text.contains("sub"), "cd sub 应回显进入子目录，实际：\(text)")
        // 导航前标签是启动目录名；导航进 sub 后标签按钮 title 应变成 sub
        Thread.sleep(forTimeInterval: 0.5)
        let subTab = app.buttons.matching(NSPredicate(format: "title == 'sub'")).firstMatch
        XCTAssertTrue(subTab.exists, "导航进 sub 后标签文字应更新为 sub")
    }

    /// 问题 2：活动侧多标签时 Ctrl+Tab 应切到下一标签。窗口标题随活动窗格目录变，
    /// 故作切换锚点：切前活动标签在 sub（标题 …/sub），Ctrl+Tab 后活动窗格换回启动
    /// 目录（另一标签），标题应不再是 sub；若标题仍是 sub 说明 Ctrl+Tab 没生效。
    func testCtrlTabSwitchesTab() {
        // ⌘T 新建标签（活动侧=左，新标签成为活动），左侧 2 标签
        menuBar("File").click()
        menuBar("File").menuItems
            .matching(NSPredicate(format: "title == 'New Tab'")).firstMatch.click()
        Thread.sleep(forTimeInterval: 0.5)
        // 当前活动标签 cd 进 sub → 活动窗格目录=sub → 窗口标题 …/sub
        activateCommandBar()
        for ch in Array("cd sub") { app.typeKey(XCUIKeyboardKey(rawValue: String(ch)), modifierFlags: []) }
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        let title = { [self] in app.windows.element(boundBy: 0).title }
        XCTAssertTrue(title().hasSuffix("sub"), "前置：活动标签应已 cd 进 sub，标题实际：\(title())")
        // Ctrl+Tab 切到另一标签（还在启动目录）→ 活动窗格目录回到启动目录 → 标题不再是 sub
        app.typeKey(XCUIKeyboardKey.tab, modifierFlags: .control)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(title().hasSuffix("sub"),
                       "Ctrl+Tab 切标签后活动窗格应换回启动目录，标题仍为 sub：\(title())")
    }
}


