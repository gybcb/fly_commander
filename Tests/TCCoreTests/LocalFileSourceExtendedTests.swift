import XCTest
import Foundation
@testable import TCCore

/// T2：FileSource 完整文件系统面（stat/copy/move/rename/mkdir/remove/流式读写）。
final class LocalFileSourceExtendedTests: XCTestCase {
    private let src = LocalFileSource()
    private var tmp: URL!
    private var p: TCPath { TCPath(url: tmp) }

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcext_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ name: String, bytes: Int = 10) throws -> TCPath {
        let url = tmp.appendingPathComponent(name)
        try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
        return TCPath(url: url)
    }

    // MARK: - stat

    func testStatFile() throws {
        let f = try makeFile("a.txt", bytes: 42)
        let item = try src.stat(f)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.name, "a.txt")
        XCTAssertFalse(item?.isDirectory ?? true)
        XCTAssertEqual(item?.size, 42)
    }

    func testStatDirectory() throws {
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("d"),
                                                withIntermediateDirectories: false)
        let item = try src.stat(TCPath(url: tmp.appendingPathComponent("d")))
        XCTAssertTrue(item?.isDirectory ?? false)
    }

    func testStatMissingReturnsNil() throws {
        XCTAssertNil(try src.stat(TCPath(url: tmp.appendingPathComponent("nope"))))
    }

    // MARK: - 元操作

    func testCopyItem() throws {
        let f = try makeFile("src.txt", bytes: 100)
        let dst = TCPath(url: tmp.appendingPathComponent("dst.txt"))
        try src.copyItem(from: f, to: dst)
        XCTAssertEqual(try Data(contentsOf: dst.url), try Data(contentsOf: f.url))
        // 源仍在
        XCTAssertNotNil(try src.stat(f))
    }

    func testMoveItemRemovesSource() throws {
        let f = try makeFile("src.txt", bytes: 100)
        let dst = TCPath(url: tmp.appendingPathComponent("dst.txt"))
        try src.moveItem(from: f, to: dst)
        XCTAssertNil(try src.stat(f))
        XCTAssertEqual(try Data(contentsOf: dst.url), Data((0..<100).map { UInt8($0 % 251) }))
    }

    func testRenameItem() throws {
        let f = try makeFile("old.txt", bytes: 10)
        let renamed = TCPath(url: tmp.appendingPathComponent("new.txt"))
        try src.renameItem(at: f, to: renamed)
        XCTAssertNil(try src.stat(f))
        XCTAssertNotNil(try src.stat(renamed))
    }

    func testMakeDirectoryAndRemoveRecursive() throws {
        let dirPath = TCPath(url: tmp.appendingPathComponent("mk"))
        try src.makeDirectory(at: dirPath)
        XCTAssertTrue((try src.stat(dirPath))?.isDirectory ?? false)
        // 已存在 → 报错
        XCTAssertThrowsError(try src.makeDirectory(at: dirPath))
        // 放进内容后删除（非空目录递归）
        let inner = dirPath.joining("inner.txt")
        try Data("x".utf8).write(to: inner.url)
        try src.removeItem(at: dirPath)
        XCTAssertNil(try src.stat(dirPath))
    }

    func testRemoveItemFile() throws {
        let f = try makeFile("gone.txt")
        try src.removeItem(at: f)
        XCTAssertNil(try src.stat(f))
    }

    // MARK: - 流式

    func testOpenReaderStreamsChunks() throws {
        // 200KB 随机内容，远超单块。
        var payload = Data(capacity: 200 * 1024)
        for i in 0..<(200 * 1024) { payload.append(UInt8(truncatingIfNeeded: i * 7919)) }
        let url = tmp.appendingPathComponent("big.bin")
        try payload.write(to: url)
        let reader = try src.openReader(TCPath(url: url))
        var assembled = Data()
        var firstCount = 0
        while let chunk = try reader(64 * 1024) {
            XCTAssertFalse(chunk.isEmpty)
            if firstCount == 0 { firstCount = chunk.count }
            assembled.append(chunk)
        }
        XCTAssertEqual(firstCount, 64 * 1024)         // 首块满块
        XCTAssertEqual(assembled, payload)             // 逐字节一致（200KB 尾块 8192）
    }

    func testStreamWritePullsUntilEmpty() throws {
        let chunks = [Data(repeating: 1, count: 1000),
                      Data(repeating: 2, count: 1000),
                      Data(repeating: 3, count: 500)]
        let dst = TCPath(url: tmp.appendingPathComponent("out.bin"))
        var i = 0
        try src.streamWrite(dst, totalBytes: 2500) {
            defer { i += 1 }
            return i < chunks.count ? chunks[i] : Data()
        }
        XCTAssertEqual(try Data(contentsOf: dst.url),
                       chunks.reduce(into: Data()) { $0.append($1) })
    }

    func testStreamWriteTruncatesExisting() throws {
        let dst = TCPath(url: tmp.appendingPathComponent("trunc.bin"))
        try Data(repeating: 9, count: 100).write(to: dst.url)
        var calls = 0
        try src.streamWrite(dst, totalBytes: 2) {
            calls += 1
            return calls == 1 ? Data("ab".utf8) : Data()   // 第二次起返回空，结束
        }
        XCTAssertEqual(try Data(contentsOf: dst.url), Data("ab".utf8))
    }

    func testPumpReaderToWriterEndToEnd() throws {
        var payload = Data((0..<150_000).map { UInt8(($0 * 31) % 256) })
        let srcURL = tmp.appendingPathComponent("pump_src.bin")
        try payload.write(to: srcURL)
        let dst = TCPath(url: tmp.appendingPathComponent("pump_dst.bin"))
        let reader = try src.openReader(TCPath(url: srcURL))
        try src.streamWrite(dst, totalBytes: Int64(payload.count)) {
            (try? reader(64 * 1024)) ?? Data()
        }
        XCTAssertEqual(try Data(contentsOf: dst.url), payload)
    }

    // MARK: - 标志位

    func testFlags() {
        XCTAssertEqual(src.isRemote, false)
        XCTAssertEqual(src.supportsTransfer, true)
    }
}
