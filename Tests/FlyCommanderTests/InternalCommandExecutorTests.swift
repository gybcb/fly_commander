import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T7b：InternalCommandExecutor 单测（fake 源 + 真实 FilePane/Workspace）。
/// 覆盖：cd 本地/远程（含拦截）、mkdir 远程、del 远程拦截语义（走 onDelete 钩子不直接删）、
/// ls/help/sftp 回显与参数。

private final class StubSource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer = true
    var table: [String: FileItem] = [:]
    var dirItems: [FileItem] = []
    var mkdirError: TCError?
    var lastErrorSim: TCError?

    init(id: String, remote: Bool) { sourceID = id; isRemote = remote }

    func item(_ path: String, dir: Bool = false) -> FileItem {
        FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                 isDirectory: dir, size: dir ? 0 : 1, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws { table[to.pathString] = table[from.pathString] }
    func moveItem(from: TCPath, to: TCPath) throws { table[to.pathString] = table.removeValue(forKey: from.pathString) }
    func renameItem(at: TCPath, to: TCPath) throws { table[to.pathString] = table.removeValue(forKey: at.pathString) }
    func makeDirectory(at: TCPath) throws {
        if let e = mkdirError { throw e }
        table[at.pathString] = item(at.pathString, dir: true)
        dirItems.append(table[at.pathString]!)
    }
    func removeItem(at: TCPath) throws { table[at.pathString] = nil }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        var sent = false
        return { _ in if sent { return Data() }; sent = true; return Data() }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {}
}

private final class Harness {
    let workspace: Workspace
    let executor: InternalCommandExecutor
    var deleted: InternalDeleteRequest?
    var connect: (host: String?, port: UInt16?)?
    var transfers: [CommandID] = []
    var viewItem: FileItem?
    var editItem: FileItem?
    var themeOpened = 0

    init(local: StubSource, remote: StubSource, activeRemote: Bool) {
        let left = FilePane(id: .left, source: local, startPath: TCPath("/L"))
        let right = FilePane(id: .right, source: remote, startPath: TCPath("sftp://h:2222/R"))
        let ws = Workspace(left: left, right: right, active: activeRemote ? .right : .left)
        left.load()
        right.load()
        let exec = InternalCommandExecutor(workspace: ws, engine: OperationEngine())
        workspace = ws
        executor = exec
        exec.onDelete = { [weak self] r in self?.deleted = r }
        exec.onConnectSFTP = { [weak self] h, p in self?.connect = (h, p) }
        ws.onCommandTransfer = { [weak self] c in self?.transfers.append(c) }
        ws.onCommandView = { [weak self] i in self?.viewItem = i }
        ws.onCommandEdit = { [weak self] i in self?.editItem = i }
        exec.onOpenTheme = { [weak self] in self?.themeOpened += 1 }
    }

    /// 在本地源里放文件 a.txt/b.txt 并让活动窗格聚焦第一个。
    func seedLocal(_ names: [String]) {
        let src = workspace.activePane.source as! StubSource
        src.dirItems = names.map { src.item("/L/\($0)") }
        for n in names { src.table["/L/\(n)"] = src.item("/L/\(n)") }
        workspace.activePane.load()
        _ = workspace.activePane.revealItem(id: "/L/\(names[0])")
    }

    /// 在远程源里放文件并聚焦。
    func seedRemote(_ names: [String]) {
        let src = workspace.activePane.source as! StubSource
        src.dirItems = names.map { src.item("/R/\($0)") }
        for n in names { src.table["/R/\(n)"] = src.item("/R/\(n)") }
        workspace.activePane.load()
        _ = workspace.activePane.revealItem(id: "/R/\(names[0])")
    }
}

final class InternalCommandExecutorTests: XCTestCase {
    // MARK: - ls / help

    func testLsEchoesItemCount() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "sftp://h:2222", remote: true), activeRemote: false)
        h.seedLocal(["a.txt", "b.txt"])
        let out = h.executor.execute(line: "ls")
        XCTAssertEqual(out, "/L：2 个条目")
    }

    func testHelpListsCommands() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "help")
        for kw in ["cd", "ls", "mkdir", "copy", "move", "del", "view", "edit", "sftp", "theme", "help"] {
            XCTAssertTrue(out?.contains(kw) ?? false, "help 应含 \(kw)：\(out ?? "nil")")
        }
    }

    func testUnknownCommand() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "frobnicate")
        XCTAssertTrue(out?.contains("未知命令") ?? false, "got: \(out ?? "nil")")
    }

    // MARK: - cd 本地

    func testCdLocalRelative() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        local.table["/L/sub"] = local.item("/L/sub", dir: true)
        let out = h.executor.execute(line: "cd sub")
        XCTAssertEqual(out, "已进入 /L/sub")
        XCTAssertEqual(h.workspace.activePane.path.pathString, "/L/sub")
    }

    func testCdLocalAbsolute() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        local.table["/tmp/x"] = local.item("/tmp/x", dir: true)
        let out = h.executor.execute(line: "cd /tmp/x")
        XCTAssertEqual(out, "已进入 /tmp/x")
    }

    func testCdLocalRejectsSftpTarget() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        let out = h.executor.execute(line: "cd sftp://h:22/x")
        XCTAssertTrue(out?.contains("本地窗格不能") ?? false, "got: \(out ?? "nil")")
    }

    // MARK: - cd 远程

    func testCdRemoteAcceptsSftpPath() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        remote.table["/R/deep"] = remote.item("/R/deep", dir: true)
        let out = h.executor.execute(line: "cd sftp://h:2222/R/deep")
        XCTAssertEqual(out, "已进入 sftp://h:2222/R/deep")
    }

    func testCdRemoteRejectsLocalPath() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        let out = h.executor.execute(line: "cd /etc")
        XCTAssertTrue(out?.contains("远程窗格只接受") ?? false, "got: \(out ?? "nil")")
    }

    func testCdMissingDirReportsFailure() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        // 目标不在 table → stat nil → navigate 拒绝（路径不变）
        let out = h.executor.execute(line: "cd /L/nonexistent")
        XCTAssertTrue(out?.contains("无法进入") ?? false, "got: \(out ?? "nil")")
    }

    // MARK: - mkdir（远程）

    func testMkdirRemote() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "mkdir nd")
        XCTAssertEqual(out, "已新建目录 sftp://h:2222/R/nd")
        XCTAssertNotNil(remote.table["/R/nd"])
    }

    func testMkdirRemoteFailureSurfacesTCError() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        remote.mkdirError = TCError.permissionDenied("nope")
        let out = h.executor.execute(line: "mkdir nd")
        XCTAssertTrue(out?.contains("新建失败") ?? false, "got: \(out ?? "nil")")
    }

    func testMkdirRequiresExactlyOneArg() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        XCTAssertTrue(h.executor.execute(line: "mkdir")?.contains("用法") ?? false)
        XCTAssertTrue(h.executor.execute(line: "mkdir a b")?.contains("用法") ?? false)
    }

    // MARK: - del（远程拦截语义：不直接删，走 onDelete 钩子）

    func testDelRemoteDelegatesToOnDeleteNotDirectRemove() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt", "b.txt"])
        // del * = 全部
        h.executor.execute(line: "del *")
        XCTAssertNotNil(h.deleted, "del 应走 onDelete 钩子（确认后删除）")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["a.txt", "b.txt"])
        // 文件此刻不应已被删（等待确认流）
        XCTAssertNotNil(remote.table["/R/a.txt"], "确认前不得真删")
    }

    func testDelRemoteMissingTargetReports() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "del nope.txt")
        XCTAssertTrue(out?.contains("未找到") ?? false, "got: \(out ?? "nil")")
        XCTAssertNil(h.deleted)
    }

    func testDelDefaultTargetsFocused() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt", "b.txt"])
        h.executor.execute(line: "del")
        XCTAssertEqual(h.deleted?.targets.map(\.name), ["a.txt"], "缺省=焦点项")
    }

    // MARK: - view / edit 远程降级

    func testViewRemoteDowngrades() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "sftp://h:2222", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: true)
        h.seedRemote(["a.txt"])
        let out = h.executor.execute(line: "view")
        XCTAssertTrue(out?.contains("远程暂不支持") ?? false, "got: \(out ?? "nil")")
        XCTAssertNil(h.viewItem)
    }

    func testViewLocalDelegates() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        h.executor.execute(line: "view")
        XCTAssertEqual(h.viewItem?.name, "a.txt")
    }

    // MARK: - sftp 参数

    func testSFTPNoArg() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "sftp")
        XCTAssertNil(h.connect?.0)
        XCTAssertNil(h.connect?.1)
        XCTAssertTrue(out?.contains("已打开") ?? false)
    }

    func testSFTPWithHostPort() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "sftp 10.0.0.5:2222")
        XCTAssertEqual(h.connect?.0, "10.0.0.5")
        XCTAssertEqual(h.connect?.1, 2222)
    }

    func testSFTPWithHostOnly() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        _ = h.executor.execute(line: "sftp example.com")
        XCTAssertEqual(h.connect?.0, "example.com")
        XCTAssertNil(h.connect?.1)
    }

    // MARK: - copy/move 走 workspace 钩子

    func testCopyDelegatesToWorkspaceHook() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        _ = h.executor.execute(line: "copy")
        XCTAssertEqual(h.transfers, [.copy])
    }

    func testMoveDelegatesToWorkspaceHook() {
        let local = StubSource(id: "local", remote: false)
        let remote = StubSource(id: "s", remote: true)
        let h = Harness(local: local, remote: remote, activeRemote: false)
        h.seedLocal(["a.txt"])
        _ = h.executor.execute(line: "move")
        XCTAssertEqual(h.transfers, [.move])
    }

    func testThemeCommandOpensWindow() {
        let h = Harness(local: StubSource(id: "local", remote: false),
                        remote: StubSource(id: "s", remote: true), activeRemote: false)
        let out = h.executor.execute(line: "theme")
        XCTAssertEqual(h.themeOpened, 1)
        XCTAssertEqual(out, "已打开主题窗")
    }
}
