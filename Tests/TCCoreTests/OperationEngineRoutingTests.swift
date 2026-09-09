import XCTest
import Foundation
@testable import TCCore

/// 记录型假源：验证 OperationEngine 的同源/跨源分流与调用序（不碰磁盘）。
private struct Pair: Equatable {
    let a: String
    let b: String
}

private final class FakeSource: FileSource {
    let sourceID: String
    let isRemote: Bool
    var supportsTransfer = true
    var statTable: [String: FileItem] = [:]
    var readerChunks: [Data] = []
    var removeError: TCError?
    var removeFailWhen: String? = nil   // path.pathString 匹配时 remove 抛 removeError
    var copyError: TCError?
    var moveError: TCError?
    var moveFailWhenFrom: String? = nil   // from.pathString 匹配时 move 抛 moveError
    var renameError: TCError?
    var mkdirError: TCError?

    var listCalls: [String] = []
    var statCalls: [String] = []
    var copyCalls: [Pair] = []
    var moveCalls: [Pair] = []
    var renameCalls: [Pair] = []
    var mkdirCalls: [String] = []
    var removeCalls: [String] = []
    var openReaders: [String] = []
    var streamWrites: [(path: String, total: Int64?, data: Data)] = []

    init(id: String, remote: Bool = false) { sourceID = id; isRemote = remote }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        listCalls.append(path.pathString); return []
    }
    func isDirectory(_ path: TCPath) -> Bool { (try? stat(path))?.isDirectory ?? false }
    func stat(_ path: TCPath) throws -> FileItem? {
        statCalls.append(path.pathString)
        return statTable[path.pathString]
    }
    func copyItem(from: TCPath, to: TCPath) throws {
        copyCalls.append(Pair(a: from.pathString, b: to.pathString))
        if let e = copyError { throw e }
    }
    func moveItem(from: TCPath, to: TCPath) throws {
        moveCalls.append(Pair(a: from.pathString, b: to.pathString))
        if let failFrom = moveFailWhenFrom, from.pathString == failFrom, let e = moveError { throw e }
    }
    func renameItem(at: TCPath, to: TCPath) throws {
        renameCalls.append(Pair(a: at.pathString, b: to.pathString))
        if let e = renameError { throw e }
    }
    func makeDirectory(at: TCPath) throws {
        mkdirCalls.append(at.pathString)
        if let e = mkdirError { throw e }
    }
    func removeItem(at: TCPath) throws {
        removeCalls.append(at.pathString)
        if let fail = removeFailWhen, at.pathString == fail, let e = removeError { throw e }
        else if removeFailWhen == nil, let e = removeError { throw e }
    }
    func openReader(_ path: TCPath) throws -> ReadHandle {
        openReaders.append(path.pathString)
        var i = 0
        let chunks = readerChunks
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

private func fakeItem(_ name: String, in dir: String) -> FileItem {
    FileItem(id: dir + "/" + name, path: TCPath(dir + "/" + name),
             name: name, isDirectory: false, size: 10,
             modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

final class OperationEngineRoutingTests: XCTestCase {
    private let engine = OperationEngine()
    private let a = FakeSource(id: "src-a")
    private let b = FakeSource(id: "src-b", remote: true)

    // MARK: - 同源走源内快路径

    func testSameSourceCopyUsesSourceCopyNotStream() throws {
        a.statTable["/d/a.txt"] = fakeItem("a.txt", in: "/d")
        _ = try engine.performCopy([fakeItem("a.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: a)
        XCTAssertEqual(a.copyCalls.count, 1)
        XCTAssertTrue(a.openReaders.isEmpty)
        XCTAssertTrue(a.streamWrites.isEmpty)
        // 冲突检查走 dst 源 stat（目标存在，默认 prompt=nil → 覆盖删除）
        XCTAssertTrue(a.statCalls.contains("/d/a.txt"))
        XCTAssertTrue(a.removeCalls.contains("/d/a.txt"))
    }

    func testSameSourceMoveUsesSourceMoveWithRollback() throws {
        b.moveCalls = []
        // 第二项（from == /s/2.txt）move 失败 → 回滚第一项。
        b.moveError = TCError.unknown("boom")
        b.moveFailWhenFrom = "/s/2.txt"
        let items = [fakeItem("1.txt", in: "/s"), fakeItem("2.txt", in: "/s")]
        XCTAssertThrowsError(
            try engine.performMove(items, to: TCPath("/d"), srcSource: b, dstSource: b)
        )
        // 正向两项 + 一次回滚 = 3 次 move。
        XCTAssertEqual(b.moveCalls.count, 3, "actual: \(b.moveCalls)")
        XCTAssertEqual(b.moveCalls[0], Pair(a: "/s/1.txt", b: "/d/1.txt"))
        XCTAssertEqual(b.moveCalls[1], Pair(a: "/s/2.txt", b: "/d/2.txt"))
        // 回滚：第一项从 dst 移回 src（方向相反）。
        XCTAssertEqual(b.moveCalls[2], Pair(a: "/d/1.txt", b: "/s/1.txt"))
    }

    // MARK: - 跨源走流式

    func testCrossSourceCopyStreams() throws {
        a.readerChunks = [Data("hello".utf8), Data(" world".utf8)]
        _ = try engine.performCopy([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b)
        XCTAssertEqual(a.openReaders, ["/s/f.txt"])
        XCTAssertEqual(b.streamWrites.count, 1)
        XCTAssertEqual(b.streamWrites[0].data, Data("hello world".utf8))
        XCTAssertTrue(a.copyCalls.isEmpty)
        XCTAssertTrue(b.copyCalls.isEmpty)
    }

    func testCrossSourceMoveStreamsAndDeletesSource() throws {
        a.readerChunks = [Data("x".utf8)]
        _ = try engine.performMove([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b)
        XCTAssertEqual(b.streamWrites.count, 1)
        XCTAssertEqual(a.removeCalls, ["/s/f.txt"])
        XCTAssertTrue(a.moveCalls.isEmpty)
    }

    func testCrossSourceMoveSourceDeleteFailureWarnsNotThrows() throws {
        a.readerChunks = [Data("x".utf8)]
        a.removeError = TCError.unknown("disk full")
        // Plan B：内核只产**结构化原料**（残留文件名 + 原始 TCError），
        // 成品警告句由 AppKit 边界（持 L10n）组装，内核零中文。
        var warnings: [(name: String, error: TCError)] = []
        XCTAssertNoThrow(try engine.performMove([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                                srcSource: a, dstSource: b,
                                                onWarning: { warnings.append(($0, $1)) }))
        XCTAssertEqual(warnings.count, 1)
        XCTAssertEqual(warnings[0].name, "f.txt")
        XCTAssertEqual(warnings[0].error, .unknown("disk full"))
    }

    // MARK: - 跨源目录明确报错（C1：目录不得静默当空文件流过去）

    private func fakeDir(_ name: String, in dir: String) -> FileItem {
        FileItem(id: dir + "/" + name, path: TCPath(dir + "/" + name),
                 name: name, isDirectory: true, size: 0,
                 modificationDate: .distantPast, isHidden: false,
                 isReadOnly: false, isExecutable: true)
    }

    func testCrossSourceDirectoryCopyThrowsExplicitError() throws {
        XCTAssertThrowsError(
            try engine.performCopy([fakeDir("dir", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b)
        ) {
            // Plan B T3：语义 case + payload（翻转≠弱化——精确 case 取代 m.contains("目录")）。
            XCTAssertEqual(asTCError($0), .crossSourceDir("dir"))
        }
        XCTAssertTrue(a.openReaders.isEmpty, "目录不得进流式读")
        XCTAssertTrue(b.streamWrites.isEmpty)
    }

    func testCrossSourceDirectoryMoveThrowsBeforeStreamingDir() throws {
        a.readerChunks = [Data("x".utf8)]
        let items = [fakeItem("1.txt", in: "/s"), fakeDir("dir", in: "/s")]
        XCTAssertThrowsError(
            try engine.performMove(items, to: TCPath("/d"), srcSource: a, dstSource: b)
        )
        XCTAssertEqual(b.streamWrites.count, 1, "仅文件被流式传输")
        XCTAssertEqual(a.removeCalls, ["/s/1.txt"])
        XCTAssertFalse(a.removeCalls.contains("/s/dir"), "目录不得被流式/删除")
    }

    // MARK: - 冲突调用序（同源）

    func testConflictOverwriteAllSequence() throws {
        a.statTable["/d/a.txt"] = fakeItem("a.txt", in: "/d")
        a.statTable["/d/b.txt"] = fakeItem("b.txt", in: "/d")
        var promptCount = 0
        _ = try engine.performCopy([fakeItem("a.txt", in: "/s"), fakeItem("b.txt", in: "/s")],
                                   to: TCPath("/d"), srcSource: a, dstSource: a,
                                   prompt: { _, _ in promptCount += 1; return .overwriteAll })
        XCTAssertEqual(promptCount, 1)              // 第二次起 overwriteAll 生效不再询问
        XCTAssertEqual(a.removeCalls, ["/d/a.txt", "/d/b.txt"])
        XCTAssertEqual(a.copyCalls.count, 2)
    }

    func testConflictSkipAllSequence() throws {
        a.statTable["/d/a.txt"] = fakeItem("a.txt", in: "/d")
        a.statTable["/d/b.txt"] = fakeItem("b.txt", in: "/d")
        var promptCount = 0
        _ = try engine.performCopy([fakeItem("a.txt", in: "/s"), fakeItem("b.txt", in: "/s")],
                                   to: TCPath("/d"), srcSource: a, dstSource: a,
                                   prompt: { _, _ in promptCount += 1; return .skipAll })
        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(a.copyCalls.isEmpty)
        XCTAssertTrue(a.removeCalls.isEmpty)
    }

    func testConflictCancelThrows() throws {
        a.statTable["/d/a.txt"] = fakeItem("a.txt", in: "/d")
        XCTAssertThrowsError(
            try engine.performCopy([fakeItem("a.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: a,
                                   prompt: { _, _ in .cancel })
        ) { XCTAssertEqual($0 as? TCError, .cancelled) }
    }

    // MARK: - rename / mkdir 走源

    func testRenameGoesToSource() throws {
        _ = try engine.performRename(fakeItem("old.txt", in: "/s"), to: "new.txt", source: b)
        XCTAssertEqual(b.renameCalls, [Pair(a: "/s/old.txt", b: "/s/new.txt")])
        XCTAssertTrue(b.statCalls.contains("/s/new.txt"))   // 先查存在
    }

    func testRenameNameCollisionThrows() throws {
        b.statTable["/s/new.txt"] = fakeItem("new.txt", in: "/s")
        XCTAssertThrowsError(
            try engine.performRename(fakeItem("old.txt", in: "/s"), to: "new.txt", source: b)
        )
    }

    func testMakeDirectoryGoesToSource() throws {
        let p = try engine.performMakeDirectory("nd", in: TCPath("/s"), source: b)
        XCTAssertEqual(b.mkdirCalls, ["/s/nd"])
        XCTAssertEqual(p.pathString, "/s/nd")
    }

    /// Plan B T3：同名目录已存在 → 语义 case `.dirExists(名)`（此前是 unknown("目录已存在：X") 中文串）。
    func testMakeDirectoryExistingThrowsDirExists() throws {
        b.statTable["/s/nd"] = fakeDir("nd", in: "/s")
        XCTAssertThrowsError(
            try engine.performMakeDirectory("nd", in: TCPath("/s"), source: b)
        ) { XCTAssertEqual($0 as? TCError, .dirExists("nd")) }
        XCTAssertTrue(b.mkdirCalls.isEmpty, "已存在不得再 mkdir")
    }

    // MARK: - 直接删除（远端无废纸篓路径）

    func testDeleteGoesToSourceRecursive() throws {
        let items = [fakeItem("a.txt", in: "/s"), fakeItem("d1", in: "/s")]
        try engine.performDelete(items, source: b)
        XCTAssertEqual(b.removeCalls, ["/s/a.txt", "/s/d1"])
    }

    func testDeleteSingleFailureStillDeletesRestThenThrows() throws {
        // 第二项失败：第一项仍被删，最后抛首个错误（尽力删完语义）。
        b.removeError = TCError.permissionDenied("locked")
        b.removeFailWhen = "/s/locked.txt"
        let items = [fakeItem("ok.txt", in: "/s"), fakeItem("locked.txt", in: "/s")]
        XCTAssertThrowsError(try engine.performDelete(items, source: b)) {
            XCTAssertEqual($0 as? TCError, .permissionDenied("locked"))
        }
        XCTAssertEqual(b.removeCalls, ["/s/ok.txt", "/s/locked.txt"])   // 两项都尝试删
    }

    // MARK: - 字节进度（跨源流式独有）

    private func sizedItem(_ name: String, in dir: String, size: Int64) -> FileItem {
        FileItem(id: dir + "/" + name, path: TCPath(dir + "/" + name),
                 name: name, isDirectory: false, size: size,
                 modificationDate: .distantPast, isHidden: false,
                 isReadOnly: false, isExecutable: false)
    }

    /// 逐 chunk 精确序列（钉死不变量：跨源字节进度在 reader 闭包内累加）。
    /// 变异：去掉累加 / 累加 writer 返回值 → 序列红。
    func testByteProgressExactSequence() throws {
        a.statTable["/s/f.txt"] = sizedItem("f.txt", in: "/s", size: 11)
        a.readerChunks = [Data([0xAA]), Data([0xBB]), Data([0xCC])]
        var seen: [String] = []
        _ = try engine.performCopy([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b,
                                   byteProgress: { seen.append("\($0)/\($1)") })
        XCTAssertEqual(seen, ["1/11", "2/11", "3/11"])
    }

    /// stat 拿不到大小（totalBytes==0）→ 宁缺毋假，不报字节。
    /// 变异：删掉 totalBytes>0 守卫 → 本条红（出现 (n,0) 假进度）。
    func testByteProgressSilentWhenSizeUnknown() throws {
        a.readerChunks = [Data("hello".utf8)]
        var seen: [String] = []
        _ = try engine.performCopy([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b,
                                   byteProgress: { seen.append("\($0)/\($1)") })
        XCTAssertTrue(seen.isEmpty, "total=0 不得报字节进度：\(seen)")
    }

    /// 同源 copyItem（服务器端 cp / 本地 fm）是黑盒 → 不触发 byteProgress。
    /// 变异：给同源分支加假 byteProgress → 本条红。
    func testByteProgressNotFiredOnSameSourceCopy() throws {
        a.readerChunks = [Data("x".utf8)]
        var seen = 0
        _ = try engine.performCopy([fakeItem("a.txt", in: "/d")], to: TCPath("/d"),
                                   srcSource: a, dstSource: a,
                                   byteProgress: { _, _ in seen += 1 })
        XCTAssertEqual(a.copyCalls.count, 1)
        XCTAssertEqual(seen, 0)
    }

    // MARK: - 取消（CancelFlag）

    /// 文件边界取消：置位后第一项都不做（IO 全零）。
    /// 变异：去掉循环入口检查 → copyCalls/streamWrites 非空红。
    func testCancelBeforeFirstFileDoesNoIO() throws {
        let flag = CancelFlag()
        flag.cancel()
        XCTAssertThrowsError(
            try engine.performCopy([fakeItem("f.txt", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b, cancel: flag)
        ) { XCTAssertEqual($0 as? TCError, .cancelled) }
        XCTAssertTrue(a.copyCalls.isEmpty && a.openReaders.isEmpty && b.streamWrites.isEmpty)
    }

    /// 多文件中途取消：第二项开始边界生效（第一项完成，后续零 IO）。
    /// 变异：检查点挪到循环尾 → 两项都被执行红。
    func testCancelTakesEffectAtNextFileBoundary() throws {
        a.statTable["/s/1.txt"] = fakeItem("1.txt", in: "/s")   // 无 dst → 无冲突删除
        let flag = CancelFlag()
        var progressCount = 0
        XCTAssertThrowsError(
            try engine.performCopy([fakeItem("1.txt", in: "/s"), fakeItem("2.txt", in: "/s")],
                                   to: TCPath("/d"), srcSource: a, dstSource: a,
                                   progress: { _, _ in
                                       progressCount += 1
                                       if progressCount == 1 { flag.cancel() }
                                   },
                                   cancel: flag)
        ) { XCTAssertEqual($0 as? TCError, .cancelled) }
        XCTAssertEqual(a.copyCalls.map(\.a), ["/s/1.txt"], "第二项不得开工")
    }

    /// pump 块边界取消：byteProgress 回调里置位（模拟 UI 线程），流在下一次拉块时中止；
    /// streamWrite 被中止（未 append 完整记录），后续 chunk 未读。
    /// 变异：去掉 write 闭包里的 cancel 检查 → 全量读完后正常返回，红。
    func testCancelMidStreamStopsAtChunkBoundary() throws {
        a.statTable["/s/big.bin"] = sizedItem("big.bin", in: "/s", size: 30)
        a.readerChunks = [Data("aaaaaaaaaa".utf8), Data("bbbbbbbbbb".utf8), Data("cccccccccc".utf8)]
        let flag = CancelFlag()
        var chunksSeen = 0
        XCTAssertThrowsError(
            try engine.performCopy([fakeItem("big.bin", in: "/s")], to: TCPath("/d"),
                                   srcSource: a, dstSource: b,
                                   byteProgress: { _, _ in
                                       chunksSeen += 1
                                       if chunksSeen == 1 { flag.cancel() }
                                   },
                                   cancel: flag)
        ) { XCTAssertEqual($0 as? TCError, .cancelled) }
        XCTAssertEqual(chunksSeen, 1, "第二块不得再进进度回调")
        XCTAssertTrue(b.streamWrites.isEmpty, "中止的写不得落成完整记录")
    }

    /// move 文件边界取消：第一项 move 完成后置位，第二项入口检查抛 .cancelled，
    /// 且**已 move 的第一项回滚回源目录**（取消检查必须在 do 内才走 catch 回滚路径）。
    /// 变异：检查挪到 do 外（裸 throw）→ 不回滚，moveCalls==1 红。
    func testCancelInMoveRollsBackCompletedMoves() throws {
        let flag = CancelFlag()
        let items = [fakeItem("1.txt", in: "/s"), fakeItem("2.txt", in: "/s")]
        XCTAssertThrowsError(
            try engine.performMove(items, to: TCPath("/d"), srcSource: b, dstSource: b,
                                   progress: { _, _ in flag.cancel() },   // 第一项完成即取消
                                   cancel: flag)
        ) { XCTAssertEqual($0 as? TCError, .cancelled) }
        XCTAssertEqual(b.moveCalls.count, 2, "一次正向 + 一次回滚")
        XCTAssertEqual(b.moveCalls[0], Pair(a: "/s/1.txt", b: "/d/1.txt"))
        XCTAssertEqual(b.moveCalls[1], Pair(a: "/d/1.txt", b: "/s/1.txt"))
    }
}
