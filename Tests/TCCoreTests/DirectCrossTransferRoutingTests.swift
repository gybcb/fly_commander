import XCTest
import Foundation
@testable import TCCore

/// 记录型假源（形状取自 OperationEngineRoutingTests 的 private FakeSource，
/// 跨文件不可复用故就地复制并补本特性需要的探针）。
private final class FakeSource: FileSource {
    let sourceID: String
    let isRemote: Bool
    var supportsTransfer = true

    /// 目录树夹具：listDirectory 按 path.pathString 查此表。
    var listTable: [String: [FileItem]] = [:]
    var statTable: [String: FileItem] = [:]
    var readerChunks: [Data] = []
    var chunksByPath: [String: [Data]] = [:]

    // 记录数组（断言用）
    var listCalls: [String] = []
    var removed: [String] = []
    var madeDirectories: [String] = []
    var openReaders: [String] = []
    var streamWrites: [(path: String, total: Int64?, data: Data)] = []
    var copyCalls: [String] = []
    var moveCalls: [String] = []

    init(id: String, remote: Bool = true) { sourceID = id; isRemote = remote }

    /// 挂一个文件条目（同时进 stat 表与所在目录列表）。
    func add(file name: String, size: Int64, in dir: String = "/") {
        statTable[dir + name] = sizedItem(name, in: dir, size: size)
        listTable[dir, default: []].append(sizedItem(name, in: dir, size: size))
    }
    /// 挂一个目录条目（目标端 = 空目录，源端内容由调用方另设 listTable）。
    func addDir(_ name: String, in dir: String = "/") {
        statTable[dir + name] = dirItem(name, in: dir)
        listTable[dir, default: []].append(dirItem(name, in: dir))
        listTable[dir + name, default: []] = []
    }
    /// 按名字取顶层条目（performCopy/performMove 的入参）。
    func items(_ names: String...) -> [FileItem] {
        names.map { statTable["/" + $0]! }
    }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        listCalls.append(path.pathString); return listTable[path.pathString] ?? []
    }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? { statTable[path.pathString] }
    func copyItem(from: TCPath, to: TCPath) throws { copyCalls.append(from.pathString) }
    func moveItem(from: TCPath, to: TCPath) throws { moveCalls.append(from.pathString) }
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws { madeDirectories.append(at.pathString) }
    func removeItem(at: TCPath) throws { removed.append(at.pathString) }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        openReaders.append(path.pathString)
        var i = 0
        let chunks = chunksByPath[path.pathString] ?? readerChunks
        return { _ in
            guard i < chunks.count else { return nil }
            let c = chunks[i]; i += 1
            return c
        }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws {
        var data = Data()
        while true {
            let chunk = try write()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        streamWrites.append((path.pathString, totalBytes, data))
    }
}

private func dirItem(_ name: String, in dir: String) -> FileItem {
    FileItem(id: dir + name, path: TCPath(dir + name),
             name: name, isDirectory: true, size: 0,
             modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

private func sizedItem(_ name: String, in dir: String, size: Int64) -> FileItem {
    FileItem(id: dir + name, path: TCPath(dir + name),
             name: name, isDirectory: false, size: size,
             modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

private func fakeItem(_ name: String, size: Int64 = 10) -> FileItem {
    sizedItem(name, in: "/", size: size)
}

/// 跨机直传接缝的路由锁：接缝点位置、粘连回退、pump 零参与。
final class DirectCrossTransferRoutingTests: XCTestCase {
    private var src = FakeSource(id: "sftp://a:22")
    private var dst = FakeSource(id: "sftp://b:22")
    private var engine = OperationEngine()

    // MARK: performCopy

    /// .handled → 引擎不开 reader/writer（pump 一行都不跑），条目级进度照常。
    func testHandledSkipsPump() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        var bytes: [(Int64, Int64)] = []
        var files: [(Int, Int)] = []
        try engine.performCopy(src.items("a.txt"), to: TCPath("/"),
                               srcSource: src, dstSource: dst,
                               progress: { files.append(($0, $1)) },
                               byteProgress: { bytes.append(($0, $1)) })
        XCTAssertEqual(src.openReaders.count, 0, "handled 不得开 reader")
        XCTAssertEqual(dst.streamWrites.count, 0, "handled 不得开 writer")
        XCTAssertEqual(bytes.map { "\($0.0)/\($0.1)" }, ["10/10"])
        XCTAssertEqual(files.map { "\($0.0)/\($0.1)" }, ["1/1"])
    }

    /// 接缝拿到的 destDir 就是 destDir.joining(item.name)（冲突处理同点）。
    func testSeamReceivesJoinedDest() throws {
        src.add(file: "a.txt", size: 10)
        var seen: TCPath?
        engine.directCrossTransfer = { _, dest, _ in seen = dest; return .handled(bytesTransferred: 10) }
        try engine.performCopy(src.items("a.txt"), to: TCPath("/tmp"),
                               srcSource: src, dstSource: dst)
        XCTAssertEqual(seen?.pathString, "/tmp/a.txt")
    }

    /// .unavailable → 走 pump；同批后续条目不再问（粘连）。
    func testUnavailableFallsBackAndStickyForBatch() throws {
        src.add(file: "a.txt", size: 10); src.add(file: "b.txt", size: 10)
        var calls = 0
        engine.directCrossTransfer = { _, _, _ in calls += 1; return .unavailable("nope") }
        try engine.performCopy(src.items("a.txt", "b.txt"), to: TCPath("/"),
                               srcSource: src, dstSource: dst)
        XCTAssertEqual(calls, 1, "首条目 .unavailable 后同批不得再问")
        XCTAssertEqual(src.openReaders.count, 2, "两条目都须走 pump")
    }

    /// 同源（sourceID 相等）恒不问接缝（cp 快路径不经接缝）。
    func testSameSourceNeverAsks() throws {
        let same = FakeSource(id: "sftp://a:22")
        let sameDst = FakeSource(id: "sftp://a:22")
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        try engine.performCopy([fakeItem("a.txt", size: 10)], to: TCPath("/"),
                               srcSource: same, dstSource: sameDst)
        XCTAssertFalse(asked)
    }

    /// 默认（不注入接缝 = nil）= 行为与本特性诞生前逐字节一致。
    func testNoSeamBehavesAsBefore() throws {
        src.add(file: "a.txt", size: 10)
        try engine.performCopy(src.items("a.txt"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertEqual(src.openReaders.count, 1)
    }

    /// 接缝抛错 → 原样上抛，不回退 pump。
    func testThrowPropagatesNoFallback() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in throw TCError.unknown("boom") }
        XCTAssertThrowsError(try engine.performCopy(src.items("a.txt"), to: TCPath("/"),
                                                    srcSource: src, dstSource: dst))
        XCTAssertEqual(src.openReaders.count, 0, "抛错后不得再 pump")
    }

    /// 目录条目：接缝处理整棵子树——引擎绝不再递归（不 listDirectory 子项、不 mkdir 目标）。
    func testDirectoryItemGoesWholeToSeam() throws {
        src.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 42) }
        try engine.performCopy(src.items("sub"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertEqual(src.listCalls.count, 0, "接缝路引擎不得列目录")
        XCTAssertEqual(dst.madeDirectories.count, 0, "接缝路引擎不得建目标目录")
    }

    /// 目录条目 + 目标已存在同名目录 → 不问接缝（rsync 语义无法表达合并），直接 pump 合并。
    func testExistingDestDirSkipsSeam() throws {
        src.addDir("sub"); dst.addDir("sub")
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        try engine.performCopy(src.items("sub"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertFalse(asked, "目标同名目录在位 → 合并语义归 pump，不问接缝")
    }

    /// 冲突 skip → 接缝不被调用、pump 也不跑、条目计入完成。
    func testConflictSkipSkipsSeam() throws {
        src.add(file: "a.txt", size: 10); dst.add(file: "a.txt", size: 1)
        var asked = false
        engine.directCrossTransfer = { _, _, _ in asked = true; return .handled(bytesTransferred: 1) }
        var files: [(Int, Int)] = []
        try engine.performCopy(src.items("a.txt"), to: TCPath("/"), srcSource: src, dstSource: dst,
                               prompt: { _, _ in .skip },
                               progress: { files.append(($0, $1)) })
        XCTAssertFalse(asked)
        XCTAssertEqual(files.map { "\($0.0)/\($0.1)" }, ["1/1"])
    }

    /// 冲突 overwrite（目标为文件）→ 删除后接缝照问（此时 dst 干净）。
    func testOverwriteRemovesThenAsksSeam() throws {
        src.add(file: "a.txt", size: 10); dst.add(file: "a.txt", size: 1)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        try engine.performCopy(src.items("a.txt"), to: TCPath("/"), srcSource: src, dstSource: dst,
                               prompt: { _, _ in .overwrite })
        XCTAssertEqual(dst.removed.count, 1)
        XCTAssertEqual(src.openReaders.count, 0)
    }

    /// 取消置位 → 抛 .cancelled，接缝不被调用。
    func testCancelBeatsSeam() throws {
        src.add(file: "a.txt", size: 10)
        let flag = CancelFlag(); flag.cancel()
        engine.directCrossTransfer = { _, _, _ in XCTFail("取消后不得问接缝"); return .unavailable("x") }
        XCTAssertThrowsError(try engine.performCopy(src.items("a.txt"), to: TCPath("/"),
                                                    srcSource: src, dstSource: dst, cancel: flag))
    }

    /// 多条目：handled 帧的 bytesDone = 已完成条目累计 + 本条目已传。
    func testBytesDoneAccumulatesAcrossItems() throws {
        src.add(file: "a.txt", size: 10); src.add(file: "b.txt", size: 20)
        engine.directCrossTransfer = { item, _, bp in
            bp?(5, item.size); bp?(item.size, item.size)
            return .handled(bytesTransferred: item.size)
        }
        var bytes: [(Int64, Int64)] = []
        try engine.performCopy(src.items("a.txt", "b.txt"), to: TCPath("/"),
                               srcSource: src, dstSource: dst,
                               byteProgress: { bytes.append(($0, $1)) })
        XCTAssertEqual(bytes.map { "\($0.0)/\($0.1)" }, ["5/10", "10/10", "15/20", "30/20"],
                       "第二条目帧须累计第一条目字节（base=10：5→15、20→30）")
    }

    // MARK: performMove

    /// 移动 + handled → 传完后删源根一次，不 pump。
    func testMoveHandledDeletesSource() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 10) }
        try engine.performMove(src.items("a.txt"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertEqual(src.removed.count, 1)
        XCTAssertEqual(src.openReaders.count, 0)
    }

    /// 移动 + 目录条目 handled → 同样删源根一次（递归删由 fake 记账）。
    func testMoveDirectoryHandledDeletesSource() throws {
        src.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in .handled(bytesTransferred: 42) }
        try engine.performMove(src.items("sub"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertEqual(src.removed.count, 1)
        XCTAssertEqual(src.listCalls.count, 0)
    }

    /// 移动 + unavailable → pump 路 + 删源（与现状逐字一致）。
    func testMoveUnavailableUsesPumpAndDeletes() throws {
        src.add(file: "a.txt", size: 10)
        engine.directCrossTransfer = { _, _, _ in .unavailable("nope") }
        try engine.performMove(src.items("a.txt"), to: TCPath("/"), srcSource: src, dstSource: dst)
        XCTAssertEqual(src.openReaders.count, 1)
        XCTAssertEqual(src.removed.count, 1)
    }

    /// 移动 + 目标同名目录在位 → 不问接缝走 pump 合并路；prompt=skip →
    /// copyDirectoryCross 返回 skipped → **不删源**（既有合同原样，接缝零参与）。
    /// （注：无 prompt 时缺省合并**会**删源——那是既有 pump 行为，别锁错方向。）
    func testMoveExistingDestDirNoSeamKeepsSource() throws {
        src.addDir("sub"); dst.addDir("sub")
        engine.directCrossTransfer = { _, _, _ in XCTFail("合并路不问接缝"); return .unavailable("x") }
        try engine.performMove(src.items("sub"), to: TCPath("/"), srcSource: src, dstSource: dst,
                               prompt: { _, _ in .skip })
        XCTAssertEqual(src.removed.count, 0, "skip 决策 → 不得删源")
    }
}
