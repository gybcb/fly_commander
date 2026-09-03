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
        // user-facing message must be the normalized TCError.message (Chinese),
        // not a localized-Error boilerplate string.
        workspace.activePane.moveFocus(to: 1, mode: .simple) // focus z.txt
        var last: OperationState?
        workspace.onOperationState = { last = $0 }
        router.rename(to: "a.txt")
        guard case .failed(let message)? = last else {
            return XCTFail("expected .failed, got \(String(describing: last))")
        }
        XCTAssertTrue(message.hasPrefix("Already exists"), "got: \(message)")
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

    private func tabGroupRight() -> TabGroup {
        TabGroup(side: .right, panes: [FilePane(id: .right, source: LocalFileSource(), startPath: TCPath(url: rightDir))])
    }
}
