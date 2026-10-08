import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 同服务器（两窗格同 sourceID）拷贝的进度与路由色点端到端锁。
///
/// 用户报障 = 「同机双栏拷贝看不到进度条 / 没有绿点黄点」。双层根因：
/// ① 引擎同源 copyItem 路从不产 byteProgress（cp 黑盒）→ 无字节帧；
/// ② frameRoute 读**目标窗格浏览源**的连接、copyFile 写**传输替身**的连接
///   （ConnectionStore.transferSource 每次新建实例 = 两个对象）→ 路由恒 nil。
///
/// 环境守卫：本地 sshd 夹具起不来自动 skip。cp 可走通 = 夹具允许 exec
/// （SFTPServerFixture 非 ForceCommand），故主锁断言绿点。
final class SameServerCopyProgressE2ETests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var source: SFTPSource!
    private var engine = OperationEngine()

    override func setUpWithError() throws {
        fixture = SFTPServerFixture()
        guard let s = fixture.start() else { throw XCTSkip("本地 sshd 不可用（环境守卫）") }
        server = s
        source = Self.makeSource(s)
    }

    override func tearDown() {
        source?.closeConnection(); source = nil
        fixture?.cleanup(); fixture = nil
        server = nil
    }

    private static func makeSource(_ live: SFTPServerFixture.Live) -> SFTPSource {
        let config = SFTPConnectionConfig(
            host: "127.0.0.1", port: UInt16(live.port), username: live.username,
            auth: .keyFile(path: live.keyPath, passphrase: live.keyPassphrase))
        let store = SFTPHostKeyStore(defaults: UserDefaults(
            suiteName: "fly.same.\(UUID().uuidString)")!)
        return SFTPSource(config: config, homeDirectory: live.remoteBase.path, hostKeyStore: store)
    }

    private func root() -> String {
        "sftp://127.0.0.1:\(server.port)\(server.remoteBase.path)"
    }

    private static func payload(_ n: Int, seed: Int) -> Data {
        Data((0..<n).map { UInt8(($0 &* seed) % 256) })
    }

    private func writeWhole(_ path: TCPath, _ data: Data) throws {
        var sent = false
        try source.streamWrite(path, totalBytes: Int64(data.count)) {
            if sent { return Data() }
            sent = true
            return data
        }
    }

    private func readAll(_ path: TCPath) throws -> Data {
        let reader = try source.openReader(path)
        var data = Data()
        while let chunk = try reader(SFTPTransfer.chunkSize), !chunk.isEmpty { data.append(chunk) }
        return data
    }

    private func runWithTimeout(_ work: @escaping () throws -> Void,
                                timeout: TimeInterval = 90) throws {
        let box = SameServerErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() } catch { box.set(error) }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + timeout), .success, "同服务器拷贝超时未返回")
        if let e = box.takeError() { throw e }
    }

    // MARK: - 主锁：文件拷贝有真字节帧 + 路由绿

    /// 16×256KB ≈ 4MB：cp 挂起期间 stat 轮询必须产出 ≥2 个递增字节帧，
    /// 且路由 = .serverSide（绿点全程可见）。旧实现：帧恒 0、路由恒 nil = 双红。
    /// 轮询时序敏感 → 重试 3 次（慢机器 cp 太快/首轮探 total 吞帧属可接受抖动）。
    func testFileCopyEmitsByteFramesAndServerSideRoute() throws {
        let name = "big.bin"
        let data = Self.payload(16 * SFTPTransfer.chunkSize, seed: 41)
        try writeWhole(TCPath("\(root())/\(name)"), data)
        let item = try XCTUnwrap(
            try source.listDirectory(TCPath(root())).first { $0.name == name })

        var lastError: Error?
        for attempt in 1...3 {
            var frames: [(Int64, Int64)] = []
            // cp 只建末级目录：dst 的父目录必须预先存在（已存在 → 吞「已存在」错）。
            try? source.makeDirectory(at: TCPath("\(root())/run\(attempt)"))
            do {
                try runWithTimeout {
                    try self.engine.performCopy([item], to: TCPath("\(self.root())/run\(attempt)"),
                                                srcSource: self.source, dstSource: self.source,
                                                byteProgress: { d, t in frames.append((d, t)) })
                }
            } catch {
                lastError = error
                continue
            }
            lastError = nil
            // 完整性（cp 路语义不变量）。
            let got = try readAll(TCPath("\(root())/run\(attempt)/\(name)"))
            XCTAssertEqual(got, data, "\(name) 服务器端 cp 必须逐字节一致")
            // 鉴别力锁：修复后 cp 期间有轮询帧。
            XCTAssertGreaterThanOrEqual(frames.count, 2,
                "第 \(attempt) 次尝试：cp 执行期必须有 ≥2 个字节帧（旧实现恒 0）")
            let dones = frames.map { $0.0 }
            XCTAssertEqual(dones, dones.sorted(), "done 必须单调不减")
            XCTAssertEqual(frames.last?.1, Int64(data.count), "已定 total 的帧第二参 = 文件大小")
            XCTAssertEqual(source.lastCopyRoute, .serverSide, "cp 成功 = 绿点路由")
            // 轮询计数器鉴别锁（变异证伪落点：删轮询 Task → 恒 0 必红；
            // 局域网 cp 快时轮数可能 =1，>0 即证「cp 执行期确有并发 stat 轮询」）。
            XCTAssertGreaterThan(source.debugCpPollRoundCount, 0,
                "cp 挂起期间必须跑过 stat 轮询（旧实现恒 0）")
            break
        }
        if let e = lastError { throw e }
    }

    // MARK: - 目录拷贝：total 宁缺毋假

    /// 目录树 cp 时目标树不可见 → total 只能从**源**树求和（条目未定 = 0）。
    /// 帧合同锁：一旦出现 total>0，其值必须 == 源树总字节（绝不允许目标 partial 污染）。
    func testDirectoryCopyTotalFromSourceTree() throws {
        let dir = "bigtree"
        try source.makeDirectory(at: TCPath("\(root())/\(dir)"))
        for i in 0..<4 {
            try writeWhole(TCPath("\(root())/\(dir)/f\(i).bin"),
                           Self.payload(2 * SFTPTransfer.chunkSize, seed: 7 &+ i))
        }
        let item = try XCTUnwrap(
            try source.listDirectory(TCPath(root())).first { $0.name == dir })
        let treeTotal = Int64(4 * 2 * SFTPTransfer.chunkSize)
        // cp 不建中间目录（真实流程目标目录必然存在）→ 测试自备父目录。
        try source.makeDirectory(at: TCPath("\(root())/dst"))

        var frames: [(Int64, Int64)] = []
        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath("\(self.root())/dst"),
                                        srcSource: self.source, dstSource: self.source,
                                        byteProgress: { d, t in frames.append((d, t)) })
        }
        // 末帧收尾：cp 完成后必有一帧 done==total==treeTotal（面板拉回 100%）。
        XCTAssertGreaterThanOrEqual(frames.count, 2,
            "目录 cp 期间必须有轮询帧（旧实现恒 0 帧）")
        let known = frames.filter { $0.1 > 0 }
        XCTAssertFalse(known.isEmpty, "至少收尾帧必须报出源树总字节")
        for f in known {
            XCTAssertEqual(f.1, treeTotal,
                "目录帧的 total 只能 = 源树求和（目标 partial 求和 = 撒谎），实得 \(f.1)")
        }
        XCTAssertEqual(known.last?.0, treeTotal, "末帧 done == total")
        XCTAssertEqual(source.lastCopyRoute, .serverSide)
    }

    // MARK: - 取消：cp 自然完成 + 不静默截断

    func testCancelDuringSameServerCopyThrows() throws {
        let name = "cancel.bin"
        try writeWhole(TCPath("\(root())/\(name)"),
                       Self.payload(8 * SFTPTransfer.chunkSize, seed: 5))
        let item = try XCTUnwrap(
            try source.listDirectory(TCPath(root())).first { $0.name == name })
        let cancel = CancelFlag()
        cancel.cancel()   // 条目边界即取消（cp 路无中途 abort = 既有合同，见引擎注）
        XCTAssertThrowsError(try engine.performCopy([item], to: TCPath("\(root())/dst"),
                                                    srcSource: source, dstSource: source,
                                                    cancel: cancel)) { e in
            XCTAssertEqual(e as? TCError, .cancelled)
        }
    }
}

/// 后台错误盒（与 PipelinedTransferTests 同款，该文件里是 private → 本文件自带）。
private final class SameServerErrorBox {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
    func takeError() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
