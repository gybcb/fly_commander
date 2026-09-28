import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// 拷贝三件套（用户新功能，⌃1/⌃2/⌃3，均走 View 菜单 keyEquivalent）：
/// - KeyDispatcher：⌃F1 已删（物理 F1 默认媒体键，真机不可用），裸/⌃ 的 keyCode 122 都不认领；
///   三件套不走 KeyDispatcher（数字键不在其表内，见下 testDigitKeysNotDispatched）；
/// - CommandRouter：范围 = operationTargets（标记多项→多行；无标记→焦点单项；
///   空→不回调），三粒度：copyPath=全路径 / copyDirPath=所在目录（目录条目=自身）/
///   copyFileName=仅名称，经 onCopyPaths 钩子交 app 层落剪贴板（TCCore 零 AppKit）；
/// - 路径格式 = item.path.displayString()：本地绝对路径；远端完整 URL sftp://host:port/…；
/// - MainMenu：View 菜单三项、mask 显式 [.control]、键位 1/2/3（⌃R 双负锁先例同款）。
final class CopyPathTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    // MARK: - KeyDispatcher（⌃F1 旧路已删的负锁）

    func testF1NotClaimedAnymore() {
        // 裸 F1 与 ⌃F1 都不认领：物理 F1 默认媒体键，真机 ⌃F1 收不到事件——已改走 ⌃1（见菜单）
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 122, modifiers: [])))
        XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: 122, modifiers: [.control])))
    }

    func testDigitKeysNotDispatched() {
        // ⌃1/⌃2/⌃3 走菜单 keyEquivalent 路（⌃R 先例：焦点无关、比裸键路稳），
        // 数字键不在 KeyDispatcher 表里——这里锁"数字键不认领"，防止误往表里加裸数字。
        for code: UInt16 in [18, 19, 20] {   // kVK_ANSI_1/2/3
            XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: code, modifiers: [])), "code=\(code)")
            XCTAssertNil(KeyDispatcher.dispatch(KeyInput(keyCode: code, modifiers: [.control])), "code=\(code)")
        }
    }

    // MARK: - CommandRouter

    /// 真临时目录 + pane.load()（FilterBarWiringTests 同款范式）。
    private func makeRouter(fileNames: [String]) throws -> (CommandRouter, FilePane) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("copyPath_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        deferDirCleanup.append(dir)
        for n in fileNames {
            // 支持 "sub/dir/keep.txt" 形式：逐级建中间目录，末段作文件写入。
            let url = dir.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: dir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: dir))
        left.load()
        let router = CommandRouter(workspace: Workspace(left: left, right: right, active: .left),
                                   engine: OperationEngine())
        return (router, left)
    }
    private var deferDirCleanup: [URL] = []
    override func tearDownWithError() throws {
        for d in deferDirCleanup { try? FileManager.default.removeItem(at: d) }
        deferDirCleanup = []
        try super.tearDownWithError()
    }

    private func index(_ pane: FilePane, _ name: String) -> Int {
        try! XCTUnwrap(pane.visibleItemIDs.firstIndex {
            $0.hasSuffix("/" + name)
        })
    }

    func testFocusedItemPathCopiedWhenNoMarks() throws {
        let (router, pane) = try makeRouter(fileNames: ["alpha.txt", "beta.txt"])
        pane.setFocus(to: index(pane, "beta.txt"))
        var got: [String]?
        router.onCopyPaths = { got = $0 }
        router.execute(.copyPath)
        XCTAssertEqual(got?.count, 1, "无标记 → 焦点单项")
        XCTAssertEqual(got?.first?.hasSuffix("/beta.txt"), true)
    }

    func testAllMarkedPathsCopiedMultiLine() throws {
        let (router, pane) = try makeRouter(fileNames: ["alpha.txt", "beta.txt", "gamma.txt"])
        pane.setFocus(to: index(pane, "gamma.txt"))
        pane.toggleMark(at: index(pane, "alpha.txt"))
        pane.toggleMark(at: index(pane, "beta.txt"))
        var got: [String]?
        router.onCopyPaths = { got = $0 }
        router.execute(.copyPath)
        XCTAssertEqual(got?.count, 2, "标记多项 → 逐条全收（焦点项不混入）")
        XCTAssertEqual(Set(got!.map { ($0 as NSString).lastPathComponent }),
                       ["alpha.txt", "beta.txt"])
    }

    /// ⌃2 所在目录：文件条目 → 其父目录路径（不含文件名本身）。
    func testCopyDirPathForFileIsParentDir() throws {
        let (router, pane) = try makeRouter(fileNames: ["alpha.txt"])
        pane.setFocus(to: index(pane, "alpha.txt"))
        var got: [String]?
        router.onCopyPaths = { got = $0 }
        router.execute(.copyDirPath)
        XCTAssertEqual(got?.count, 1)
        XCTAssertEqual(got?.first, pane.focusedItem?.path.parent?.displayString(),
                       "文件的所在目录=父目录")
        XCTAssertFalse(got?.first?.hasSuffix("alpha.txt") ?? true, "不得含文件名")
    }

    /// ⌃2 所在目录：目录条目 → 其自身路径（"这个目录"的路径，非其父）。
    func testCopyDirPathForDirectoryIsItself() throws {
        let (router, pane) = try makeRouter(fileNames: ["sub/dir/keep.txt"])
        // sub 是列出的目录条目
        guard let subIdx = pane.visibleItemIDs.firstIndex(where: { $0.hasSuffix("/sub") }) else {
            return XCTFail("夹具应有 sub 目录条目")
        }
        pane.setFocus(to: subIdx)
        var got: [String]?
        router.onCopyPaths = { got = $0 }
        router.execute(.copyDirPath)
        XCTAssertTrue(got?.first?.hasSuffix("/sub") ?? false, "目录条目的所在目录=自身路径")
    }

    /// ⌃3 仅名称：文件 → 文件名；目录 → 目录名（无路径前缀）。
    func testCopyFileNameIsBareName() throws {
        let (router, pane) = try makeRouter(fileNames: ["alpha.txt", "sub/keep.txt"])
        pane.setFocus(to: index(pane, "alpha.txt"))
        var got: [String]?
        router.onCopyPaths = { got = $0 }
        router.execute(.copyFileName)
        XCTAssertEqual(got, ["alpha.txt"], "文件仅名称，无路径")
    }

    func testEmptyTargetsNoCallback() throws {
        let (router, _) = try makeRouter(fileNames: [])
        var called = false
        router.onCopyPaths = { _ in called = true }
        router.execute(.copyPath)
        XCTAssertFalse(called, "空目标不得回调（防清空剪贴板）")
    }

    /// 远端格式锁：sftp URL 的 displayString 携 scheme://host:port（多服务器不歧义）。
    /// （用 ASCII 路径：TCPath 的 sftp 分支走 URL(string:)，未编码中文会落本地降级分支。）
    func testRemotePathIsFullURL() {
        let p = TCPath("sftp://10.0.0.5:2222/home/u/report.txt")
        XCTAssertEqual(p.displayString(), "sftp://10.0.0.5:2222/home/u/report.txt")
    }

    // MARK: - MainMenu

    /// 菜单键位锁：View 菜单三项、动作正确、keyEquivalent=1/2/3 且 **mask 显式 .control**
    /// （⌃R 双负锁先例同款：防落缺省 ⌘）。
    func testViewMenuCopyTripletKeys() throws {
        let main = MainMenu.build(target: NSObject())
        let view = main.items.first { $0.submenu?.title == L10n.t(.menuView) }?.submenu
        let cases: [(L10nKey, Selector, String)] = [
            (.copyPath, #selector(MainViewController.menuCopyPath(_:)), "1"),
            (.copyDirPath, #selector(MainViewController.menuCopyDirPath(_:)), "2"),
            (.copyFileName, #selector(MainViewController.menuCopyFileName(_:)), "3"),
        ]
        for (key, sel, kbd) in cases {
            let item = try XCTUnwrap(view?.items.first { $0.title == L10n.t(key) },
                                     "View 菜单缺 \(key) 项")
            XCTAssertEqual(item.action, sel)
            XCTAssertEqual(item.keyEquivalent, kbd, "\(key) 键位须 ⌃\(kbd)")
            XCTAssertEqual(item.keyEquivalentModifierMask, [.control], "\(key) 须显式 .control（防落缺省 ⌘）")
        }
    }
}
