import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T4 e2e：SFTPSource 完整 FileSource 面对真实 sshd（本地 fixture）。
/// 覆盖：双认证（key 带 passphrase / 错密码）、list 映射、写→读回逐字节、
/// rename/mkdir/remove（递归）、同源 copy、stat 语义、TCError 映射不崩溃。
/// 环境不满足时自动 skip（见 SFTPServerFixture）。
final class SFTPSourceTests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var source: SFTPSource!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "fly.sftpsource.test")!
        defaults.removePersistentDomain(forName: "fly.sftpsource.test")
        fixture = SFTPServerFixture()
        guard let live = fixture.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        server = live
        let config = SFTPConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: server.username,
            auth: .keyFile(path: server.keyPath, passphrase: server.keyPassphrase)
        )
        source = SFTPSource(config: config,
                            homeDirectory: server.remoteBase.path,
                            hostKeyStore: SFTPHostKeyStore(defaults: defaults))
    }

    override func tearDown() {
        source?.closeConnection()
        source = nil
        fixture?.cleanup()
        fixture = nil
        server = nil
    }

    private func p(_ path: String) -> TCPath {
        TCPath("sftp://127.0.0.1:\(server.port)\(path)")
    }

    /// 本地泵数据：按 64KB 块吐出，模拟跨源 openReader → streamWrite。
    private func pump(_ data: Data, into dst: TCPath, totalBytes: Int64? = nil) throws {
        var i = 0
        try source.streamWrite(dst, totalBytes: totalBytes ?? Int64(data.count)) {
            if i >= data.count { return Data() }
            let end = min(i + 64 * 1024, data.count)
            defer { i = end }
            return data.subdata(in: i..<end)
        }
    }

    /// 一次性小写（闭包状态捕获在闭包外，避免死循环）。
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

    // MARK: - 浏览 / 映射

    func testListMapping() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/t4_list"))
        let dir = p(base + "/t4_list")
        try writeOnce(Data("hello".utf8), into: dir.joining("a.txt"))
        try writeOnce(Data("abc".utf8), into: dir.joining(".hidden"))
        try source.makeDirectory(at: dir.joining("sub"))

        let items = try source.listDirectory(dir)
        // 排序规则与 LocalFileSource 一致：localizedStandardCompare（点文件靠后）
        XCTAssertEqual(items.map(\.name), ["sub", ".hidden", "a.txt"],
                       "目录优先 + 名称排序：\(items.map(\.name))")
        let a = items.first { $0.name == "a.txt" }!
        XCTAssertFalse(a.isDirectory)
        XCTAssertEqual(a.size, 5)
        XCTAssertFalse(a.isHidden)
        XCTAssertFalse(a.modificationDate.timeIntervalSinceNow < -3600, "mtime 应接近当前")
        let hidden = items.first { $0.name == ".hidden" }!
        XCTAssertTrue(hidden.isHidden)
        let sub = items.first { $0.name == "sub" }!
        XCTAssertTrue(sub.isDirectory)
        XCTAssertEqual(sub.size, 0)
        XCTAssertTrue(sub.isExecutable)
        // id/path 用远端路径 + sftp URL
        XCTAssertEqual(a.id, base + "/t4_list/a.txt")
        XCTAssertTrue(a.path.isRemote)
        XCTAssertEqual(a.path.url.host, "127.0.0.1")
        // 不含 "."/".."
        XCTAssertFalse(items.contains { $0.name == "." || $0.name == ".." })
    }

    func testStatFileAndMissing() throws {
        let base = server.remoteBase.path
        try writeOnce(Data("1234567".utf8), into: p(base + "/t4_stat.txt"))
        let item = try source.stat(p(base + "/t4_stat.txt"))
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.name, "t4_stat.txt")
        XCTAssertEqual(item?.size, 7)
        XCTAssertFalse(item?.isDirectory ?? true)

        let missing = try source.stat(p(base + "/no_such_file_\(UUID().uuidString)"))
        XCTAssertNil(missing, "不存在 → nil（而非 throw）")
    }

    func testIsDirectory() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/t4_isdir"))
        XCTAssertTrue(source.isDirectory(p(base + "/t4_isdir")))
        XCTAssertFalse(source.isDirectory(p(base + "/t4_isdir/inner.txt")))
    }

    // MARK: - 写 / 读

    func testWriteReadRoundTripByteExact() throws {
        let base = server.remoteBase.path
        // 1.5MB 伪随机数据（跨多个 64KB 块，尾块非整块）
        var payload = Data(capacity: 1_536_000)
        var seed: UInt64 = 0x9e3779b97f4a7c15
        for _ in 0..<1_536_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            payload.append(UInt8(truncatingIfNeeded: seed >> 33))
        }
        let f = p(base + "/t4_round.bin")
        try pump(payload, into: f)
        XCTAssertEqual(try source.stat(f)?.size, Int64(payload.count))
        XCTAssertEqual(try readAll(f), payload, "写→读回逐字节一致")
        // 覆盖写（截断重建）
        let small = Data("xy".utf8)
        try pump(small, into: f, totalBytes: Int64(payload.count))
        XCTAssertEqual(try readAll(f), small)
    }

    // MARK: - 元操作

    func testRename() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/t4_ren"))
        let old = p(base + "/t4_ren/old.txt")
        try writeOnce(Data("z".utf8), into: old)
        try source.renameItem(at: old, to: p(base + "/t4_ren/new.txt"))
        XCTAssertNil(try source.stat(old))
        XCTAssertEqual(try source.stat(p(base + "/t4_ren/new.txt"))?.name, "new.txt")
        // 覆盖同名 → throw
        try source.renameItem(at: p(base + "/t4_ren/new.txt"), to: old)
        XCTAssertThrowsError(try source.renameItem(at: p(base + "/t4_ren/new.txt"), to: old))
    }

    func testMakeDirectory() throws {
        let base = server.remoteBase.path
        let nd = p(base + "/t4_mkdir")
        XCTAssertNil(try source.stat(nd))
        try source.makeDirectory(at: nd)
        XCTAssertEqual(try source.stat(nd)?.isDirectory, true)
        // 已存在 → throw
        XCTAssertThrowsError(try source.makeDirectory(at: nd))
    }

    func testRecursiveRemove() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/t4_del"))
        let root = p(base + "/t4_del")
        try source.makeDirectory(at: root.joining("d1"))
        try source.makeDirectory(at: root.joining("d1/d2"))
        try writeOnce(Data("ab".utf8), into: root.joining("f1"))
        try writeOnce(Data("cd".utf8), into: root.joining("d1/f2"))
        try writeOnce(Data("ef".utf8), into: root.joining("d1/d2/f3"))
        XCTAssertNotNil(try source.stat(root))
        try source.removeItem(at: root)
        XCTAssertNil(try source.stat(root), "嵌套目录应被递归删除")
        // 单文件删除
        let lone = p(base + "/t4_lone.txt")
        try writeOnce(Data("q".utf8), into: lone)
        try source.removeItem(at: lone)
        XCTAssertNil(try source.stat(lone))
    }

    // MARK: - 同源 copy

    func testSameSourceCopy() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/t4_copy"))
        let src = p(base + "/t4_copy/src.bin")
        let payload = Data((0..<200_000).map { UInt8($0 % 251) })
        try pump(payload, into: src)
        let dst = p(base + "/t4_copy/dst.bin")
        try source.copyItem(from: src, to: dst)
        XCTAssertEqual(try readAll(dst), payload, "同源 copy 逐字节一致")
        // 源仍在
        XCTAssertEqual(try source.stat(src)?.size, Int64(payload.count))
        // 同源 move
        let moved = p(base + "/t4_copy/moved.bin")
        try source.moveItem(from: dst, to: moved)
        XCTAssertNil(try source.stat(dst))
        XCTAssertEqual(try readAll(moved), payload)
    }

    // MARK: - 错误映射

    func testWrongPasswordMapsToTCError() throws {
        let badConfig = SFTPConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: server.username,
            auth: .password("definitely-wrong-password")
        )
        let badSource = SFTPSource(config: badConfig,
                                   homeDirectory: server.remoteBase.path,
                                   hostKeyStore: SFTPHostKeyStore(defaults: defaults))
        defer { badSource.closeConnection() }
        XCTAssertThrowsError(try badSource.listDirectory(p("/"))) { error in
            let tc = asTCError(error)
            switch tc {
            case .permissionDenied(let m):
                XCTAssertTrue(m.contains("认证被拒绝"), "应映射为认证拒绝：\(m)")
            default:
                XCTFail("期望 permissionDenied，实际 \(tc)")
            }
        }
    }

    func testOpenReaderMissingFileThrows() throws {
        XCTAssertThrowsError(try source.openReader(p("/no/such/\(UUID().uuidString)")))
    }
}
