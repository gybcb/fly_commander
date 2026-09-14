import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// e2e：FTPSource 完整 FileSource 面对进程内 MiniFTPServer（真 NWConnection + 真临时目录）。
/// 覆盖：list 映射、RETR 下载逐字节、STOR 上传落盘逐字节、mkdir/remove（递归）、
/// rename、stat 语义、同源 copy 回环、认证被拒映射、无 MLSD 时的 LIST 回退。
///
/// 断言不用时序 sleep：FTPConnection 是同步阻塞的（awaitBlocking），
/// 每个 source 方法返回即代表服务器已完成，无需轮询等待。
final class FTPSourceE2ETests: XCTestCase {
    private var server: MiniFTPServer!
    private var root: URL!
    private var source: FTPSource!
    private var port: UInt16 = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fly-ftp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = MiniFTPServer(root: root)
        port = try server.start()
        source = FTPSource(config: FTPClient.Config(host: "127.0.0.1", port: port,
                                                     username: "user", password: "secret", tls: false))
    }

    override func tearDown() {
        source?.closeConnection()
        source = nil
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func p(_ remote: String) -> TCPath {
        FTPSource.tcPath(host: "127.0.0.1", port: Int(port), remotePath: remote)
    }
    private var base: String { root.standardizedFileURL.path }

    /// 本地泵：按 64KB 块吐，模拟跨源 openReader → streamWrite。
    private func pump(_ data: Data, into dst: TCPath) throws {
        var i = 0
        try source.streamWrite(dst, totalBytes: Int64(data.count)) {
            if i >= data.count { return Data() }
            let end = min(i + 64 * 1024, data.count)
            defer { i = end }
            return data.subdata(in: i..<end)
        }
    }
    private func writeOnce(_ data: Data, into dst: TCPath) throws {
        var sent = false
        try source.streamWrite(dst, totalBytes: Int64(data.count)) {
            if sent { return Data() }
            sent = true
            return data
        }
    }
    private func readAll(_ src: TCPath) throws -> Data {
        let reader = try source.openReader(src)
        var out = Data()
        while let chunk = try reader(64 * 1024) { out.append(chunk) }
        return out
    }

    // MARK: - 登录 / home

    func testResolveHomeIsRootDir() throws {
        XCTAssertEqual(try source.resolveHome(), base)
    }

    /// 登录成功后懒重连语义：closeConnection 后下次操作自动重连并仍可用。
    func testReconnectAfterClose() throws {
        try writeOnce(Data("a".utf8), into: p(base + "/rc.txt"))
        source.closeConnection()
        XCTAssertEqual(try readAll(p(base + "/rc.txt")), Data("a".utf8), "关闭后应懒重连")
    }

    func testWrongPasswordMapsToAuthRejected() throws {
        let bad = FTPSource(config: FTPClient.Config(host: "127.0.0.1", port: port,
                                                     username: "user", password: "nope", tls: false))
        defer { bad.closeConnection() }
        XCTAssertThrowsError(try bad.listDirectory(p(base))) { error in
            guard case .authRejected? = error as? TCError else {
                return XCTFail("期望 authRejected，实际 \(String(describing: error))")
            }
        }
    }

    // MARK: - 列表

    func testListMapping() throws {
        try source.makeDirectory(at: p(base + "/list"))
        let dir = p(base + "/list")
        try writeOnce(Data("hello".utf8), into: dir.joining("a.txt"))
        try writeOnce(Data("abc".utf8), into: dir.joining(".hidden"))
        try source.makeDirectory(at: dir.joining("sub"))

        let items = try source.listDirectory(dir)
        // 目录优先 + localizedStandardCompare（与 LocalFileSource/SFTPSource 一致）
        XCTAssertEqual(items.map(\.name), ["sub", ".hidden", "a.txt"], "实际 \(items.map(\.name))")
        let a = items.first { $0.name == "a.txt" }!
        XCTAssertFalse(a.isDirectory)
        XCTAssertEqual(a.size, 5)
        XCTAssertFalse(a.isHidden)
        let hidden = items.first { $0.name == ".hidden" }!
        XCTAssertTrue(hidden.isHidden)
        let sub = items.first { $0.name == "sub" }!
        XCTAssertTrue(sub.isDirectory)
        XCTAssertEqual(sub.size, 0)
        XCTAssertEqual(a.id, base + "/list/a.txt")
        XCTAssertTrue(a.path.isRemote)
        XCTAssertFalse(items.contains { $0.name == "." || $0.name == ".." })
    }

    /// 含空格目录名的列表往返（远端路由不回落本地）。
    func testListWithSpaceInName() throws {
        try source.makeDirectory(at: p(base + "/My Docs"))
        let dir = p(base + "/My Docs")
        try writeOnce(Data("x".utf8), into: dir.joining("a b.txt"))
        let items = try source.listDirectory(dir)
        XCTAssertEqual(items.map(\.name), ["a b.txt"])
        XCTAssertTrue(items[0].path.isRemote)
        XCTAssertEqual(items[0].path.pathString, base + "/My Docs/a b.txt")
    }

    // MARK: - 读写逐字节

    func testWriteReadRoundTripByteExact() throws {
        // 1.5MB 伪随机（跨多块 + 尾块非整块）
        var payload = Data(capacity: 1_536_000)
        var seed: UInt64 = 0x9e3779b97f4a7c15
        for _ in 0..<1_536_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            payload.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        let f = p(base + "/round.bin")
        try pump(payload, into: f)
        // 服务端落盘逐字节（直接读真实 FS，不经客户端）
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("round.bin")), payload)
        XCTAssertEqual(try readAll(f), payload)
        XCTAssertEqual(try source.stat(f)?.size, Int64(payload.count))
        // 覆盖写截断重建
        try pump(Data("xy".utf8), into: f)
        XCTAssertEqual(try readAll(f), Data("xy".utf8))
    }

    func testRetrMissingFileThrowsNotFound() throws {
        let missing = base + "/no_such_\(UUID().uuidString).txt"
        XCTAssertThrowsError(try source.openReader(p(missing))) { error in
            guard case .notFound(let path)? = error as? TCError else {
                return XCTFail("期望 notFound，实际 \(String(describing: error))")
            }
            XCTAssertEqual(path, missing, "notFound 携真实远端路径")
        }
    }

    // MARK: - 元操作

    func testRename() throws {
        try source.makeDirectory(at: p(base + "/ren"))
        let old = p(base + "/ren/old.txt")
        try writeOnce(Data("z".utf8), into: old)
        try source.renameItem(at: old, to: p(base + "/ren/new.txt"))
        XCTAssertNil(try source.stat(old))
        XCTAssertEqual(try source.stat(p(base + "/ren/new.txt"))?.name, "new.txt")
    }

    func testMakeDirectory() throws {
        let nd = p(base + "/mkdir")
        XCTAssertNil(try source.stat(nd))
        try source.makeDirectory(at: nd)
        XCTAssertEqual(try source.stat(nd)?.isDirectory, true)
    }

    func testRecursiveRemove() throws {
        try source.makeDirectory(at: p(base + "/del"))
        let r = p(base + "/del")
        try source.makeDirectory(at: r.joining("d1"))
        try source.makeDirectory(at: r.joining("d1/d2"))
        try writeOnce(Data("ab".utf8), into: r.joining("f1"))
        try writeOnce(Data("cd".utf8), into: r.joining("d1/f2"))
        try writeOnce(Data("ef".utf8), into: r.joining("d1/d2/f3"))
        XCTAssertNotNil(try source.stat(r))
        try source.removeItem(at: r)
        XCTAssertNil(try source.stat(r), "嵌套目录应被递归删除")
    }

    /// 同源复制 = RETR→STOR 回环，逐字节一致，源仍在。
    func testSameSourceCopy() throws {
        try source.makeDirectory(at: p(base + "/cp"))
        let src = p(base + "/cp/src.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try pump(payload, into: src)
        let dst = p(base + "/cp/dst.bin")
        try source.copyItem(from: src, to: dst)
        XCTAssertEqual(try readAll(dst), payload)
        XCTAssertEqual(try source.stat(src)?.size, Int64(payload.count), "源仍在（cp 非 mv）")
    }

    func testMoveIsRename() throws {
        try source.makeDirectory(at: p(base + "/mv"))
        let src = p(base + "/mv/a.txt")
        try writeOnce(Data("m".utf8), into: src)
        try source.moveItem(from: src, to: p(base + "/mv/b.txt"))
        XCTAssertNil(try source.stat(src))
        XCTAssertEqual(try readAll(p(base + "/mv/b.txt")), Data("m".utf8))
    }

    // MARK: - stat / isDirectory

    func testIsDirectory() throws {
        try source.makeDirectory(at: p(base + "/isdir"))
        XCTAssertTrue(source.isDirectory(p(base + "/isdir")))
        try writeOnce(Data("x".utf8), into: p(base + "/isdir/file.txt"))
        XCTAssertFalse(source.isDirectory(p(base + "/isdir/file.txt")))
    }

    func testStatMissingReturnsNil() throws {
        XCTAssertNil(try source.stat(p(base + "/nope_\(UUID().uuidString)")))
    }

    // MARK: - LIST 回退（服务器无 MLSD）

    func testListFallbackWhenMlsdRefused() throws {
        source.closeConnection(); source = nil
        server.stop()
        // 关掉 MLSD：客户端 LIST 路径 + 服务端 UNIX 列表解析
        server = MiniFTPServer(root: root, advertiseMlsd: false, refuseMlsd: true)
        port = try server.start()
        source = FTPSource(config: FTPClient.Config(host: "127.0.0.1", port: port,
                                                    username: "user", password: "secret", tls: false))
        try source.makeDirectory(at: p(base + "/fb"))
        let dir = p(base + "/fb")
        try writeOnce(Data("hello".utf8), into: dir.joining("a.txt"))
        try source.makeDirectory(at: dir.joining("sub"))
        let items = try source.listDirectory(dir)
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "sub"])
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.size, 5)
        XCTAssertTrue(items.first { $0.name == "sub" }!.isDirectory)
    }
}

/// sourceID / tcPath 纯映射（不依赖服务器）。
final class FTPSourcePathTests: XCTestCase {
    func testSourceIDDefaultPortOmitsIt() {
        XCTAssertEqual(FTPClient.Config(host: "h", port: 21, username: "u", password: nil, tls: false).sourceID,
                       "ftp://h")
        XCTAssertEqual(FTPClient.Config(host: "h", port: 2121, username: "u", password: nil, tls: false).sourceID,
                       "ftp://h:2121")
        XCTAssertEqual(FTPClient.Config(host: "h", port: 990, username: "u", password: nil, tls: true).sourceID,
                       "ftp://h")
    }

    func testTcPathWithSpacesStaysRemote() {
        let p = FTPSource.tcPath(host: "h", port: 21, remotePath: "/home/My Docs/a b.txt")
        XCTAssertTrue(p.isRemote)
        XCTAssertEqual(p.pathString, "/home/My Docs/a b.txt")
        XCTAssertEqual(p.url.host, "h")
        XCTAssertEqual(p.url.port, 21)
    }

    func testTcPathRoot() {
        let p = FTPSource.tcPath(host: "h", port: 21, remotePath: "/")
        XCTAssertTrue(p.isRemote)
    }

    func testParentOf() {
        XCTAssertEqual(FTPSource.parentOf("/a/b/c"), "/a/b")
        XCTAssertEqual(FTPSource.parentOf("/a"), "/")
        XCTAssertNil(FTPSource.parentOf("/"))
    }
}
