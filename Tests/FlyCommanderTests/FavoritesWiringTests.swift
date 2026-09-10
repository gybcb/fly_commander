import XCTest
import AppKit
import TCCore
@testable import FlyCommander

/// 本地内存源桩（FavoritesWiringTests 独立桩——HiddenSource 在 TCCore 测试且 private）。
/// sourceID 可注入，供「同源自 navigate / 跨源换源 / 假远端断连提示」三分派用例。
private final class FavStubSource: FileSource {
    var sourceID: String
    var isRemote = false
    var dirs: [String: [FileItem]]
    init(sourceID: String, dirs: [String: [FileItem]] = [:]) {
        self.sourceID = sourceID; self.dirs = dirs
    }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirs[path.pathString] ?? [] }
    func isDirectory(_ path: TCPath) -> Bool { dirs[path.pathString] != nil }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at path: TCPath) throws {}
    func removeItem(at path: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

/// FavoritesMenu.build 纯构建回归（不弹窗，headless）。
/// 总变异锚：把 separator 条件改成恒真/恒假、toggle 标题三元写反、payload 丢 side，均红。
/// 缩减 SDK 无 NSView.rightClick/click——selector 只做值比对不真调用，本地探针即可。
private final class MenuProbe: NSObject {
    @objc func jump(_ sender: NSMenuItem) {}
    @objc func toggle(_ sender: NSMenuItem) {}
}

final class FavoritesMenuBuildTests: XCTestCase {
    private let probe = MenuProbe()
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    private let favA = DirectoryFavorite(sourceID: "local", path: "/a", displayName: "A")
    private let favB = DirectoryFavorite(sourceID: "local", path: "/b", displayName: "B")

    /// 空收藏：仅剩底部切换项（标题「收藏当前目录」、无 ✓、无快捷键）。
    /// 变异：删 `if !favorites.isEmpty` 守卫 → 多一条 separator 红；toggle 状态写死 .on 红；
    /// toggle 误挂 keyEquivalent → 末行红（切换项恒不编号，无数字键可达，靠鼠标点击）。
    func testEmptyFavoritesYieldsOnlyToggleItem() {
        let menu = FavoritesMenu.build(side: .left, isCurrentFavorited: false, favorites: [],
                                       target: probe,
                                       jumpAction: #selector(MenuProbe.jump(_:)),
                                       toggleAction: #selector(MenuProbe.toggle(_:)))
        XCTAssertEqual(menu.items.count, 1)
        XCTAssertEqual(menu.items[0].title, L10n.t(.addFavorite))
        XCTAssertEqual(menu.items[0].state, .off)
        XCTAssertEqual(menu.items[0].keyEquivalent, "", "切换项不得占用数字键")
        // 切换项无数字键、弹出也无默认高亮（spike 三路全灭）——靠鼠标点击到达。
        guard case let .toggleCurrent(side)? = (menu.items[0].representedObject as? PayloadHolder)?.payload else {
            return XCTFail("底部项须挂 toggleCurrent payload")
        }
        XCTAssertEqual(side, .left, "payload 须携带发起侧（非活动侧 🔽 跳自己侧）")
    }

    /// 非空：编号收藏项原序在前 → separator → 切换项标题翻「取消收藏」且带 ✓。
    /// 变异：remove/add 标题三元写反 → 两条 title 断言红；separator 漏加 → count 红；
    /// 编号 off-by-one（"0."/"1."）→ items[0].title 红。
    func testPopulatedMenuOrderSeparatorAndToggleFlip() {
        let menu = FavoritesMenu.build(side: .right, isCurrentFavorited: true,
                                       favorites: [favB, favA],   // store 序=新在前
                                       target: probe,
                                       jumpAction: #selector(MenuProbe.jump(_:)),
                                       toggleAction: #selector(MenuProbe.toggle(_:)))
        XCTAssertEqual(menu.items.count, 4, "1. B、2. A、separator、toggle")
        XCTAssertEqual(menu.items[0].title, "1. B", "编号=显示序（store 新在前）")
        XCTAssertEqual(menu.items[1].title, "2. A")
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertEqual(menu.items[3].title, L10n.t(.removeFavorite))
        XCTAssertEqual(menu.items[3].state, .on)

        // 跳转项 payload：收藏本体 + 发起侧。
        guard case let .jump(fav, side)? = (menu.items[0].representedObject as? PayloadHolder)?.payload else {
            return XCTFail("跳转项须挂 jump payload")
        }
        XCTAssertEqual(fav, favB)
        XCTAssertEqual(side, .right)

        // action 绑定：跳转项/切换项各走各的 selector，target 收口调用方。
        XCTAssertEqual(menu.items[0].action, #selector(MenuProbe.jump(_:)))
        XCTAssertEqual(menu.items[3].action, #selector(MenuProbe.toggle(_:)))
        for item in [menu.items[0], menu.items[3]] {
            XCTAssertTrue(item.target is MenuProbe)
            // autoenablesItems 旁路：target/action 齐全才不被系统禁用（禁用项 keyEquiv 不触发）。
            XCTAssertTrue(item.isEnabled)
        }
    }

    /// 数字编号与裸键快捷键结构锁：前 9 条 keyEquivalent="1"…"9" 且 **mask 显式清空**；
    /// 第 10 条起仅 `N. ` 前缀、无快捷键（store cap=20 超出 1~9 的部分）。
    /// 变异：忘清 keyEquivalentModifierMask（NSMenuItem 缺省 ⌘）→ mask 断言红；
    /// 编号界从 idx<9 改成 idx<12 → 第 10 条 keyEquivalent 非空红；标题漏前缀 → 首条红。
    func testNumberingAndBareKeyEquivalents() {
        let favs = (1...12).map {
            DirectoryFavorite(sourceID: "local", path: "/p\($0)", displayName: "P\($0)")
        }
        let menu = FavoritesMenu.build(side: .left, isCurrentFavorited: false, favorites: favs,
                                       target: probe,
                                       jumpAction: #selector(MenuProbe.jump(_:)),
                                       toggleAction: #selector(MenuProbe.toggle(_:)))
        for idx in 0..<9 {
            let item = menu.items[idx]
            XCTAssertEqual(item.title, "\(idx + 1). P\(idx + 1)")
            XCTAssertEqual(item.keyEquivalent, String(idx + 1), "前 9 条挂裸数字快捷键")
            XCTAssertEqual(item.keyEquivalentModifierMask, [], "mask 必须清空，否则做成 ⌘N")
        }
        for idx in 9..<12 {
            let item = menu.items[idx]
            XCTAssertEqual(item.title, "\(idx + 1). P\(idx + 1)", "10+ 仍显示序号")
            XCTAssertEqual(item.keyEquivalent, "", "10+ 无数字快捷键（1~9 之外无键可绑）")
        }
    }

    /// 语言切换：标题走 L10n.t——先取 en 串，切 zh 后构建再与 en 串比「必不同」，
    /// 且断 zh 串==zh 表值（同语言自比恒真无意义，跨语言差才是语言驱动的证据）。
    /// 变异：硬编码标题 → en 值断言红；不走 L10n.t → 跨语言差断言红。
    func testTitlesFollowLanguage() {
        func toggleTitle() -> String {
            let menu = FavoritesMenu.build(side: .left, isCurrentFavorited: false, favorites: [favA],
                                           target: probe,
                                           jumpAction: #selector(MenuProbe.jump(_:)),
                                           toggleAction: #selector(MenuProbe.toggle(_:)))
            return menu.items.last!.title
        }
        let en = toggleTitle()
        XCTAssertEqual(en, L10n.t(.addFavorite), "en 态=当前表值")
        L10n.current = .zh
        let zh = toggleTitle()
        XCTAssertEqual(zh, L10n.t(.addFavorite), "zh 态=当前表值")
        XCTAssertNotEqual(zh, en, "zh 文案须与 en 不同（语言驱动的证据）")
    }
}

/// 收藏 App 层接线回归（范式同 FilterBarWiringTests #7：SessionStore 注入 + `_ = vc.view`）。
/// 覆盖：favoritesButton 兄弟视图存活 + performClick、F2 钩子→弹活动侧下拉、
/// 切换项→store 往返+回显、jump 三分派中可 headless 的两分支（同源自 navigate / 跨源换源）+ 断连提示。
final class FavoritesWiringTests: XCTestCase {
    private var dirA: URL!, dirB: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var favStore: DirectoryFavoritesStore!
    private var vc: MainViewController!

    override func setUpWithError() throws {
        try super.setUpWithError()
        L10n.current = .en
        let fm = FileManager.default
        func mk(_ tag: String) throws -> URL {
            let u = fm.temporaryDirectory.appendingPathComponent("favwiring_\(tag)_\(UUID().uuidString)")
            try fm.createDirectory(at: u, withIntermediateDirectories: true)
            try "x".write(to: u.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
            return u
        }
        dirA = try mk("a"); dirB = try mk("b")

        suiteName = "fly.test.favorites.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        favStore = DirectoryFavoritesStore(defaults: defaults)

        let sessionSuiteName = "fly.test.favorites.session.\(UUID().uuidString)"
        let sessionSuite = UserDefaults(suiteName: sessionSuiteName)!
        defer { sessionSuite.removePersistentDomain(forName: sessionSuiteName) }
        let store = SessionStore(defaults: sessionSuite)
        // 右侧落 dirB：payload 侧辨别用例需要左右路径不同（同路径下 store 键无法区分侧）。
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dirA.path,
                                            rightPath: dirB.path, active: "left"))
        vc = MainViewController(sessionStore: store, favoritesStore: favStore)
        _ = vc.view   // loadView：wireFavorites 接 router.onOpenFavoritesMenu
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        L10n.current = .en
        try? FileManager.default.removeItem(at: dirA)
        try? FileManager.default.removeItem(at: dirB)
        vc = nil
        super.tearDown()
    }

    /// 视图树里按 AX id 找控件。
    private func findByAX(_ root: NSView, _ id: String) -> NSView? {
        if root.accessibilityIdentifier() == id { return root }
        for s in root.subviews { if let hit = findByAX(s, id) { return hit } }
        return nil
    }

    /// favoritesButton 是 bar 的兄弟视图（stack 外），rebuild 不销毁；performClick 触发 onFavorites。
    /// 变异：把 favoritesButton 塞进 stack → 第二次 findByAX 为 nil 红；
    /// 删 favoritesClicked 里的回调 → fired 0 红。
    func testFavoritesButtonSurvivesRebuildAndFiresCallback() {
        let bar = TabBarView()
        bar.rebuild(titles: ["a", "b"], activeIndex: 0, isActiveSide: true)
        guard let button = findByAX(bar, "paneFavoritesButton") as? NSButton else {
            return XCTFail("标签条缺少常驻收藏按钮")
        }
        XCTAssertTrue(button.superview === bar, "收藏按钮须是兄弟视图，不在 stack 里")

        bar.rebuild(titles: ["c"], activeIndex: 0, isActiveSide: false)
        guard let again = findByAX(bar, "paneFavoritesButton") as? NSButton else {
            return XCTFail("rebuild 后收藏按钮被销毁")
        }
        XCTAssertTrue(again.superview === bar)

        var fired = 0
        bar.onFavorites = { fired += 1 }
        again.performClick(nil)
        XCTAssertEqual(fired, 1, "点击应触发 onFavorites")
    }

    /// 每侧标签条真装上了 🔽（左右各一，走 loadView 真实搭建）。
    /// 变异：拆容器搭建/少接一侧 → 计数 ≠2 红。
    func testBothSidesHaveFavoritesButtonInVCViewTree() {
        _ = vc.view
        func bars(in root: NSView) -> [TabBarView] {
            if let bar = root as? TabBarView { return [bar] }
            return root.subviews.flatMap { bars(in: $0) }
        }
        let found = bars(in: vc.view)
        XCTAssertEqual(found.count, 2, "左右各一常驻标签条")
        for bar in found {
            XCTAssertNotNil(findByAX(bar, "paneFavoritesButton"), "每条标签条须有 🔽")
        }
    }

    /// F2 全链（语义已变更）：router.execute(.openFavoritesMenu) → onOpenFavoritesMenu →
    /// **弹活动侧下拉**（不再直切收藏）。经假呈现器捕获「弹了哪一侧 + 菜单结构对不对」，
    /// 并负向锁 store 未被改动（证明 F2 不再直接收藏）。
    /// 变异：wireFavorites 里左右容器对调 → presentedSide 红；改回直切 toggleFavorite →
    /// presented 仍 nil（呈现器没被调）红；菜单条目与 store 不符 → count 红。
    func testF2HookOpensFavoritesDropdownOnActiveSide() {
        // 先给 store 塞两条，使弹出的菜单可见证条目（顺序：新在前）。
        favStore.add(sourceID: "local", path: dirB.path, displayName: "B")
        favStore.add(sourceID: "local", path: dirA.path, displayName: "A")

        var presented: (side: PaneID, menu: NSMenu)?
        vc.favoritesMenuPresenter = { container, menu in
            presented = (container.side, menu)
        }

        // 活动侧 = 左（会话快照 active:"left"）。
        vc.router.execute(.openFavoritesMenu)
        XCTAssertEqual(presented?.side, .left, "F2 须弹活动侧（左）")
        // 菜单结构：2 收藏 + separator + toggle = 4 项，且首条为「1. A」（A 新在前）。
        XCTAssertEqual(presented?.menu.items.count, 4)
        XCTAssertEqual(presented?.menu.items.first?.title, "1. A")

        // 负向锁：F2 不写 store（旧行为会切换收藏态；现仅弹菜单）。
        XCTAssertEqual(Set(favStore.all.map { $0.path }), [dirA.path, dirB.path],
                       "F2 前后 store 不变")

        // 切到右侧后 F2 须弹右侧。
        presented = nil
        vc.workspace.switchActive()
        vc.router.execute(.openFavoritesMenu)
        XCTAssertEqual(presented?.side, .right, "切窗格后 F2 须弹新活动侧（右）")

        vc.favoritesMenuPresenter = nil   // 复位缺省呈现器
    }

    /// 菜单内切换项（收藏写入唯一入口）：favoriteToggleCurrentSelected → store 增→删往返 +
    /// 状态栏回显（原 testF2HookTogglesStoreWithStatusEcho 的 store/回显覆盖迁移至此）。
    /// 变异：toggleFavorite 两分支回显串写反 → 两条 status 断言红；add/remove 写反 → isFavorited 红。
    func testToggleItemRoundTripsStoreWithStatusEcho() {
        let label = NSTextField(labelWithString: "")
        vc.attachStatusLabel(label)
        // 活动侧=左（dirA），切换项 payload 带 .left → 切 dirA。
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = PayloadHolder(.toggleCurrent(side: .left))

        vc.favoriteToggleCurrentSelected(item)
        XCTAssertTrue(favStore.isFavorited(sourceID: "local", path: dirA.path))
        XCTAssertEqual(label.stringValue, L10n.t(.favoriteAdded))

        vc.favoriteToggleCurrentSelected(item)   // 再点 = 取消
        XCTAssertFalse(favStore.isFavorited(sourceID: "local", path: dirA.path))
        XCTAssertEqual(label.stringValue, L10n.t(.favoriteRemoved))
    }

    /// 收藏快照的显示名 = tabTitle 同款（与标签条一致，非裸路径）。
    /// 变异：displayName 改传 path.pathString → 末段名断言红（多段路径时）。
    func testToggleStoresTabTitleDisplayName() {
        let pane = vc.workspace.leftTabs.activePane
        vc.toggleFavorite(pane: pane)
        let fav = favStore.all.first
        XCTAssertEqual(fav?.displayName, SidePaneContainer.tabTitle(pane.path))
        XCTAssertEqual(fav?.displayName, dirA.lastPathComponent, "夹具在临时目录深层 → 名即末段")
    }

    /// jump 分派①：同 sourceID → navigate（本地同步路，path 立刻变）。
    /// 变异：同判定 `fav.sourceID == pane.source.sourceID` 删掉 → 走 local 分支也到同处？
    /// 不会——local 分支 setSource(andPath:) 重置选择器；这里改测 navigate 保留筛选侧证据不现实，
    /// 故变异锚为「同判定改成恒 false + local 分支删掉」→ 落到末行断连提示，path 不变红。
    func testJumpSameSourceNavigates() {
        let pane = vc.workspace.activePane
        XCTAssertEqual(pane.path.pathString, dirA.path, "前置：起始在 A")
        let fav = DirectoryFavorite(sourceID: "local", path: dirB.path, displayName: "B")
        vc.jump(to: fav, in: pane)
        XCTAssertEqual(pane.path.pathString, dirB.path)
        XCTAssertEqual(pane.source.sourceID, "local")
    }

    /// jump 分派②：跨源且收藏是本地 → setSource(LocalFileSource) 换源接路径。
    /// 变异：local 分支删掉 → 落到 favoritesNeedReconnect（stub id 非 sftp/smb），path 不变红。
    func testJumpLocalFavoriteFromForeignSourceSwitchesSource() {
        let stub = FavStubSource(sourceID: "stub://x", dirs: [:])
        let pane = vc.workspace.activePane
        pane.setSource(stub, andPath: TCPath("/nowhere"))
        let fav = DirectoryFavorite(sourceID: "local", path: dirB.path, displayName: "B")
        vc.jump(to: fav, in: pane)
        XCTAssertEqual(pane.source.sourceID, "local", "须换回本地源")
        XCTAssertEqual(pane.path.pathString, dirB.path)
    }

    /// jump 分派③：sftp/smb 收藏且连接表无活源（shared store 空/异 id）→ 状态栏断连提示，
    /// 窗格纹丝不动，也不弹连接窗（本用例即「不弹窗」的负向锁：弹窗会阻塞或留窗口）。
    /// 变异：删末行 setStatus → 回显空红；删 `let live = …` 守卫 → 走 setSource(nil!) 崩。
    func testJumpDisconnectedRemoteShowsHintAndStaysPut() {
        let label = NSTextField(labelWithString: "")
        vc.attachStatusLabel(label)
        let pane = vc.workspace.activePane
        let before = pane.path.pathString

        let sftpFav = DirectoryFavorite(sourceID: "sftp://unhost.test:22", path: "/srv", displayName: "r")
        vc.jump(to: sftpFav, in: pane)
        XCTAssertEqual(label.stringValue, L10n.t(.favoritesNeedReconnect))
        XCTAssertEqual(pane.path.pathString, before, "断连收藏不得改动窗格")

        let smbFav = DirectoryFavorite(sourceID: "smb://unhost.test/share", path: "/docs", displayName: "s")
        vc.jump(to: smbFav, in: pane)
        XCTAssertEqual(label.stringValue, L10n.t(.favoritesNeedReconnect))
        XCTAssertEqual(pane.path.pathString, before)
    }

    /// 下拉底部切换项动作 = **发起侧**活动窗格的 toggleFavorite（payload 携带侧还原）。
    /// 夹具左右异路径（左 dirA / 右 dirB）：用 .right payload 应切 dirB 而非活动侧 dirA。
    /// 变异：favoriteToggleCurrentSelected 忽略 payload 侧改取 workspace.active（活动=left）
    /// → dirA 入 store、dirB 不入，两条断言全红。
    func testToggleSelectorUsesPayloadSidePane() {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = PayloadHolder(.toggleCurrent(side: .right))
        vc.favoriteToggleCurrentSelected(item)
        XCTAssertTrue(favStore.isFavorited(sourceID: "local", path: dirB.path), "须切 right 侧（dirB）")
        XCTAssertFalse(favStore.isFavorited(sourceID: "local", path: dirA.path), "活动侧 left（dirA）不得被切")
    }

    /// 跳转选择器：payload 解包 → jump 到目标；非法 representedObject 静默忽略（防崩）。
    /// 变异：guard 改成 force-cast → 垃圾 sender 崩；jump 行删 → path 不变红。
    func testJumpSelectorUnwrapsPayloadAndIgnoresGarbage() {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.representedObject = PayloadHolder(.jump(
            DirectoryFavorite(sourceID: "local", path: dirB.path, displayName: "B"), side: .left))
        vc.favoriteJumpSelected(item)
        XCTAssertEqual(vc.workspace.leftTabs.activePane.path.pathString, dirB.path)

        let garbage = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        garbage.representedObject = "not a holder"
        vc.favoriteJumpSelected(garbage)   // 不崩即通过（path 仍 dirB）
        XCTAssertEqual(vc.workspace.leftTabs.activePane.path.pathString, dirB.path)
    }
}
