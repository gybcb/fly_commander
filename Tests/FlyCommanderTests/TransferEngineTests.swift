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
private final class StateRecorder {
    var entries: [(label: String, progress: Double?)] = []
    var finishedPanes: (FilePane, FilePane)?
    func record(_ s: OperationState) {
        switch s {
        case .running(let l, let p): entries.append((l, p))
        case .done(let m): entries.append((m, nil))
        case .failed(let m): entries.append(("FAILED:\(m)", nil))
        case .idle: entries.append(("IDLE", nil))
        }
    }
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
    func testCrossSourceCopyStreamsAndEmitsProgressAndDone() {
        let h = Harness()
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
        XCTAssertEqual(h.local.table["/dst/a.txt"]?.size, 11)
        // 状态序：running(0) → running(1) → done
        XCTAssertEqual(h.rec.entries.count, 3, "状态流：\(h.rec.entries)")
        XCTAssertEqual(h.rec.entries[0].progress, 0)
        XCTAssertEqual(h.rec.entries[1].progress, 1)
        XCTAssertTrue(h.rec.entries[2].label.hasPrefix("复制 1 个文件 完成"), "done：\(h.rec.entries[2].label)")
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

    func testCancelFromPromptYieldsIdleNotFailed() {
        let h = Harness()
        h.local.table["/dst/a.txt"] = h.local.item("/dst/a.txt", size: 1)
        h.engine.prompt = { _, _ in .cancel }
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last?.label, "IDLE", "取消应是 idle：\(h.rec.entries)")
    }

    func testSourceDeleteFailureOnMoveWarnsButCompletes() {
        let h = Harness()
        h.remote.removeError = TCError.unknown("disk full")
        h.engine.run(false, h.left, h.right)
        guard let last = h.rec.entries.last else { return XCTFail("move 应完成：\(h.rec.entries)") }
        XCTAssertTrue(last.label.hasPrefix("移动 1 个文件 完成"), "done 文案：\(last.label)")
        XCTAssertTrue(last.label.contains("⚠"), "删源失败应带警告：\(last.label)")
        XCTAssertTrue(last.label.contains("源端残留"), "警告内容：\(last.label)")
        // 传输本身成功
        XCTAssertEqual(h.local.data["/dst/a.txt"], Data("hello world".utf8))
    }

    func testEngineFailureSurfacesFailedState() {
        let h = Harness()
        h.remote.data = [:]   // openReader 抛 "no file: /src/a.txt"
        h.engine.run(true, h.left, h.right)
        XCTAssertEqual(h.rec.entries.last?.label, "FAILED:no file: /src/a.txt", "应透出源端错误：\(h.rec.entries)")
    }

    func testNoTargetsDoesNothing() {
        let h = Harness()
        h.remote.dirItems = []
        h.left.load()
        h.engine.run(true, h.left, h.right)
        XCTAssertTrue(h.rec.entries.isEmpty, "无目标项时不应有任何状态回调：\(h.rec.entries)")
    }
}
