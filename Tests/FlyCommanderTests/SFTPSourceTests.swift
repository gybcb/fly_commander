import XCTest
import Foundation
import Traversio
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

    // MARK: - 服务器端对拷（exec cp；本机 sshd 允许 exec → 走真 cp 路径）
    //
    // 每条的可证伪性注在函数内。回退 pump 分支不给专测：需要 ForceCommand 专用
    // sshd 夹具，代价不对称——由 runCp 的 catch→channelGone 结构 + 上方
    // testSameSourceCopy（现跑在 exec 路径上）共同兜底；exec 若整体挂掉本组全红。

    /// 目录递归复制——**回归锚**：旧双句柄 pump 对目录 openFile 必抛错（设计已核实
    /// 同源目录复制在 exec 前就是坏的），exec `cp -a` 修复之。
    /// 变异：去掉 exec 阶段（只留 pump）→ 本条红（copyItem 抛错）。
    func testServerSideCopyDirectoryRecursive() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/ssc_dir"))
        try source.makeDirectory(at: p(base + "/ssc_dir/src"))
        try source.makeDirectory(at: p(base + "/ssc_dir/src/sub"))
        let inner = p(base + "/ssc_dir/src/sub/deep.txt")
        try writeOnce(Data("deep-content".utf8), into: inner)
        try source.copyItem(from: p(base + "/ssc_dir/src"), to: p(base + "/ssc_dir/copy"))
        XCTAssertEqual(try readAll(p(base + "/ssc_dir/copy/sub/deep.txt")), Data("deep-content".utf8),
                       "嵌套内容须随目录整体复制")
        XCTAssertEqual(try source.stat(p(base + "/ssc_dir/copy"))?.isDirectory, true)
        // 源仍在（cp 非 mv）
        XCTAssertNotNil(try source.stat(inner))
    }

    /// 特殊文件名三连——shell 引用的端到端验证（纯函数测的是字符串，这里测真 shell）。
    /// 变异：shellQuote 去单引号 / 漏 `--` → 对应名字红（命令被拆词或路径当 flag）。
    func testServerSideCopySpecialFilenames() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/ssc_names"))
        let payload = Data("special-name-payload".utf8)
        for name in ["hello world.txt", "it's a file.txt", "-rf.txt"] {
            let src = p(base + "/ssc_names/\(name)")
            try writeOnce(payload, into: src)
            try source.copyItem(from: src, to: p(base + "/ssc_names/copy_\(name)"))
            XCTAssertEqual(try readAll(p(base + "/ssc_names/copy_\(name)")), payload,
                           "文件名「\(name)」复制失败 = 引用/转义回归")
        }
    }

    /// cp -a 属性保留（有意语义改进）：可执行位须随复制保留。
    /// 变异：exec 阶段失效退回 pump（openFile+write 不带属性）→ isExecutable 变 false 红。
    func testServerSideCopyPreservesExecutable() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/ssc_perm"))
        // 本机 sshd 直接映射真实文件系统 → 用 FileManager 造 0755 源。
        let real = base + "/ssc_perm/run.sh"
        try "echo hi".write(toFile: real, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: real)
        XCTAssertEqual(try source.stat(p(base + "/ssc_perm/run.sh"))?.isExecutable, true,
                       "夹具自检：源应可执行")
        try source.copyItem(from: p(base + "/ssc_perm/run.sh"), to: p(base + "/ssc_perm/copy.sh"))
        XCTAssertEqual(try source.stat(p(base + "/ssc_perm/copy.sh"))?.isExecutable, true,
                       "cp -a 应保留可执行位（pump 不保留——此断言红说明回退到了 pump）")
    }

    /// 覆盖已存在目标（引擎 resolveConflict 先删后拷的不变量端到端成立）。
    /// 变异：若 dst 未被先删，`cp -a` 对已存在**目录**目标会把 src 拷**进去**
    /// （dst/src 而非 dst）→ readAll(dst) 红。
    func testServerSideCopyOverExistingDirectory() throws {
        let base = server.remoteBase.path
        try source.makeDirectory(at: p(base + "/ssc_over"))
        try source.makeDirectory(at: p(base + "/ssc_over/srcdir"))
        try writeOnce(Data("new".utf8), into: p(base + "/ssc_over/srcdir/f.txt"))
        try source.makeDirectory(at: p(base + "/ssc_over/dstdir"))   // 已存在同名目录
        // 模拟 resolveConflict 的「先删后拷」（引擎路径的语义镜像）。
        try source.removeItem(at: p(base + "/ssc_over/dstdir"))
        try source.copyItem(from: p(base + "/ssc_over/srcdir"), to: p(base + "/ssc_over/dstdir"))
        XCTAssertEqual(try readAll(p(base + "/ssc_over/dstdir/f.txt")), Data("new".utf8),
                       "覆盖式目录复制：目标须整体替换而非嵌入")
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
            let tc = error as? TCError
            // Plan B T4：语义 case（此前是 permissionDenied + 泛化中文 payload）。
            guard case .authRejected(let method)? = tc else {
                return XCTFail("期望 authRejected，实际 \(String(describing: tc))")
            }
            XCTAssertFalse(method.isEmpty, "authRejected 应携带被拒方法名")
            // 中英双断边界显示（payload=方法名，非泛化中文串）。
            XCTAssertEqual(tc.map(tcErrorDisplay), "Authentication rejected (\(method))")
            L10n.current = .zh
            defer { L10n.current = .en }
            XCTAssertEqual(tc.map(tcErrorDisplay), "认证被拒绝（\(method)）")
        }
    }

    /// 缺失文件 → notFound 携真实远端路径（此前塞泛化占位"远端路径"）。
    func testMissingFileCarriesRealPathInTCError() throws {
        let base = server.remoteBase.path
        let missing = base + "/no_such_\(UUID().uuidString).txt"
        XCTAssertThrowsError(try source.openReader(p(missing))) { error in
            let tc = error as? TCError
            guard case .notFound(let path)? = tc else {
                return XCTFail("期望 notFound，实际 \(String(describing: tc))")
            }
            XCTAssertEqual(path, missing, "notFound 应携真实远端路径而非泛化占位")
            XCTAssertEqual(tc.map(tcErrorDisplay), "Not found: \(missing)")
            L10n.current = .zh
            defer { L10n.current = .en }
            XCTAssertEqual(tc.map(tcErrorDisplay), "找不到：\(missing)")
        }
    }

    func testOpenReaderMissingFileThrows() throws {
        XCTAssertThrowsError(try source.openReader(p("/no/such/\(UUID().uuidString)")))
    }
}

/// 纯路径映射单测（不依赖 sshd）：远端名字含空格必须保持远端路由并往返一致。
/// 曾因 TCPath("sftp://…\(path)") 裸拼在空格处 URL(string:)==nil 回落本地分支，
/// 导致复制/移动/删除静默路由到不存在的本地路径。
final class SFTPPathMappingTests: XCTestCase {
    private let attrs = SSHSFTPFileAttributes(flags: 0, size: 5, userID: nil, groupID: nil,
                                              permissions: nil, accessTime: nil,
                                              modificationTime: 0, extensions: [])
    private let cfg = SFTPConnectionConfig(host: "h", port: 22, username: "u",
                                           auth: .password("p"))

    func testTCPathWithSpacesStaysRemoteAndRoundTrips() {
        let p = SFTPSource.tcPath(host: "h", port: 22, remotePath: "/home/My Docs/a b.txt")
        XCTAssertTrue(p.isRemote, "含空格不得回落本地分支")
        XCTAssertEqual(p.pathString, "/home/My Docs/a b.txt")
        XCTAssertEqual(p.url.host, "h")
        XCTAssertEqual(p.url.port, 22)
    }

    func testTCPathRootAndPlainPath() {
        XCTAssertTrue(SFTPSource.tcPath(host: "h", port: 22, remotePath: "/").isRemote)
        let plain = SFTPSource.tcPath(host: "h", port: 22, remotePath: "/a/b.txt")
        XCTAssertTrue(plain.isRemote)
        XCTAssertEqual(plain.pathString, "/a/b.txt")
    }

    func testMapWithSpaceNameKeepsItemRemote() {
        let item = SFTPSource.map(attrs: attrs, name: "a b.txt",
                                  fullPath: "/home/My Docs/a b.txt", config: cfg)
        XCTAssertTrue(item.path.isRemote)
        XCTAssertEqual(item.path.pathString, "/home/My Docs/a b.txt")
        XCTAssertEqual(item.id, "/home/My Docs/a b.txt")
    }
}

/// 纯映射单测（不依赖 sshd）：`sftpMappedTCError(path:)` 直连。
/// SSHClientError 各 case 里只有 `authenticationRejected` 的关联值全公开可合成
/// （operationFailed/connectionFailed 的 failure struct 无 public init）——故 notFound
/// 携真路径走 e2e（见 testMissingFileCarriesRealPathInTCError），这里锁 authRejected 语义。
final class SFTPErrorMappingTests: XCTestCase {
    func testAuthRejectedMapsToSemanticCase() {
        let err = SSHClientError.authenticationRejected(
            methodName: "password", availableMethods: ["publickey"], partialSuccess: false)
        let tc = err.sftpMappedTCError(path: "/x/y")
        XCTAssertEqual(tc, .authRejected(method: "password"))
        XCTAssertEqual(tc.l10nKey, .errAuthRejected)
        XCTAssertEqual(tc.l10nArgs, ["password"])
        XCTAssertEqual(tc.message, "Authentication rejected (password)")
    }

    func testDefaultAsTCErrorStillPassesThroughMapped() {
        // 非 SSHClientError → 落全局 asTCError（不吞语义）。
        let tc = TCError.busy("/z").sftpMappedTCError()
        XCTAssertEqual(tc, .busy("/z"))
    }
}
