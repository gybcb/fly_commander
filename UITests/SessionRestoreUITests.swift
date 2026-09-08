import XCTest
import Carbon

/// Tier 2 UI 回归：会话恢复（记住上次打开的左右目录 + 活动侧）。
///
/// 零污染注入口 `FLY_SESSION_JSON`：app 以该快照启动（左右窗格落在指定目录、活动侧按
/// `active`），**并关闭记录**（不写 UserDefaults）——本类用例因此不会污染开发者的真实偏好。
/// 另据契约：`--start-dir` / `FLY_START_DIR` 存在时既不恢复也不记录，故第二个用例用
/// FLY_START_DIR 与 FLY_SESSION_JSON 同时给，验证「显式启动目录压过记忆」。
///
/// 夹具：三个互相独立的目录 A/B/C，各放一个唯一命名的小文本文件（内容可读，供预览断言）。
/// 右栏 B 额外放一个空子目录 `bsub`——默认序目录优先，启动焦点落在它上面，
/// 按一次 ↓ 才落到文本文件，使「↓ 是否真的作用在活动（右）窗格」可被预览窗口证伪。
final class SessionRestoreUITests: XCTestCase {
    var app: XCUIApplication!
    /// 夹具根：内含 dirA / dirB / dirC。
    var fixtureRoot: URL!
    var dirA: URL!
    var dirB: URL!
    var dirC: URL!

    /// 夹具里的唯一文件名 / 目录名（断言与建盘共用常量，避免拼写漂移）。
    private let leftFile = "leftonly.txt"
    private let rightFile = "rightonly.txt"
    private let explicitFile = "conly.txt"
    private let rightSubdir = "bsub"

    // MARK: - 夹具 / 生命周期

    override func setUpWithError() throws {
        continueAfterFailure = false
        switchToEnglishInputSource()   // 键入类断言须英文输入法（与 FlyCommanderUITests 同因）
        makeFixture()
        app = XCUIApplication()
        app.terminate()   // 清掉上一用例可能残留的进程
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let fixtureRoot { try? FileManager.default.removeItem(at: fixtureRoot) }
    }

    /// 把输入源切到英文 ABC（若可用）。中文输入法激活时 XCUITest 的 typeKey 字母会进
    /// IME 组合层、提交不出预期 ASCII。只影响 UI 测试会话，不动 app 代码。
    /// （与 FlyCommanderUITests 里的同款私有方法各自持有——XCUITest 类之间不共享 helper。）
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

    /// A：仅 leftFile；B：空子目录 bsub + 唯一文本文件 rightFile；C：仅 explicitFile。
    private func makeFixture() {
        let fm = FileManager.default
        fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_uitest_session_\(UUID().uuidString)")
        dirA = fixtureRoot.appendingPathComponent("sessionA_\(UUID().uuidString.prefix(8))")
        dirB = fixtureRoot.appendingPathComponent("sessionB_\(UUID().uuidString.prefix(8))")
        dirC = fixtureRoot.appendingPathComponent("sessionC_\(UUID().uuidString.prefix(8))")
        for dir in [dirA!, dirB!, dirC!] {
            try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try! fm.createDirectory(at: dirB.appendingPathComponent(rightSubdir),
                                withIntermediateDirectories: true)
        write(dirA, leftFile, "left pane session fixture marker")
        write(dirB, rightFile, "right pane session fixture marker")
        write(dirC, explicitFile, "explicit start dir fixture marker")
    }

    private func write(_ dir: URL, _ name: String, _ text: String) {
        try! text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 按契约结构拼快照 JSON 串（走 JSONSerialization，路径含特殊字符也不会拼坏）。
    private func sessionJSON(left: URL, right: URL, active: String) -> String {
        let obj: [String: Any] = [
            "version": 1,
            "leftPath": left.path,
            "rightPath": right.path,
            "active": active,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// 每次用例自定 launchEnvironment（快照 / 启动目录），launchArguments 恒为英文。
    private func launch(environment: [String: String]) {
        app.launchArguments = ["-appLanguage", "en"]
        app.launchEnvironment = environment
        app.launch()
        // 两个表格都出现才算列目录完成（boundBy:1 在只有一个表格时不存在，会继续轮询）。
        XCTAssertTrue(app.tables.element(boundBy: 1).waitForExistence(timeout: 20),
                      "主窗两个窗格表格未出现")
        Thread.sleep(forTimeInterval: 0.5)   // 等两侧列目录与窗口标题落定
    }

    // MARK: - 定位助手

    /// 左栏表格 = 两个 table 中 x 最小的那个（split 左侧）。
    private func leftTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }!
    }

    /// 右栏表格 = 两个 table 中 x 最大的那个（split 右侧）。
    private func rightTable() -> XCUIElement {
        app.tables.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }!
    }

    /// 某表格各行名称（按行序；每行 AX 有 3 个 Cell 各含整行文案，取 x 最小的 StaticText 即名称列）。
    private func rowNames(_ table: XCUIElement) -> [String] {
        table.tableRows.allElementsBoundByIndex.compactMap { row in
            row.staticTexts.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.value as? String
        }
    }

    /// 菜单栏按 title 取项（主菜单 5 项：Apple/FlyCommander/File/Edit/View）。
    private func menuBar(_ title: String) -> XCUIElement {
        app.menuBarItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
    }

    /// 预览窗内的文本渲染内容（NSTextView 在 AX 上是 textView）。
    private func previewTextContent(_ preview: XCUIElement) -> String? {
        preview.descendants(matching: .textView).firstMatch.value as? String
    }

    // MARK: - 用例

    /// 快照恢复：左右两窗格各自落在 A/B（不只是活动侧），活动侧 = 右；
    /// 并用「↓ → 查看→预览」证伪「活动侧只是 core 标记、键盘第一响应者仍在左窗格」。
    func testRestoresLastDirectoriesAndActiveSide() {
        let json = sessionJSON(left: dirA, right: dirB, active: "right")
        launch(environment: ["FLY_SESSION_JSON": json])

        // (a) 窗口标题 = 活动窗格路径（MainViewController.updateBars）→ 应为 B。
        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.title.contains(dirB.lastPathComponent),
                      "窗口标题应为活动（右）窗格路径 B，实际：\(window.title)")

        // (b) 两侧目录都从快照恢复：左首行 = leftonly.txt，右表含 rightonly.txt。
        let leftNames = rowNames(leftTable())
        let rightNames = rowNames(rightTable())
        XCTAssertEqual(leftNames.first, leftFile,
                       "左窗格应从快照恢复 A 目录（首行 \(leftFile)），实际：\(leftNames)")
        XCTAssertTrue(rightNames.contains(rightFile),
                      "右窗格应从快照恢复 B 目录（含 \(rightFile)），实际：\(rightNames)")

        // (c) 第一响应者端到端证据：右栏焦点启动在目录 bsub 上，按一次 ↓ 应落到 rightFile；
        //     若方向键仍落在左窗格（修复前），右栏焦点停在目录 → 预览被目录守卫拦截，不弹窗。
        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        menuBar("View").click()
        menuBar("View").menuItems
            .matching(NSPredicate(format: "title == 'Preview'")).firstMatch.click()
        let preview = app.windows
            .matching(NSPredicate(format: "title CONTAINS %@", rightFile)).firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5),
                      "右栏按 ↓ 后预览应弹出并指向 \(rightFile)；未弹出说明方向键没作用在活动（右）窗格")
        // 预览内容确为 rightFile 的正文（小文件同步读，弹窗即可读）。
        XCTAssertEqual(previewTextContent(preview), "right pane session fixture marker",
                       "预览内容应为 \(rightFile) 的正文")
    }

    /// 显式启动目录压过记忆：同时给 FLY_START_DIR=C 与指向 A/B 的 FLY_SESSION_JSON，
    /// 两侧都应从 C 启动，且不得出现 A/B 的夹具文件。
    func testExplicitStartDirBeatsSavedSession() {
        let json = sessionJSON(left: dirA, right: dirB, active: "right")
        launch(environment: ["FLY_START_DIR": dirC.path, "FLY_SESSION_JSON": json])

        let window = app.windows.element(boundBy: 0)
        XCTAssertTrue(window.title.contains(dirC.lastPathComponent),
                      "窗口标题应为显式启动目录 C，实际：\(window.title)")

        for (label, table) in [("左", leftTable()), ("右", rightTable())] {
            let names = rowNames(table)
            XCTAssertTrue(names.contains(explicitFile),
                          "\(label)窗格应从 FLY_START_DIR=C 启动（含 \(explicitFile)），实际：\(names)")
            XCTAssertFalse(names.contains(leftFile) || names.contains(rightFile),
                           "\(label)窗格不应恢复快照目录 A/B，实际：\(names)")
        }
    }
}
