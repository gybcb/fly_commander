import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// 隐藏文件开关的 App 层接线回归（headless；范式同 FilterBarWiringTests #7/#9）。
/// 覆盖面：⌘⇧. 菜单项绑定、menuToggleHidden 全局传播+持久化、validateMenuItem ✓ 态、
/// wirePaneCallbacks 对新建 pane 的继承注入。
final class HiddenFilesWiringTests: XCTestCase {
    private var dir: URL!
    private var vc: MainViewController!
    private var defaultsKeyRestored: Bool?
    private var favSuiteName: String!
    private var favDefaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.current = .en
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hiddenwiring_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".dot"), atomically: true, encoding: .utf8)

        // 隔离真实 UserDefaults：记录原值，强制初始「隐藏」（false），tearDown 还原。
        defaultsKeyRestored = UserDefaults.standard.object(forKey: "showHiddenFiles") as? Bool
        UserDefaults.standard.set(false, forKey: "showHiddenFiles")

        let suiteName = "fly.test.hiddenwiring.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dir.path,
                                            rightPath: dir.path, active: "left"))
        // 收藏夹也走注入空 suite（FavoritesWiringTests 同款纪律）：默认参数是 .shared，
        // 本类目前虽不碰收藏，但不注入就是给未来用例留「写脏开发者真实偏好」的坑。
        favSuiteName = "fly.test.hiddenwiring.favorites.\(UUID().uuidString)"
        favDefaults = UserDefaults(suiteName: favSuiteName)!
        vc = MainViewController(sessionStore: store,
                                favoritesStore: DirectoryFavoritesStore(defaults: favDefaults))
        _ = vc.view   // loadView：两初生 pane 经 wirePaneCallbacks 继承开关
    }

    override func tearDown() {
        favDefaults.removePersistentDomain(forName: favSuiteName)
        if let v = defaultsKeyRestored {
            UserDefaults.standard.set(v, forKey: "showHiddenFiles")
        } else {
            UserDefaults.standard.removeObject(forKey: "showHiddenFiles")
        }
        L10n.current = .en
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    /// ⌘⇧. 菜单项存在且绑定正确（仿 ⌘⇧F 先例）。
    /// 变异：删菜单项 / 改错键或 selector → 本用例红。
    func testViewMenuHasToggleHiddenItemBoundToCommandShiftDot() {
        let menu = MainMenu.build(target: NSObject())
        let view = menu.items.first { $0.submenu?.title == L10n.t(.menuView) }?.submenu
        guard let item = view?.items.first(where: { $0.title == L10n.t(.toggleHiddenFiles) }) else {
            return XCTFail("查看菜单缺少「显示隐藏文件」项")
        }
        XCTAssertEqual(item.keyEquivalent, ".")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(item.action, #selector(MainViewController.menuToggleHidden(_:)))
    }

    /// 全局传播：一次切换 → 左右全部标签 pane 同步 + UserDefaults 持久化 + 状态栏回显。
    /// 变异：去掉遍历改只设 activePane → inactive 侧断言红；去掉 set(forKey:) →
    /// 持久化断言红；去掉 setStatus → 回显断言红。
    func testTogglePropagatesToAllPanesAndPersists() {
        let label = NSTextField(labelWithString: "")
        vc.attachStatusLabel(label)
        let allPanes = vc.workspace.leftTabs.panes + vc.workspace.rightTabs.panes
        XCTAssertFalse(allPanes.isEmpty)

        vc.menuToggleHidden(nil)   // false → true（显示）
        XCTAssertTrue(vc.workspace.leftTabs.activePane.showHidden)
        XCTAssertTrue(vc.workspace.rightTabs.activePane.showHidden)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "showHiddenFiles") as? Bool, true)
        XCTAssertEqual(label.stringValue, L10n.t(.hiddenFilesShown), "状态栏回显随语言")

        vc.menuToggleHidden(nil)   // true → false（隐藏）
        XCTAssertFalse(vc.workspace.leftTabs.activePane.showHidden)
        XCTAssertFalse(vc.workspace.rightTabs.activePane.showHidden)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "showHiddenFiles") as? Bool, false)
        XCTAssertEqual(label.stringValue, L10n.t(.hiddenFilesHidden))
    }

    /// 新建标签继承全局态（wirePaneCallbacks 唯一注入点回归：6 路 pane 创建共用）。
    /// 变异：删 wirePaneCallbacks 里的 `pane.showHidden = showHiddenFiles` →
    /// 新标签 showHidden 回内核缺省 true，本用例红。
    func testNewTabInheritsGlobalState() {
        vc.menuToggleHidden(nil)   // → 显示（true）
        vc.newTab()
        XCTAssertTrue(vc.workspace.activePane.showHidden, "新标签须继承「显示」")
        vc.menuToggleHidden(nil)   // → 隐藏（false）
        vc.newTab()
        XCTAssertFalse(vc.workspace.activePane.showHidden, "再切「隐藏」后新标签须继承")
        // 新标签是活动标签——若注入点被删，新 pane 恒为内核缺省 true，上一行即红。
        XCTAssertGreaterThan(vc.workspace.activeTab.count, 1, "前置：确实新建了标签")
    }

    /// 菜单 ✓ 态随全局开关翻转（validateMenuItem 在打开菜单时被系统调用）。
    /// 变异：validateMenuItem 的三元写反 → 两次断言全红；整个方法删掉 → 恒 .off 红。
    func testValidateMenuItemSyncsCheckmark() {
        let item = NSMenuItem(title: "", action: #selector(MainViewController.menuToggleHidden(_:)),
                              keyEquivalent: ".")
        vc.menuToggleHidden(nil)                     // 显示
        XCTAssertTrue(vc.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        vc.menuToggleHidden(nil)                     // 隐藏
        XCTAssertTrue(vc.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    /// 视图重投影回归（真窗 XCUITest 抓到的缺陷下沉 Tier-1）：menuToggleHidden 只设
    /// pane.showHidden（快路，不发 onReload）→ 表格须被显式 reload 才见 dotfile 增删。
    /// 夹具 a.txt + .dot：默认隐藏 → 左表 1 行；开后 → 2 行；再关 → 1 行。
    /// 变异：删 menuToggleHidden 末尾 allPaneViews.forEach{reload} → 行数停留旧值红。
    func testToggleReprojectsTableRows() {
        func leftRows() -> Int {
            let pv = findPaneView(in: vc.view, sideIsLeft: true)
            XCTAssertNotNil(pv, "前置：视图树应能找到窗格视图")
            return pv.map { $0.numberOfRows(in: $0.tableView!) } ?? -1
        }
        XCTAssertEqual(leftRows(), 1, "前置：默认隐藏 → 只剩 a.txt")
        vc.menuToggleHidden(nil)   // → 显示
        XCTAssertEqual(leftRows(), 2, "开后 .dot 须现身（表格须重投影）")
        vc.menuToggleHidden(nil)   // → 隐藏
        XCTAssertEqual(leftRows(), 1, "再关 .dot 须消失")
    }

    /// 视图树里按 x 最小者取左窗格视图（左右两份 PaneTableView，同 FilterBar 消歧法）。
    private func findPaneView(in root: NSView, sideIsLeft: Bool) -> PaneTableView? {
        func all(_ v: NSView) -> [PaneTableView] {
            var out: [PaneTableView] = []
            if let p = v as? PaneTableView { out.append(p) }
            for s in v.subviews { out += all(s) }
            return out
        }
        let pv = all(root)
        XCTAssertGreaterThanOrEqual(pv.count, 2, "前置：左右各一窗格视图")
        // 离屏未布局 frame 可能同为 0——回退按添加序（左容器先加）取。
        let positioned = pv.filter { $0.frame.width > 0 }
        guard positioned.count >= 2, let first = positioned.min(by: { $0.frame.minX < $1.frame.minX }) else {
            return sideIsLeft ? pv.first : pv.last
        }
        return first
    }
}
