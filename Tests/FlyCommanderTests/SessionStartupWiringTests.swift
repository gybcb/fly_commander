import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// T4：真实 loadView 接线冒烟 + 会话写回接线（headless AppKit，与 ResidentWindowRepaintTests 同法）。
/// 恢复决策 / isRestoring 护栏 / 第一响应者 / 导航写回若接线错，这里会崩或断言失败。
final class SessionStartupWiringTests: XCTestCase {
    private var suiteName: String!
    private var suite: UserDefaults!

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    override func setUp() {
        suiteName = "fly.test.session.wiring.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 启动恢复

    /// 有快照：左侧种子为 nil（上次是远端/从未记录）、右侧候选不存在 → 上溯。
    /// 恢复期**一个字节都不写回**（isRestoring 护栏）——否则左侧会被写成 ~ 展开的 home。
    func testLoadViewRestoresSnapshotWithoutWritingBack() {
        let missing = "/no-such-dir-\(UUID().uuidString)"
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: nil,
                                            rightPath: missing, active: "right"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view                       // 强制 loadView（恢复决策 + 初始 load）

        XCTAssertNil(store.snapshot?.leftPath,
                     "恢复期不得写回——否则 nil 会被写成 ~ 展开的 home")
        XCTAssertEqual(store.snapshot?.rightPath, missing,
                       "恢复期不得把上溯结果写回记忆")
        XCTAssertEqual(store.snapshot?.active, "right")
        XCTAssertNotNil(vc.initialKeyView, "活动侧为右时第一响应者仍须存在")
    }

    /// 无快照（首启）：建出视图，且初始 load 本身不写盘——首次记忆由用户首次操作触发。
    func testLoadViewWithoutSnapshotDoesNotWriteOnStartup() {
        let store = SessionStore(defaults: suite)
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        XCTAssertNotNil(vc.initialKeyView)
        XCTAssertNil(store.snapshot, "初始 load 属恢复期，不得写盘")
    }

    // MARK: - 写回接线

    /// 契约 7：导航（gotoParent）→ refresh 首条 → 写回该侧活动标签的新目录。
    func testNavigationWritesMemory() {
        let store = SessionStore(defaults: suite)
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        vc.workspace.leftTabs.activePane.gotoParent()
        XCTAssertEqual(store.snapshot?.leftPath, TCPath(home).parent!.pathString,
                       "导航后须写回父目录")
    }

    /// 第一响应者必须是**活动**侧窗格（恒取左窗格即红）。
    func testInitialKeyViewIsActiveSide() {
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: home,
                                            rightPath: home, active: "right"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        XCTAssertTrue(vc.initialKeyView === vc.viewOfPane(vc.workspace.rightTabs.activePane),
                      "活动侧为右时第一响应者应为右窗格视图")
    }

    /// 端到端：切换活动侧 → applyActiveState 末条记录。右侧候选不可用被上溯，用户未离开
    /// 上溯落点 → 写回的仍是**原候选**（degraded 一次性语义在真实链路上成立）。
    func testPaneSwitchRecordsAndPreservesDegradedCandidate() {
        let missing = "/no-such-dir-\(UUID().uuidString)"
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: home,
                                            rightPath: missing, active: "right"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        vc.menuSwitchPane(nil)            // 活动侧右→左，触发 applyActiveState → 记录

        XCTAssertEqual(store.snapshot?.active, "left")
        XCTAssertEqual(store.snapshot?.leftPath, home)
        XCTAssertEqual(store.snapshot?.rightPath, missing,
                       "未离开上溯落点 → 写回原候选，而非上溯后的祖先")
    }

    /// 候选不存在时确实落在真实祖先目录上（而非不存在的候选），且一旦离开该祖先，
    /// degraded 立即解除、写回当前目录。
    func testDegradedStartupLandsOnAncestorThenReleasesOnLeave() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_wiring_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ancestor = TCPath(tmp.path).pathString
        let missing = ancestor + "/missing"
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: home,
                                            rightPath: missing, active: "right"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        XCTAssertEqual(vc.workspace.rightTabs.activePane.path.pathString, ancestor,
                       "不存在的候选应上溯到真实祖先目录")

        vc.workspace.rightTabs.activePane.gotoParent()
        XCTAssertEqual(store.snapshot?.rightPath, TCPath(tmp.path).parent!.pathString,
                       "离开上溯落点 → degraded 一次性解除，写回当前目录")
    }

    /// 只记录该侧**活动**标签：后台标签 load 不得把 /tmp 写进记忆。
    func testOnlyActiveTabIsRecorded() {
        let store = SessionStore(defaults: suite)
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        let leftTabs = vc.workspace.leftTabs
        let activePane = leftTabs.activePane
        let bg = FilePane(id: .left, source: LocalFileSource(), startPath: TCPath("/tmp"))
        leftTabs.add(bg)                        // 追加并激活（index 1）
        bg.onReload = activePane.onReload       // 模拟 app 的 wirePaneCallbacks
        leftTabs.activate(index: 0)             // 活动标签切回 index 0（home）

        bg.load()                               // 非活动标签的 reload
        XCTAssertEqual(store.snapshot?.leftPath, TCPath(home).pathString,
                       "记录的是该侧活动标签的目录；后台标签 /tmp 不得污染记忆")
    }

    // MARK: - 新标签继承当前目录（N1）

    /// 新标签落点 = 该侧当前目录（TC 行为），而不是 `startPath`。
    func testNewTabInheritsCurrentDirectory() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_newtab_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = SessionStore(defaults: suite)
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        vc.workspace.leftTabs.activePane.navigate(to: TCPath(tmp.path))
        let expected = vc.workspace.leftTabs.activePane.path.pathString
        XCTAssertNotEqual(expected, TCPath(home).pathString, "前置条件：导航确实离开了 home")

        vc.newTab(in: .left)
        XCTAssertEqual(vc.workspace.leftTabs.count, 2)
        XCTAssertEqual(vc.workspace.leftTabs.activePane.path.pathString, expected,
                       "新标签应继承该侧当前目录")
        XCTAssertEqual(store.snapshot?.leftPath, expected)
    }

    /// N1 核心：degraded 侧（候选不可用已上溯）开新标签**不得**击穿记忆保护。
    /// 若新标签落回 ~，则 current != resolved → degraded 解除 → 原候选被 ~ 覆盖（此断言即红）。
    func testNewTabOnDegradedSidePreservesCandidate() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fly_newtab_degraded_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ancestor = TCPath(tmp.path).pathString
        let missing = ancestor + "/missing"
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: home,
                                            rightPath: missing, active: "right"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        XCTAssertEqual(vc.workspace.rightTabs.activePane.path.pathString, ancestor)

        vc.newTab(in: .right)                   // 非活动侧开新标签（标签条 + 按钮同路）
        XCTAssertEqual(vc.workspace.rightTabs.activePane.path.pathString, ancestor,
                       "degraded 侧的新标签也应继承上溯落点，而非回落 ~")
        XCTAssertEqual(store.snapshot?.rightPath, missing,
                       "新标签不得击穿 degraded 保护：原候选必须保住")
    }

    /// 远端标签（SFTP/SMB）的路径不是本地路径 → 新标签回落默认起始目录。
    func testNewTabFromRemoteSideFallsBackToDefaultStart() {
        let store = SessionStore(defaults: suite)
        let vc = MainViewController(sessionStore: store)
        _ = vc.view
        // SMB 形态：pathString 形如 /share/dir，与本地无法区分，只能靠 source.isRemote 判定。
        let remote = FilePane(id: .left, source: RemoteStubFileSource(),
                              startPath: TCPath("/share/dir"))
        vc.workspace.leftTabs.add(remote)       // 成为该侧活动标签

        vc.newTab(in: .left)
        let fresh = vc.workspace.leftTabs.activePane
        XCTAssertFalse(fresh.source.isRemote, "新标签恒为本地源")
        XCTAssertEqual(fresh.path.pathString, MainViewController.startPath.pathString,
                       "远端标签的路径不可当本地路径继承 → 回落默认起始目录")
    }
}

/// 最小远端 fake：只为让 FilePane.source.isRemote 为真（不做 IO）。
private final class RemoteStubFileSource: FileSource {
    var sourceID: String { "smb://stub/share" }
    var isRemote: Bool { true }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}
