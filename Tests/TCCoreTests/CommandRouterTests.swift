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

    // MARK: - .favoriteDirectory（F2 → onFavorite 钩子，内核零收藏夹持有）

    /// 变异：删掉 execute 的 `.favoriteDirectory: onFavorite?(a)` 分支 → 钩子永不触发，
    /// 本用例红；分支传错窗格（如恒传 left）→ 切到右窗格后的断言红。
    func testFavoriteDirectoryFiresHookWithActivePane() {
        var received: FilePane?
        router.onFavorite = { received = $0 }
        router.execute(.favoriteDirectory)
        XCTAssertTrue(received === workspace.activePane, "钩子须收到活动窗格（左）")
        workspace.switchActive()
        router.execute(.favoriteDirectory)
        XCTAssertTrue(received === workspace.activePane, "切窗格后再按 → 收到右窗格")
    }

    private func tabGroupRight() -> TabGroup {
        TabGroup(side: .right, panes: [FilePane(id: .right, source: LocalFileSource(), startPath: TCPath(url: rightDir))])
    }
}
