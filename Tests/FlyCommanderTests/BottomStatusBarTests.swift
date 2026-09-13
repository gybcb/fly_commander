import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// 底部状态栏 ↔ 命令栏同槽互换的接线回归（headless，范式同 HiddenFilesWiringTests）。
/// 锁的是：初始互换态、setCommandLineVisible 双向翻转与幂等、状态栏文案随
/// 焦点/标记刷新、多选门禁（marked 为空绝不显「已选」——去掉门禁本文件必须变红）、
/// 程序化子视图约束卫生（塌陷坑的结构守卫，FilterBarWiringTests 同款）。
final class BottomStatusBarTests: XCTestCase {
    private var dir: URL!
    private var vc: MainViewController!
    private var hiddenKeyRestored: Bool?
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        L10n.current = .en
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bottomstatus_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 三个有内容的文件（合计可断言）+ 一个子目录（statusLine 的「文件夹」分支）。
        try String(repeating: "a", count: 100).write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try String(repeating: "b", count: 200).write(
            to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "c".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)

        hiddenKeyRestored = UserDefaults.standard.object(forKey: "showHiddenFiles") as? Bool
        UserDefaults.standard.set(false, forKey: "showHiddenFiles")

        suiteName = "fly.test.bottomstatus.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let store = SessionStore(defaults: defaults)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dir.path,
                                            rightPath: dir.path, active: "left"))
        vc = MainViewController(sessionStore: store,
                                favoritesStore: DirectoryFavoritesStore(defaults: defaults))
        _ = vc.view   // loadView
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        if let v = hiddenKeyRestored {
            UserDefaults.standard.set(v, forKey: "showHiddenFiles")
        } else {
            UserDefaults.standard.removeObject(forKey: "showHiddenFiles")
        }
        L10n.current = .en
        try? FileManager.default.removeItem(at: dir)
    }

    /// 读左栏文案：loadView 建的视图层级里按 AX id 找（不依赖私有属性）。
    private func infoText() -> String {
        bottomStatusView()?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    private func bottomStatusView() -> BottomStatusBar? {
        func find(_ v: NSView) -> BottomStatusBar? {
            if let b = v as? BottomStatusBar { return b }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return find(vc.view)
    }

    private func commandBarView() -> CommandLineBar? {
        func find(_ v: NSView) -> CommandLineBar? {
            if let b = v as? CommandLineBar { return b }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return find(vc.view)
    }

    // MARK: - 初始互换态

    func testLaunchShowsStatusBarWithCommandLineHidden() {
        XCTAssertEqual(vc.isCommandLineVisible, false, "启动默认命令栏隐藏（用户定档）")
        XCTAssertEqual(commandBarView()?.isHidden, true, "commandBar 初始 isHidden")
        XCTAssertEqual(bottomStatusView()?.isHidden, false, "状态栏初始可见")
    }

    // MARK: - setCommandLineVisible 双向翻转 + 幂等

    func testSetCommandLineVisibleTogglesBothBars() {
        vc.setCommandLineVisible(true)
        XCTAssertEqual(vc.isCommandLineVisible, true)
        XCTAssertEqual(commandBarView()?.isHidden, false)
        XCTAssertEqual(bottomStatusView()?.isHidden, true)
        vc.setCommandLineVisible(false)
        XCTAssertEqual(vc.isCommandLineVisible, false)
        XCTAssertEqual(commandBarView()?.isHidden, true)
        XCTAssertEqual(bottomStatusView()?.isHidden, false)
        // 收回必须是 isHidden 互换而非移出层级：removeFromSuperview 会让
        // commandBar.activate 的 `guard let win = window` 静默失败（右箭头永久失效）。
        XCTAssertNotNil(commandBarView(), "收回后命令栏必须仍在视图层级里")
    }

    /// 幂等：重复同值调用不得产生副作用（重入守卫——收回时输入框随父隐藏会再触发
    /// resignFirstResponder 回调自指，就是靠这个守卫挡的）。
    func testSetCommandLineVisibleIsIdempotent() {
        vc.setCommandLineVisible(false)   // 与初始同值
        XCTAssertEqual(vc.isCommandLineVisible, false)
        vc.setCommandLineVisible(true)
        vc.setCommandLineVisible(true)
        XCTAssertEqual(commandBarView()?.isHidden, false, "二次 true 后仍可见")
    }

    // MARK: - 焦点行文案

    func testFocusLineShowsNameSizeDate() {
        let pane = vc.workspace.activePane
        XCTAssertFalse(pane.selection.items.isEmpty, "前置：左窗格已装载")
        // 移焦点到 0 时若焦点本就在 0 可能不发变更通知——标记再取消强制走一次
        // onSelectionChange → updateBars 刷新链。
        pane.moveFocus(to: 0, mode: .simple)
        pane.toggleMark(at: 0)
        pane.toggleMark(at: 0)
        let focused = pane.focusedItem?.name
        let text = infoText()
        XCTAssertTrue(text.contains(focused ?? "?"),
                      "焦点行应含焦点文件名 \(focused ?? "?")，实际：\(text)")
    }

    func testStatusLineDirectorySaysFolderNotBytes() {
        let item = FileItem(id: "d", path: TCPath(dir.path), name: "sub", isDirectory: true,
                            size: 4096, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                            isHidden: false, isReadOnly: false, isExecutable: false)
        let line = MainViewController.statusLine(item)
        XCTAssertTrue(line.contains("sub") && line.contains(L10n.t(.statusFolder)),
                      "目录行 = 名 + 文件夹 + 日期，实际：\(line)")
        XCTAssertFalse(line.contains("4.1 KB") || line.contains("4,096"),
                       "目录不得显示字节数（对齐大小列留空约定），实际：\(line)")
    }

    func testStatusLineFileHasSizeNotFolder() {
        let item = FileItem(id: "f", path: TCPath(dir.path), name: "a.txt", isDirectory: false,
                            size: 100, modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                            isHidden: false, isReadOnly: false, isExecutable: false)
        let line = MainViewController.statusLine(item)
        XCTAssertTrue(line.contains("a.txt"), "实际：\(line)")
        XCTAssertFalse(line.contains(L10n.t(.statusFolder)), "文件不显「文件夹」，实际：\(line)")
    }

    // MARK: - 多选门禁（本文件最有牙的一条：删掉 marked.isEmpty 门禁 → 纯焦点显「已选」→ 红）

    /// 有牙的一条：先标记（焦点仍在被标项上）→ clearMarks → 回到"纯焦点"态。
    /// 若去掉 updateBars 里的 `marked.isEmpty` 门禁，此刻 operationIDs 回退 [focusID]
    ///（SelectionModel.swift:43）会显「已选 1 项」→ 本用例红。
    func testPlainFocusNeverSaysSelected() {
        let pane = vc.workspace.activePane
        XCTAssertFalse(pane.selection.items.isEmpty, "前置：左窗格已装载")
        pane.moveFocus(to: 0, mode: .additive)   // 焦点 0 且标记 0
        XCTAssertFalse(pane.selection.marked.isEmpty, "前置：additive 应已标记焦点项")
        pane.clearMarks()
        XCTAssertTrue(pane.selection.marked.isEmpty, "前置：clearMarks 后无标记")
        let text = infoText()
        XCTAssertFalse(text.contains("selected") || text.contains("已选"),
                       "纯焦点态绝不得显「已选」（operationIDs 回退陷阱），实际：\(text)")
        XCTAssertTrue(text.contains("·"),
                      "纯焦点态应是 名·大小·日期 三段，实际：\(text)")
    }

    func testMarkingTwoItemsShowsCountAndTotal() {
        let pane = vc.workspace.activePane
        let items = pane.selection.items
        XCTAssertGreaterThanOrEqual(items.count, 3, "前置：至少 3 项")
        pane.toggleMark(at: 0)
        pane.toggleMark(at: 1)
        let text = infoText()
        XCTAssertTrue(text.contains("2 selected") || text.contains("已选 2 项"),
                      "标 2 项应显计数，实际：\(text)")
        XCTAssertTrue(text.contains("KB") || text.contains("bytes") || text.contains("字节"),
                      "应含合计大小，实际：\(text)")
    }

    // MARK: - 约束卫生（塌陷盲区结构守卫；FilterBarWiringTests 同款本地复制）

    func testBottomStatusBarUsesConstraints() {
        guard let bar = bottomStatusView() else {
            return XCTFail("视图层级里找不到 BottomStatusBar")
        }
        XCTAssertFalse(bar.translatesAutoresizingMaskIntoConstraints,
                       "BottomStatusBar 漏设 translatesAutoresizingMaskIntoConstraints = false")
        XCTAssertEqual(bar.frame.height, 0, "初始 frame 应为 0×0（靠约束定尺寸）")
    }
}
