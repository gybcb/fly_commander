import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T6 单测：TransferEngine 后台跨源传输的状态回调、收尾刷新、冲突询问透传。
/// 线程边界注入同步实现（runInBackground/onMain 直接调用），避免主线程死锁。

/// 内存假源：table 存元数据，data 存文件内容（跨源流式写落这里）。
private final class MemSource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer = true
    var table: [String: FileItem] = [:]
    var data: [String: Data] = [:]
    var removeError: TCError?
    var removeCalls: [String] = []
    var dirItems: [FileItem] = []

    init(id: String, remote: Bool) { sourceID = id; isRemote = remote }

    func item(_ path: String, size: Int64) -> FileItem {
        FileItem(id: path, path: TCPath(path), name: (path as NSString).lastPathComponent,
                 isDirectory: false, size: size, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] { dirItems }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { table[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws {
        table[to.pathString] = table[from.pathString]
        data[to.pathString] = data[from.pathString]
    }
    func moveItem(from: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: from.pathString)
        data[to.pathString] = data.removeValue(forKey: from.pathString)
    }
    func renameItem(at: TCPath, to: TCPath) throws {
        table[to.pathString] = table.removeValue(forKey: at.pathString)
        data[to.pathString] = data.removeValue(forKey: at.pathString)
    }
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {
        removeCalls.append(at.pathString)
        if let e = removeError { throw e }
        table[at.pathString] = nil
        data[at.pathString] = nil
    }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        guard let payload = data[path.pathString] else { throw TCError.unknown("no file: \(path.pathString)") }
        var i = 0
        return { _ in
            guard i < payload.count else { return Data() }
            let slice = payload.subdata(in: i..<min(i + 7, payload.count))
            i += slice.count
            return slice
        }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {
        var buf = Data()
        while true {
            let chunk = try write()
            if chunk.isEmpty { break }
            buf.append(chunk)
        }
        data[path.pathString] = buf
        table[path.pathString] = item(path.pathString, size: Int64(buf.count))
    }
}

/// 状态记录器（引用类型，闭包与测试共享同一份数组）。
/// Plan B：OperationState 是结构化契约（key + args + warningLines），原样存下再逐 case 断言。
private final class StateRecorder {
    var entries: [OperationState] = []
    var finishedPanes: (FilePane, FilePane)?
    func record(_ s: OperationState) { entries.append(s) }
}

/// 同步线程边界的执行器 + 真实 FilePane 对（左=远端假源，右=本地假源）。
private final class Harness {
    let engine: TransferEngine
    let remote: MemSource
    let local: MemSource
    let left: FilePane
    let right: FilePane
    let rec = StateRecorder()

    init() {
        remote = MemSource(id: "sftp://h:2222", remote: true)
        local = MemSource(id: "local-t", remote: false)
        let aFile = remote.item("/src/a.txt", size: 11)
        remote.table["/src/a.txt"] = aFile
        remote.data["/src/a.txt"] = Data("hello world".utf8)
        remote.dirItems = [aFile]

        left = FilePane(id: .left, source: remote, startPath: TCPath("/src"))
        right = FilePane(id: .right, source: local, startPath: TCPath("/dst"))
        left.load()
        right.load()

        let te = TransferEngine()
        te.runInBackground = { $0() }
        te.onMain = { $0() }
        engine = te
        te.state = { [weak self] s in self?.rec.record(s) }
        te.onFinished = { [weak self] s, d in self?.rec.finishedPanes = (s, d) }
    }
}

final class TransferEngineTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 警告串/状态串都经 L10n 表；固定英文默认，zh 用例内部自切自恢复。
        L10n.current = .en
    }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    func testCrossSourceCopyStreamsAndEmitsProgressAndDone() {
        let h = Harness()
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
        XCTAssertEqual(h.local.table["/dst/a.txt"]?.size, 11)
        // 状态序：running(0) → running(1) → done（Plan B：结构化 key，非中文串）
        XCTAssertEqual(h.rec.entries.count, 3, "状态流：\(h.rec.entries)")
        XCTAssertEqual(h.rec.entries[0], .running(label: .opCopying, args: ["1"], progress: 0))
        XCTAssertEqual(h.rec.entries[1], .running(label: .opCopying, args: ["1"], progress: 1))
        XCTAssertEqual(h.rec.entries[2], .done(label: .opCopying, args: ["1"], warningLines: []))
    }

    func testOnFinishedReceivesBothPanes() {
        let h = Harness()
        h.engine.run(true, h.left, h.right)
        XCTAssertTrue(h.rec.finishedPanes?.0 === h.left, "onFinished 源窗格应是 left")
        XCTAssertTrue(h.rec.finishedPanes?.1 === h.right, "onFinished 目标窗格应是 right")
    }

    func testConflictPromptIsPassedThrough() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        h.local.data["/dst/a.txt"] = Data("old".utf8)
        var prompts: [(String, String)] = []
        h.engine.prompt = { s, d in
            prompts.append((s.pathString, d.pathString))
            return .overwrite
        }
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(prompts.count, 1)
        XCTAssertEqual(prompts[0].0, "/src/a.txt")
        XCTAssertEqual(prompts[0].1, "/dst/a.txt")
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8), "覆盖后应为源内容")
    }

    func testConflictPromptRunsOnMainThread() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        var ranOnMain = false
        h.engine.prompt = TransferEngine.promptOnMain { _, _ in
            ranOnMain = Thread.isMainThread
            return .overwrite
        }
        // 模拟 app 侧真实线程拓扑：传输块跑在后台线程（run() 仍在主线程发起）。
        // 用 expectation + wait(for:)（泵 run loop），不能用信号量阻塞主线程——
        // 否则 promptOnMain 的 main.sync 无法被服务。
        let exp = expectation(description: "transfer finished")
        h.engine.runInBackground = { block in
            DispatchQueue.global(qos: .userInitiated).async {
                block()
                exp.fulfill()
            }
        }
        h.engine.onMain = { $0() }
        h.engine.run(true, h.left, h.right)
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(ranOnMain, "冲突询问必须在主线程执行")
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
    }

    func testCancelFromPromptYieldsIdleNotFailed() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        h.engine.prompt = { _, _ in .cancel }
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last, .idle, "取消应是 idle：\(h.rec.entries)")
    }

    func testSourceDeleteFailureOnMoveWarnsButCompletes() {
        let h = Harness()
        h.remote.removeError = TCError.busy("x")
        h.engine.run(false, h.left, h.right)
        // Plan B：引擎产结构化原料 (name, TCError)，成品警告串在 AppKit 边界（L10n）组装。
        guard case .done(let label, let args, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(label, .opMoving)
        XCTAssertEqual(args, ["1"])
        XCTAssertEqual(warns, ["Source leftover: a.txt (Busy: x)"], "警告成品串：\(warns)")
        // 传输本身成功
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
    }

    /// 警告串随语言：zh 下 TransferEngine 组装的是中文模板（全角 ：（））。
    func testSourceDeleteWarningFollowsLanguage() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let h = Harness()
        h.remote.removeError = TCError.busy("x")
        h.engine.run(false, h.left, h.right)
        guard case .done(_, _, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(warns, ["源端残留：a.txt（忙碌/被占用：x）"], "zh 警告：\(warns)")
    }

    /// R-C1 哨兵：警告原料是 `.unknown`（locale 透传文本）时，内嵌串必须是**裸 payload**——
    /// errUnknown 模板改裸 {0} 后不得再出现 "（错误：disk full）" 的层内前缀。
    func testSourceDeleteWarningWithUnknownIsBarePayload() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let h = Harness()
        h.remote.removeError = TCError.unknown("disk full")
        h.engine.run(false, h.left, h.right)
        guard case .done(_, _, let warns)? = h.rec.entries.last else {
            return XCTFail("move 应完成：\(h.rec.entries)")
        }
        XCTAssertEqual(warns, ["源端残留：a.txt（disk full）"], "zh 警告：\(warns)")
    }

    func testEngineFailureSurfacesFailedState() {
        let h = Harness()
        h.remote.data = [:]   // openReader 抛 TCError.unknown("no file: /src/a.txt")
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last, .failed(.unknown("no file: /src/a.txt")),
                       "应透出源端错误（结构化 TCError）：\(h.rec.entries)")
    }

    func testNoTargetsDoesNothing() {
        let h = Harness()
        h.remote.dirItems = []
        h.left.load()
        h.engine.run(true, h.left, h.right)
        XCTAssertTrue(h.rec.entries.isEmpty, "无目标项时不应有任何状态回调：\(h.rec.entries)")
    }
}
