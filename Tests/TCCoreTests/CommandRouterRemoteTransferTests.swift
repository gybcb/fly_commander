import XCTest
import Foundation
@testable import TCCore

/// T6：CommandRouter 的复制/移动在"任一端为远端源且注入了委托钩子"时交给
/// app 层后台执行器，而不是走本地快路径（快路径是同步的，远端会冻住主线程）。
/// 双端皆本地 → 钩子即便注入也不得调用；未注入钩子 → 仍走快路径（core 语义不变）。

private final class FakeRemoteSource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer = true
    var table: [String: FileItem]
    var dirItems: [FileItem] = []
    var copyError: TCError?
    var copyCalls: [String] = []

    init(id: String, remote: Bool, table: [String: FileItem] = [:]) {
        sourceID = id; isRemote = remote; self.table = table
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws {
        copyCalls.append(to.pathString)
        if let e = copyError { throw e }
        table[to.pathString] = table[from.pathString]
    }
    func moveItem(from: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: from.pathString)
    }
    func renameItem(at: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: at.pathString)
    }
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws { _ = table.removeValue(forKey: at.pathString) }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        var sent = false
        return { _ in
            if sent { return Data() }
            sent = true
            return Data()
        }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {}
}

private func fileItem(_ path: String, isDir: Bool = false) -> FileItem {
    let name = (path as NSString).lastPathComponent
    return FileItem(id: path, path: TCPath(path), name: name, isDirectory: isDir, size: 3,
                    modificationDate: .distantPast, isHidden: false,
                    isReadOnly: false, isExecutable: false)
}

final class CommandRouterRemoteTransferTests: XCTestCase {
    private var leftDir: URL!
    private var rightDir: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("rtrr_\(UUID().uuidString)")
        leftDir = base.appendingPathComponent("L")
        rightDir = base.appendingPathComponent("R")
        try FileManager.default.createDirectory(at: leftDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rightDir, withIntermediateDirectories: true)
        try "x".write(to: leftDir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: leftDir.deletingLastPathComponent())
    }

    /// 左窗格接远端假源（目录内含 a.txt），右窗格接本地源；返回已加载的工作区与路由。
    private func makeWorkspace() -> (Workspace, CommandRouter, FakeRemoteSource) {
        let item = fileItem("/R/a.txt")
        let remote = FakeRemoteSource(id: "sftp://test:2222", remote: true,
                                      table: ["/R/a.txt": item])
        remote.dirItems = [item]
        let local = LocalFileSource()
        let left = FilePane(id: .left, source: remote, startPath: TCPath("/R"))
        let right = FilePane(id: .right, source: local, startPath: TCPath(url: rightDir))
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        left.load()
        right.load()
        return (ws, router, remote)
    }

    func testCopyDelegatesToRemoteHookWithCorrectArgs() {
        let (ws, router, _) = makeWorkspace()
        var calls: [(isCopy: Bool, src: FilePane, dst: FilePane)] = []
        router.onRemoteTransfer = { calls.append(($0, $1, $2)) }
        router.execute(.copy)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(calls[0].isCopy)
        XCTAssertTrue(calls[0].src === ws.leftTabs.panes[0], "源应是活动窗格（左=远端）")
        XCTAssertTrue(calls[0].dst === ws.rightTabs.panes[0], "目标是另一窗格")
    }

    func testMoveDelegatesToRemoteHookWithIsCopyFalse() {
        let (ws, router, _) = makeWorkspace()
        var calls: [(isCopy: Bool, src: FilePane, dst: FilePane)] = []
        router.onRemoteTransfer = { calls.append(($0, $1, $2)) }
        router.execute(.move)
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].isCopy)
        XCTAssertTrue(calls[0].src === ws.leftTabs.panes[0])
        XCTAssertTrue(calls[0].dst === ws.rightTabs.panes[0])
    }

    /// 委托被调用时不得再走本地快路径（否则会重复传输/写错目标）。
    func testDelegatedCopySkipsLocalFastPath() {
        let (ws, router, remote) = makeWorkspace()
        var called = false
        router.onRemoteTransfer = { _, _, _ in called = true }
        router.execute(.copy)
        XCTAssertTrue(called)
        XCTAssertTrue(remote.copyCalls.isEmpty, "委托后不应有任何同源快路径写调用")
        XCTAssertEqual(remote.table.count, 1, "远端表不应被快路径改动：\(remote.table.keys)")
        _ = ws
    }

    func testLocalOnlyCopyDoesNotCallRemoteHook() {
        let local = LocalFileSource()
        let left = FilePane(id: .left, source: local, startPath: TCPath(url: leftDir))
        let right = FilePane(id: .right, source: local, startPath: TCPath(url: rightDir))
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        left.load()
        right.load()
        var hookCalled = false
        router.onRemoteTransfer = { _, _, _ in hookCalled = true }
        router.execute(.copy)
        XCTAssertFalse(hookCalled, "双端皆本地时不得走远端委托")
        // 走的是本地快路径：文件真的被复制了
        XCTAssertTrue(FileManager.default.fileExists(atPath: rightDir.appendingPathComponent("a.txt").path))
    }

    /// 未注入钩子：即便窗格是远端源，也退回快路径（core 保持同步语义，不依赖 app 层）。
    func testNoHookFallsBackToSynchronousFastPath() {
        // 两端接同一远端假源 → 同源快路径（copyItem）
        let item = fileItem("/R/a.txt")
        let remote = FakeRemoteSource(id: "sftp://test:2222", remote: true,
                                      table: ["/R/a.txt": item])
        remote.dirItems = [item]
        remote.copyError = TCError.unknown("boom-remote")
        let left = FilePane(id: .left, source: remote, startPath: TCPath("/R"))
        let right = FilePane(id: .right, source: remote, startPath: TCPath("/S"))
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        left.load()
        right.load()
        var last: OperationState?
        ws.onOperationState = { last = $0 }
        router.execute(.copy)
        XCTAssertEqual(remote.copyCalls, ["/S/a.txt"], "未注入钩子时应走同步快路径")
        guard case .failed(let msg) = last else {
            return XCTFail("快路径失败应同步上报 .failed，得到 \(String(describing: last))")
        }
        XCTAssertTrue(msg.contains("boom-remote"), "应透出源端错误：\(msg)")
    }
}
