import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 跨服务器直传的**真连接**集成锁（Task 4）。
///
/// 夹具 = 双 SFTPServerFixture（形状抄 SFTPToSFTPTransferTests：双 sshd、TOFU 域
/// 隔离、超时防死锁三件事已在那解决）。A、B **不注入** A→B 信任（各 fixture 只把
/// 自己的应用密钥写进自己的 authorized_keys），所以本文件锁的是**回退路**：
/// 真实 exec 通道在 A 上跑 rsync → A 的 ssh 连 B 被 `-oBatchMode=yes` 立即拒
/// → DirectRsync.classify 判 needsAuth → `.unavailable` → 引擎 pump 完成整批，
/// 面板经 TransferEngine 的 mirrorRoute 看到黄点 `.relayed(.needsAuth)`。
///
/// 正向（信任在场走 `.handled`）e2e 的 spike 结论（实测于本机 macOS 26 / OpenSSH
/// 10.3p1，按 brief Step 1.5 要求记录）：**不可行**，阻塞在信任注入而非二进制缺失
/// （`/usr/bin/rsync`=openrsync proto29 与 `/usr/bin/ssh` 本机都在，exec 通道本身
/// 经既有 ServerSideCopy 用例证明可用）：
/// 1. A 上执行的 `ssh` 连 B 需要 **B 的主机密钥信任 + fixture 私钥身份**。二者都只
///    存在于测试临时目录，而 A 的 ssh 只读真实账户的 `~/.ssh/known_hosts` 与默认
///    `identityfile ~/.ssh/id_*`（`ssh -G` 实测）——注入即写真实 ~/.ssh（brief 明令
///    禁止）。命令构造器（Task 3 冻结）没有 `-oUserKnownHostsFile=`/`-i` 注入口，
///    加它 = 改产品信任模型（TOFU-off）或把临时路径焊进生产命令，越权。
/// 2. 环境注入旁路同样不通：Traversio `openExec(environment:)` 发的 env 需 sshd
///    `AcceptEnv` 放行，系统 `/etc/ssh/sshd_config` 实测无 AcceptEnv → 静默拒收，
///    HOME/XDG 都改不动 A 上 ssh 的取键路径。
/// 正向因此由三层锁覆盖：Task 3 纯函数（命令/分类/进度解析）、Task 1 引擎 fake
/// （路由与字节累计）、Task 2 面板路由渲染。本文件只留回退锁。
/// 环境不满足（无 sshd）自动 skip。
final class DirectConnectionProbeTests: XCTestCase {
    private var fixtureA: SFTPServerFixture!
    private var fixtureB: SFTPServerFixture!
    private var serverA: SFTPServerFixture.Live!
    private var serverB: SFTPServerFixture.Live!
    private var engine = OperationEngine()

    override func setUpWithError() throws {
        fixtureA = SFTPServerFixture()
        guard let a = fixtureA.start() else { throw XCTSkip("本地 sshd 不可用（环境守卫）") }
        serverA = a
        fixtureB = SFTPServerFixture()
        guard let b = fixtureB.start() else { throw XCTSkip("第二个 sshd 实例起不来（环境守卫）") }
        serverB = b
    }

    override func tearDown() {
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
        let store = SFTPHostKeyStore(defaults: UserDefaults(
            suiteName: "fly.direct.\(UUID().uuidString)")!)
        return SFTPSource(config: config, homeDirectory: live.remoteBase.path, hostKeyStore: store)
    }

    private func root(_ live: SFTPServerFixture.Live) -> String {
        "sftp://127.0.0.1:\(live.port)\(live.remoteBase.path)"
    }

    /// 后台跑 + 超时：BatchMode 若失效（A 的 ssh 挂在口令提示上）此处超时红灯，正是变异。
    private func runWithTimeout(_ work: @escaping () throws -> Void,
                                timeout: TimeInterval = 60) throws {
        let box = DirectErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() }
            catch { box.set(error) }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + timeout), .success,
                       "传输超时未返回（BatchMode 未生效或接缝挂起）")
        if let e = box.takeError() { throw e }
    }

    /// 无 A→B 信任：跨服务器复制**目录** = 真实 exec 尝试 → needsAuth → pump 完成整批，
    /// 且面板路由（经 TransferEngine mirrorRoute）为 `.relayed(.needsAuth)`。
    ///
    /// 走生产路 TransferEngine.run（接缝注入 + 双独立传输连接 + mirrorRoute 全在里面），
    /// 断言三点：
    /// ① 目标树逐文件字节一致（回退路把活干完）；
    /// ② 至少一帧**文件级** route == `.relayed(.needsAuth)`（黄点真值；变异=注释掉接缝
    ///    注入 → 接缝零调用 → pump 从不写 route → 全帧 nil → 此断言挂）；
    /// ③ 全程无 route == `.directCrossHost`（无信任时绿点是谎言）。
    func testNoTrustFallsBackToPumpWithNeedsAuthRoute() throws {
        let sourceA = Self.makeSource(serverA)
        let sourceB = Self.makeSource(serverB)
        defer { sourceA.closeConnection(); sourceB.closeConnection() }
        XCTAssertNotEqual(sourceA.sourceID, sourceB.sourceID)

        // A 根下 sub/{a.txt(1KB), deep/b.txt(2KB)}；B 空。
        try writeRemote(sourceA, "\(root(serverA))/sub", "a.txt", Data(repeating: 0x41, count: 1024))
        try writeRemote(sourceA, "\(root(serverA))/sub/deep", "b.txt", Data(repeating: 0x42, count: 2048))
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == "sub" })
        XCTAssertTrue(item.isDirectory)

        // 生产路：两个 ConnectionStore（独立 UserDefaults 域）+ 按 sourceID 路由的 provider
        // （形状抄 SFTPToSFTPTransferTests.testTransferEngineProductionPath）。
        let storeA = ConnectionStore(defaults: UserDefaults(
            suiteName: "fly.direct.storeA.\(UUID().uuidString)")!)
        let storeB = ConnectionStore(defaults: UserDefaults(
            suiteName: "fly.direct.storeB.\(UUID().uuidString)")!)
        let reqA = ConnectionRequest(host: "127.0.0.1", port: UInt16(serverA.port),
                                     username: serverA.username, auth: .keyFile,
                                     keyPath: serverA.keyPath, secret: serverA.keyPassphrase,
                                     remember: false)
        let reqB = ConnectionRequest(host: "127.0.0.1", port: UInt16(serverB.port),
                                     username: serverB.username, auth: .keyFile,
                                     keyPath: serverB.keyPath, secret: serverB.keyPassphrase,
                                     remember: false)
        let (browseA, _) = try storeA.connect(reqA)
        let (browseB, _) = try storeB.connect(reqB)

        let srcPane = FilePane(id: .left, source: browseA, startPath: TCPath(root(serverA)))
        srcPane.load()
        XCTAssertTrue(srcPane.revealItem(
            id: srcPane.itemByID.first { $0.value.name == "sub" }?.key ?? ""))
        let dstPane = FilePane(id: .right, source: browseB, startPath: TCPath(root(serverB)))
        dstPane.load()

        let transfer = TransferEngine()
        transfer.transferSourceProvider = { browse in
            let store: ConnectionStore?
            if browse.sourceID == storeA.source(for: browse.sourceID)?.sourceID { store = storeA }
            else if browse.sourceID == storeB.source(for: browse.sourceID)?.sourceID { store = storeB }
            else { store = nil }
            guard let store, let ts = store.transferSource(for: browse.sourceID) else { return nil }
            return (ts, { ts.closeConnection() })
        }
        let sem = DispatchSemaphore(value: 0)
        var finalState: OperationState?
        let frames = DirectFrameRecorder()
        // onMain 同步化：测试线程阻塞在信号量上，默认跳主线程会自锁（同 S2S 测试）。
        transfer.onMain = { $0() }
        transfer.state = { s in
            switch s {
            case .done, .failed, .idle: finalState = s; sem.signal()
            default: break
            }
        }
        try runWithTimeout {
            transfer.run(true, srcPane, dstPane, cancel: CancelFlag(),
                         onProgress: { frames.append($0) })
        }
        XCTAssertEqual(sem.wait(timeout: .now() + 60), .success, "TransferEngine 未落终态")
        guard case .done = finalState else {
            return XCTFail("期望 .done，实得 \(String(describing: finalState))")
        }

        // ① 回退路完成整批：目标树逐文件字节一致。
        let readB: (String) throws -> Data = { p in
            let reader = try sourceB.openReader(TCPath(p))
            var d = Data()
            while let c = try reader(64 * 1024), !c.isEmpty { d.append(c) }
            return d
        }
        XCTAssertEqual(Set(try sourceB.listDirectory(TCPath("\(root(serverB))/sub")).map(\.name)),
                       ["a.txt", "deep"])
        XCTAssertEqual(try readB("\(root(serverB))/sub/a.txt").count, 1024)
        XCTAssertEqual(try readB("\(root(serverB))/sub/deep/b.txt").count, 2048)

        // ② 黄点真值抵达 UI 帧。
        let routes = frames.all().compactMap(\.route)
        XCTAssertTrue(routes.contains(.relayed(.needsAuth)),
                      "文件级帧必须携 .relayed(.needsAuth)，实得 \(routes)")
        // ③ 无信任不得出现绿点。
        XCTAssertFalse(routes.contains(.directCrossHost), "无信任时直传绿点 = 谎报")
    }

    /// 夹具小工具：在远端目录塞一个文件（makeDirectory + 一次性 streamWrite）。
    private func writeRemote(_ source: SFTPSource, _ dir: String,
                             _ name: String, _ data: Data) throws {
        try source.makeDirectory(at: TCPath(dir))
        var sent = false
        try source.streamWrite(TCPath("\(dir)/\(name)"), totalBytes: Int64(data.count)) {
            if sent { return Data() }
            sent = true
            return data
        }
    }
}

/// 跨线程帧收集盒（onMain 已同步化，仍加锁自保）。
private final class DirectFrameRecorder {
    private let lock = NSLock()
    private var frames: [TransferEngine.TransferProgressInfo] = []
    func append(_ f: TransferEngine.TransferProgressInfo) {
        lock.lock(); frames.append(f); lock.unlock()
    }
    func all() -> [TransferEngine.TransferProgressInfo] {
        lock.lock(); defer { lock.unlock() }; return frames
    }
}

/// runWithTimeout 的错误盒（形状同 SFTPToSFTPTransferTests 的 private ErrorBox）。
private final class DirectErrorBox {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
    func takeError() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
