import XCTest
import Foundation
@testable import TCCore

final class CommandRouterTests: XCTestCase {
    private var leftDir: URL!
    private var rightDir: URL!
    private var workspace: Workspace!
    private var router: CommandRouter!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rtr_\(UUID().uuidString)")
        leftDir = base.appendingPathComponent("L")
        rightDir = base.appendingPathComponent("R")
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        try "a".write(to: leftDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "z".write(to: leftDir.appendingPathComponent("z.txt"), atomically: true, encoding: .utf8)
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: TCPath(url: leftDir))
        let right = FilePane(id: .right, source: source, startPath: TCPath(url: rightDir))
        workspace = Workspace(left: left, right: right, active: .left)
        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        left.load()
        right.load()
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: leftDir.deletingLastPathComponent())
    }

    func testDownMovesFocus() {
        router.execute(.down, moveMode: .simple)
        XCTAssertEqual(workspace.activePane.selection.focusIndex, 1)
    }

    // MARK: - .enter 分流（目录→进入；文件→onOpen 默认程序打开）

    /// 焦点在目录上按回车：进目录，不触发 onOpen。
    func testEnterOnDirectoryNavigatesNotOpens() {
        try! FileManager.default.createDirectory(
            at: leftDir.appendingPathComponent("sub"), withIntermediateDirectories: false)
        let left = workspace.leftTabs.activePane
        left.load()
        let subIdx = left.selection.items.firstIndex { $0.hasSuffix("/sub") }!
        left.moveFocus(to: subIdx, mode: .simple)
        var opened: [FileItem] = []
        router.onOpen = { opened.append($0) }
        router.execute(.enter)
        XCTAssertEqual(left.path.url.lastPathComponent, "sub", "回车进目录")
        XCTAssertTrue(opened.isEmpty, "目录不该触发 onOpen")
    }

    /// 焦点在文件上按回车：触发 onOpen（AppKit 层接默认程序打开），不改 path。
    func testEnterOnFileFiresOnOpen() {
        let left = workspace.leftTabs.activePane
        let fileIdx = left.selection.items.firstIndex { $0.hasSuffix("a.txt") }!
        left.moveFocus(to: fileIdx, mode: .simple)
        var opened: [FileItem] = []
        router.onOpen = { opened.append($0) }
        let before = left.path
        router.execute(.enter)
        XCTAssertEqual(opened.map(\.name), ["a.txt"], "文件回车须发 onOpen")
        XCTAssertEqual(left.path, before, "onOpen 不改路径")
    }

    /// 空目录回车：两者皆不触发（无 focusedItem 不 crash）。
    func testEnterOnEmptyPaneIsNoop() {
        workspace.leftTabs.activePane.moveFocus(to: 2, mode: .simple)  // 越界钳回，仍有项
        let right = workspace.rightTabs.activePane                     // 空目录
        var opened: [FileItem] = []
        router.onOpen = { opened.append($0) }
        workspace.switchActive()
        router.execute(.enter)
        XCTAssertTrue(opened.isEmpty)
        _ = right
    }

    func testCopyToInactivePane() {
        router.execute(.copy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
    }

    func testCopyKeepsFocusOnSource() {
        router.execute(.copy)
        XCTAssertTrue(workspace.activePane.selection.focusID?.hasSuffix("L/a.txt") ?? false,
                      "focus: \(String(describing: workspace.activePane.selection.focusID))")
    }

    func testCopyKeepsFocusOnMarkedLastItem() {
        workspace.activePane.moveFocus(to: 1, mode: .simple)   // focus z.txt
        workspace.activePane.toggleMark()
        router.execute(.copy)
        let sel = workspace.activePane.selection
        XCTAssertTrue(sel.focusID?.hasSuffix("L/z.txt") ?? false,
                      "focus: \(String(describing: sel.focusID))")
        XCTAssertTrue(sel.focusID.map { sel.isMarked($0) } ?? false)
    }

    func testMoveToInactivePane() {
        router.execute(.move)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("a.txt").path))
    }

    func testMoveMovesFocusToNext() {
        router.execute(.move)
        XCTAssertTrue(workspace.activePane.selection.focusID?.hasSuffix("L/z.txt") ?? false,
                      "focus: \(String(describing: workspace.activePane.selection.focusID))")
    }

    func testMoveLastFileFocusMovesToFirstRemaining() {
        workspace.activePane.moveFocus(to: 1, mode: .simple)   // focus z.txt (last)
        router.execute(.move)
        XCTAssertTrue(workspace.activePane.selection.focusID?.hasSuffix("L/a.txt") ?? false,
                      "focus: \(String(describing: workspace.activePane.selection.focusID))")
    }

    func testRenameViaMethod() {
        workspace.activePane.moveFocus(to: 0, mode: .simple)
        router.rename(to: "changed.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("changed.txt").path))
    }

    func testMakeDirectoryViaMethod() {
        router.makeDirectory(named: "newdir")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftDir.appendingPathComponent("newdir").path))
    }

    func testRenameFailureSurfacesTCErrorMessage() {
        // a.txt already exists, so renaming z.txt -> a.txt must fail. The
        // user-facing message must be the normalized TCError (English),
        // not a localized-Error boilerplate string.
        workspace.activePane.moveFocus(to: 1, mode: .simple) // focus z.txt
        var last: OperationState?
        workspace.onOperationState = { last = $0 }
        router.rename(to: "a.txt")
        guard case .failed(let error)? = last else {
            return XCTFail("expected .failed, got \(String(describing: last))")
        }
        // Plan B：.failed 携带结构化 TCError（边界再翻译），不再是文本串。
        XCTAssertEqual(error, .alreadyExists("a.txt"))
    }

    func testDeleteDelegatesToOnDelete() {
        var got: [FileItem] = []
        router.onDelete = { _, items in got = items }
        router.execute(.delete)
        XCTAssertEqual(got.map { $0.name }, ["a.txt"])
    }

    func testViewFileDelegatesToOnView() {
        var got: FileItem?
        router.onView = { got = $0 }
        router.execute(.viewFile)
        XCTAssertEqual(got?.name, "a.txt")
    }

    func testEditFileDelegatesToOnEdit() {
        var got: FileItem?
        router.onEdit = { got = $0 }
        router.execute(.editFile)
        XCTAssertEqual(got?.name, "a.txt")
    }

    func testSearchDelegatesToOnSearch() {
        var got: TCPath?
        var gotSource: FileSource?
        router.onSearch = { path, source in got = path; gotSource = source }
        router.execute(.search)
        XCTAssertEqual(got, TCPath(url: leftDir))
        // 活动窗格的 source 一并透传（本地窗格 = LocalFileSource，sourceID "local"）
        XCTAssertEqual(gotSource?.sourceID, "local")
    }

    func testViewFileIgnoresDirectory() {
        let dirURL = leftDir.appendingPathComponent("subdir")
        try! FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: false)
        workspace.activePane.load()
        workspace.activePane.moveFocus(to: 0, mode: .simple)   // focus subdir (dirs first)
        var called = false
        router.onView = { _ in called = true }
        router.execute(.viewFile)
        XCTAssertFalse(called)
    }

    func testOperationStateEmittedOnCopy() {
        var last: OperationState?
        workspace.onOperationState = { last = $0 }
        router.execute(.copy)
        if case .done = last {
            // expected
        } else {
            XCTFail("expected .done, got \(String(describing: last))")
        }
    }

    func testNextTabCommandSwitchesActivePane() {
        // 左侧重建两个标签：L 与 L2（不同目录），验证切标签后 activePane 变化。
        let l2 = leftDir.deletingLastPathComponent().appendingPathComponent("L2")
        try? FileManager.default.createDirectory(at: l2, withIntermediateDirectories: true)
        let src = LocalFileSource()
        let p0 = FilePane(id: .left, source: src, startPath: TCPath(url: leftDir))
        let p1 = FilePane(id: .left, source: src, startPath: TCPath(url: l2))
        let lt = TabGroup(side: .left, panes: [p0, p1])
        let ws = Workspace(left: lt, right: tabGroupRight(), active: .left)
        let r = CommandRouter(workspace: ws, engine: OperationEngine())
        XCTAssertNotIdentical(ws.activePane, p1)
        r.execute(.nextTab)
        XCTAssertTrue(ws.activePane === p1, "nextTab 后活动窗格应为第二标签")
    }

    // MARK: - .openFavoritesMenu（F2 → onOpenFavoritesMenu 钩子，内核零收藏夹持有）

    /// 变异：删掉 execute 的 `.openFavoritesMenu: onOpenFavoritesMenu?(a)` 分支 → 钩子永不触发，
    /// 本用例红；分支传错窗格（如恒传 left）→ 切到右窗格后的断言红。
    func testOpenFavoritesMenuFiresHookWithActivePane() {
        var received: FilePane?
        router.onOpenFavoritesMenu = { received = $0 }
        router.execute(.openFavoritesMenu)
        XCTAssertTrue(received === workspace.activePane, "钩子须收到活动窗格（左）")
        workspace.switchActive()
        router.execute(.openFavoritesMenu)
        XCTAssertTrue(received === workspace.activePane, "切窗格后再按 → 收到右窗格")
    }

    private func tabGroupRight() -> TabGroup {
        TabGroup(side: .right, panes: [FilePane(id: .right, source: LocalFileSource(), startPath: TCPath(url: rightDir))])
    }

    // MARK: - .refresh（⌃R 手动刷新：重载当前目录且保焦点/筛选）

    /// 外部改了目录内容 → `.refresh` 须让列表反映新内容，且焦点项、筛选文本原样保留。
    /// 变异：分支改成 `a.load(preserveFocus: false)` → 焦点断言红；
    /// 分支整个删掉（穷举 switch 编译不过，故实际变异形态=分支体改空操作）→ 新文件不现身红。
    func testRefreshReloadsAndPreservesFocusAndFilter() throws {
        let left = workspace.leftTabs.activePane
        left.setFilter("txt")
        left.moveFocus(to: 1, mode: .simple)                 // 第二项
        let focusBefore = left.selection.focusID
        XCTAssertNotNil(focusBefore, "前置：有焦点项")

        // 模拟外部进程在磁盘上新建文件（绕开 pane 自己的操作路）。
        try "ext".write(to: leftDir.appendingPathComponent("external.txt"),
                        atomically: true, encoding: .utf8)

        router.execute(.refresh)

        XCTAssertTrue(left.page?.items.contains { $0.name == "external.txt" } ?? false,
                      ".refresh 须重载出新文件：\(left.page?.items.map(\.name) ?? [])")
        XCTAssertEqual(left.selection.focusID, focusBefore, "刷新须保焦点")
        XCTAssertEqual(left.filterText, "txt", "同目录刷新须保筛选")
    }

    /// 焦点项被外部删除时刷新：焦点钳到同索引的下一项（不崩、不清零到越界）。
    /// 变异：load 失败分支/selection.reload 不 clamp → 焦点越界或 nil，本用例红。
    func testRefreshClampsFocusWhenFocusedItemDeleted() throws {
        let left = workspace.leftTabs.activePane
        // 排序后 a.txt 在前（默认按名），焦点在末项 z.txt。
        left.moveFocus(to: (left.page?.items.count ?? 1) - 1, mode: .simple)
        let focused = left.focusedItem?.name
        XCTAssertEqual(focused, "z.txt", "前置：焦点在 z.txt")

        try FileManager.default.removeItem(at: leftDir.appendingPathComponent("z.txt"))
        router.execute(.refresh)

        XCTAssertFalse(left.page?.items.contains { $0.name == "z.txt" } ?? true,
                       "z.txt 已删，列表不应仍有")
        XCTAssertNotNil(left.focusedItem, "焦点项被删后须钳到有效项，不得 nil")
    }

    /// 远端活动窗格：`.refresh` 必须走 loadAsync（同步 load 会把网络 RTT 卡进主线程）。
    /// 证法：先挂 onReload 计数 + 快照「execute 返回瞬间」的 page——同步路会让快照变新
    /// （红），异步路快照仍是旧内容、回调稍后到（绿）。
    /// 变异：`.refresh` 分支改成裸 `pane.load()` → execute 返回瞬间 page 已是 new.txt → 快照断言红。
    func testRefreshUsesAsyncLoadForRemotePane() {
        let remote = FilterRefreshSource(id: "sftp://h:2222")
        remote.dirs["/r"] = [remoteItem("old.txt")]
        let rp = FilePane(id: .left, source: remote, startPath: TCPath("/r"))
        rp.load()
        XCTAssertEqual(rp.page?.items.map(\.name), ["old.txt"], "前置：初始 old.txt")

        let ws = Workspace(left: TabGroup(side: .left, panes: [rp]),
                           right: tabGroupRight(), active: .left)
        let r = CommandRouter(workspace: ws, engine: OperationEngine())

        remote.dirs["/r"] = [remoteItem("new.txt")]          // 外部改远端列表
        let done = expectation(description: "async reload done")
        rp.onReload = { _ in done.fulfill() }
        r.execute(.refresh)

        XCTAssertEqual(rp.page?.items.map(\.name), ["old.txt"],
                       ".refresh 不得同步阻塞——execute 返回瞬间仍应是旧内容")
        wait(for: [done], timeout: 5)
        XCTAssertEqual(rp.page?.items.map(\.name), ["new.txt"], "异步回来后须见新内容")
    }
}

/// 远端假源：isRemote=true，`listDirectory` 返回可变态 dirs，供 loadAsync 异步路验证。
private final class FilterRefreshSource: FileSource {
    let sourceID: String
    var isRemote = true
    var dirs: [String: [FileItem]] = [:]
    init(id: String) { sourceID = id }
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

private func remoteItem(_ name: String) -> FileItem {
    FileItem(id: "/r/\(name)", path: TCPath("/r/\(name)"), name: name, isDirectory: false,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}
