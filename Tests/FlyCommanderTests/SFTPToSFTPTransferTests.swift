import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// SFTP↔SFTP 双服务器互拷 e2e（用户报「两台服务器互拷有问题」）。
/// 既有 CrossSourceTransferE2ETests 只覆盖 本地⇄SFTP；SFTP↔SFTP 是唯一
/// 「dst.streamWrite 锁内 async 块 → 同步闭包 → src.openReader 在另一条连接上
/// 再进 awaitBlocking」的嵌套形状——本地侧是纯同步 IO 从不嵌套，此路从未被测过。
/// 双实例 = 两个独立 SFTPServerFixture（不同端口 → 不同 sourceID → 引擎走跨源泵送）。
/// 环境不满足（无 sshd）自动 skip。
final class SFTPToSFTPTransferTests: XCTestCase {
    private var fixtureA: SFTPServerFixture!
    private var fixtureB: SFTPServerFixture!
    private var serverA: SFTPServerFixture.Live!
    private var serverB: SFTPServerFixture.Live!
    private var sourceA: SFTPSource!
    private var sourceB: SFTPSource!
    private var engine = OperationEngine()

    override func setUpWithError() throws {
        fixtureA = SFTPServerFixture()
        guard let a = fixtureA.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        serverA = a
        fixtureB = SFTPServerFixture()
        guard let b = fixtureB.start() else {
            throw XCTSkip("第二个 sshd 实例起不来（环境守卫）")
        }
        serverB = b
        sourceA = Self.makeSource(serverA)
        sourceB = Self.makeSource(serverB)
        // 前置：sourceID 必须不同（同源会走 cp 快路径，本测试就测不到泵送）。
        XCTAssertNotEqual(sourceA.sourceID, sourceB.sourceID)
    }

    override func tearDown() {
        sourceA?.closeConnection()
        sourceB?.closeConnection()
        sourceA = nil
        sourceB = nil
        fixtureA?.cleanup()
        fixtureB?.cleanup()
        fixtureA = nil
        fixtureB = nil
        serverA = nil
        serverB = nil
    }

    private static func makeSource(_ live: SFTPServerFixture.Live) -> SFTPSource {
        let config = SFTPConnectionConfig(
            host: "127.0.0.1", port: UInt16(live.port), username: live.username,
            auth: .keyFile(path: live.keyPath, passphrase: live.keyPassphrase))
        // 独立 hostKey 存储（UserDefaults 域隔离）——两服务器 host 相同端口不同，
        // 生产 TOFU 键含端口本就无冲突；这里再隔离一层排除 fixture 串扰。
        let store = SFTPHostKeyStore(defaults: UserDefaults(
            suiteName: "fly.s2s.\(UUID().uuidString)")!)
        let src = SFTPSource(config: config, homeDirectory: live.remoteBase.path,
                             hostKeyStore: store)
        return src
    }

    private func root(_ live: SFTPServerFixture.Live) -> String {
        "sftp://127.0.0.1:\(live.port)\(live.remoteBase.path)"
    }

    /// 后台跑传输 + 超时等待：泵送若死锁（嵌套 awaitBlocking 饿死协作线程池），
    /// XCTFail 报「超时未返回」而不是把整个测试进程挂死。
    private func runWithTimeout(_ work: @escaping () throws -> Void,
                                timeout: TimeInterval = 30) throws {
        let box = ErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() }
            catch { box.set(error) }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + timeout), .success,
                       "传输超时未返回（疑似嵌套 awaitBlocking 死锁）")
        if let e = box.takeError() { throw e }
    }

    // MARK: - 目录递归（用户报「目录不可用」+ 后续「传输面板卡在 2%」的 e2e 面）

    /// A 上建 dir/{a.txt, sub/b.txt}（真 sshd 双服务器），performCopy 整棵泵过去：
    /// 结构（目录逐级建）+ 内容（逐字节）+ copy 不动源。
    func testCopyDirectoryBetweenTwoSFTPServers() throws {
        try makeRemoteTree(sourceA, serverA, name: "d1",
                           files: ["a.txt": "AAA", "sub/b.txt": "BBBB"])
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == "d1" })
        XCTAssertTrue(item.isDirectory, "list 必须把 d1 标成目录")

        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }

        let baseB = "\(root(serverB))/d1"
        let topB = try sourceB.listDirectory(TCPath(baseB))
        XCTAssertEqual(Set(topB.map(\.name)), ["a.txt", "sub"])
        let subB = try sourceB.listDirectory(TCPath("\(baseB)/sub"))
        XCTAssertEqual(subB.map(\.name), ["b.txt"])
        XCTAssertEqual(try readAll(sourceB, TCPath("\(baseB)/a.txt")), Data("AAA".utf8))
        XCTAssertEqual(try readAll(sourceB, TCPath("\(baseB)/sub/b.txt")), Data("BBBB".utf8))
        // copy 语义：源树仍在
        XCTAssertNotNil(try sourceA.stat(TCPath("\(root(serverA))/d1/a.txt")))
    }

    /// move 目录：目标收到整棵树 + 源根整体消失（removeItem 递归合同在真 SFTP 上验证）。
    func testMoveDirectoryBetweenTwoSFTPServers() throws {
        try makeRemoteTree(sourceA, serverA, name: "d2",
                           files: ["a.txt": "AAA", "sub/b.txt": "BBBB"])
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == "d2" })

        try runWithTimeout {
            try self.engine.performMove([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }
        XCTAssertEqual(try readAll(sourceB, TCPath("\(root(serverB))/d2/sub/b.txt")),
                       Data("BBBB".utf8))
        XCTAssertNil(try sourceA.stat(TCPath("\(root(serverA))/d2")), "move 后源根必须消失")
    }

    /// 目录递归夹具：makeDirectory 逐级 + streamWrite 塞小文件。
    private func makeRemoteTree(_ source: SFTPSource, _ live: SFTPServerFixture.Live,
                                name: String, files: [String: String]) throws {
        let base = "\(root(live))/\(name)"
        try source.makeDirectory(at: TCPath(base))
        try source.makeDirectory(at: TCPath("\(base)/sub"))
        for (rel, text) in files {
            let data = Data(text.utf8)
            var sent = false
            try source.streamWrite(TCPath("\(base)/\(rel)"), totalBytes: Int64(data.count)) {
                if sent { return Data() }
                sent = true
                return data
            }
        }
    }

    /// e2e 锁 10（真 sshd 跨源目录）：聚合通道端到端合同——帧存在、total = 预扫描
    /// 树和（AAA+BBBB=7）、done 单调、末帧 done==total。修复前无 aggregate 参数。
    func testDirectoryAggregateFramesEndAtPrescanPlan() throws {
        try makeRemoteTree(sourceA, serverA, name: "agg",
                           files: ["a.txt": "AAA", "sub/b.txt": "BBBB"])
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == "agg" })
        var frames: [(Int64, Int64)] = []
        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB,
                                        aggregate: { d, t in frames.append((d, t)) })
        }
        XCTAssertFalse(frames.isEmpty, "真 SFTP 跨源目录必须有聚合帧")
        XCTAssertTrue(frames.allSatisfy { $0.1 == 7 }, "total = 预扫描树和 7，实得 \(frames.map(\.1))")
        let dones = frames.map { $0.0 }
        XCTAssertEqual(dones, dones.sorted(), "done 单调")
        XCTAssertEqual(dones.last, 7, "末帧 done==total")
    }

    /// 整档读回（测试用：小文件一次读完）。
    private func readAll(_ source: SFTPSource, _ path: TCPath) throws -> Data {
        let reader = try source.openReader(path)
        var data = Data()
        while let chunk = try reader(64 * 1024), !chunk.isEmpty { data.append(chunk) }
        return data
    }

    // MARK: - 主锁：A → B 文件复制

    func testCopyFileBetweenTwoSFTPServers() throws {
        let name = "a2b.bin"
        // 700KB：10 个整 64KB 块 + 尾块，覆盖多块泵送。
        let payload = Data((0..<(700 * 1024)).map { UInt8(($0 &* 31) % 256) })
        let srcPath = TCPath("\(root(serverA))/\(name)")
        var sent = false
        try sourceA.streamWrite(srcPath, totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == name })

        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }

        let dstPath = TCPath("\(root(serverB))/\(name)")
        let got = try readAll(sourceB, dstPath)
        XCTAssertEqual(got.count, payload.count, "字节数不符")
        XCTAssertEqual(got, payload, "跨 SFTP 复制必须逐字节一致")
        // copy 语义：源仍在
        XCTAssertNotNil(try sourceA.stat(srcPath))
    }

    // MARK: - B → A 方向

    func testCopyFileBackwards() throws {
        let name = "b2a.bin"
        let payload = Data((0..<200_000).map { UInt8(($0 &* 7) % 256) })
        let srcPath = TCPath("\(root(serverB))/\(name)")
        var sent = false
        try sourceB.streamWrite(srcPath, totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }
        let item = try XCTUnwrap(
            try sourceB.listDirectory(TCPath(root(serverB))).first { $0.name == name })

        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverA)),
                                        srcSource: self.sourceB, dstSource: self.sourceA)
        }
        let got = try readAll(sourceA, TCPath("\(root(serverA))/\(name)"))
        XCTAssertEqual(got, payload)
    }

    // MARK: - 多文件

    func testCopyMultipleFiles() throws {
        var items: [FileItem] = []
        var payloads: [String: Data] = [:]
        for i in 0..<3 {
            let name = "m\(i).bin"
            let payload = Data((0..<(70_000 + i * 1000)).map { UInt8(($0 &+ i) % 256) })
            var sent = false
            try sourceA.streamWrite(TCPath("\(root(serverA))/\(name)"),
                                    totalBytes: Int64(payload.count)) {
                if sent { return Data() }
                sent = true
                return payload
            }
            payloads[name] = payload
        }
        items = try sourceA.listDirectory(TCPath(root(serverA)))
            .filter { payloads.keys.contains($0.name) }
        XCTAssertEqual(items.count, 3)

        try runWithTimeout {
            try self.engine.performCopy(items, to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }
        for (name, payload) in payloads {
            let got = try readAll(sourceB, TCPath("\(root(serverB))/\(name)"))
            XCTAssertEqual(got, payload, "\(name) 内容不符")
        }
    }

    // MARK: - 生产路径：TransferEngine + ConnectionStore 双服务器替身连接
    //
    // 上面三测直调 OperationEngine（无传输替身）。真机走 TransferEngine.run →
    // ConnectionStore.transferSource 为**两端各开第二条连接** → 引擎跨源泵送。
    // 「替身 src → 替身 dst」这条嵌套组合从未被执行过（同 server 两目录用例里
    // dst 恒=src 替身；本地⇄SFTP 只有一端是 SFTP）。此处两个 ConnectionStore
    // 实例（各自独立 sources 表/UserDefaults 域），provider 按 sourceID 路由。

    func testTransferEngineProductionPath() throws {
        let storeA = ConnectionStore(defaults: UserDefaults(
            suiteName: "fly.s2s.storeA.\(UUID().uuidString)")!)
        let storeB = ConnectionStore(defaults: UserDefaults(
            suiteName: "fly.s2s.storeB.\(UUID().uuidString)")!)
        let reqA = ConnectionRequest(host: "127.0.0.1", port: UInt16(serverA.port),
                                     username: serverA.username, auth: .keyFile,
                                     keyPath: serverA.keyPath,
                                     secret: serverA.keyPassphrase, remember: false)
        let reqB = ConnectionRequest(host: "127.0.0.1", port: UInt16(serverB.port),
                                     username: serverB.username, auth: .keyFile,
                                     keyPath: serverB.keyPath,
                                     secret: serverB.keyPassphrase, remember: false)
        let (browseA, _) = try storeA.connect(reqA)
        let (browseB, _) = try storeB.connect(reqB)

        // 前置：替身连接必须能建起来（Keychain 不参与：secret 走内存 config）。
        XCTAssertNotNil(storeA.transferSource(for: browseA.sourceID))
        XCTAssertNotNil(storeB.transferSource(for: browseB.sourceID))

        let payload = Data((0..<300_000).map { UInt8(($0 &* 13) % 256) })
        let srcPath = TCPath("\(root(serverA))/eng.bin")
        var sent = false
        try browseA.streamWrite(srcPath, totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }

        let srcPane = FilePane(id: .left, source: browseA, startPath: TCPath(root(serverA)))
        srcPane.load()
        XCTAssertTrue(srcPane.revealItem(
            id: srcPane.itemByID.first { $0.value.name == "eng.bin" }?.key ?? ""))
        let dstPane = FilePane(id: .right, source: browseB, startPath: TCPath(root(serverB)))
        dstPane.load()

        let transfer = TransferEngine()
        let sem = DispatchSemaphore(value: 0)
        var finalState: OperationState?
        // 生产 provider 形状：按 browse.sourceID 路由到各自 store。
        transfer.transferSourceProvider = { browse in
            let store: ConnectionStore?
            if browse.sourceID == storeA.source(for: browse.sourceID)?.sourceID { store = storeA }
            else if browse.sourceID == storeB.source(for: browse.sourceID)?.sourceID { store = storeB }
            else { store = nil }
            guard let store, let ts = store.transferSource(for: browse.sourceID) else { return nil }
            return (ts, { ts.closeConnection() })
        }
        transfer.state = { s in
            switch s {
            case .done, .failed, .idle: finalState = s; sem.signal()
            default: break
            }
        }
        // runInBackground 保持生产实现（global queue）；仅 onMain 同步化——
        // 测试主线程阻塞在信号量上，默认 onMain 跳主线程会自锁。
        transfer.onMain = { $0() }
        transfer.run(true, srcPane, dstPane, cancel: CancelFlag(), onProgress: nil)
        XCTAssertEqual(sem.wait(timeout: .now() + 30), .success,
                       "TransferEngine 30s 未落终态（卡住）")
        guard case .done = finalState else {
            return XCTFail("期望 .done，实得 \(String(describing: finalState))")
        }

        let got = try readAll(browseB, TCPath("\(root(serverB))/eng.bin"))
        XCTAssertEqual(got, payload, "生产路径必须逐字节一致")
    }
}

/// runWithTimeout 的错误盒（模块内已有泛型 ResultBox，避免同名混淆另起名）。
private final class ErrorBox {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
    func takeError() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
