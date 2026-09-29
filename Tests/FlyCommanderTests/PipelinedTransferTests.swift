import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 本机中转 pump 提速（读/写双向流水线 + 256KB 块）的行为锁。
///
/// 鉴别力锁（红先行）：DEBUG 在途峰值计数器 `debugMaxReadInflight` /
/// `debugMaxWriteInflight` —— 旧串行实现恒 1，流水线实现 > 1。
/// 合同回归锁（新旧都该绿）：字节完整性（含 256KB 块边界 ±1）、跨源泵送、
/// 进度帧 done 单调末帧 done==total、取消块边界、写错误透传。
///
/// 环境守卫：双 sshd 夹具（不同端口 → 不同 sourceID → 必走跨源泵送）；
/// 起不来自动 skip。吞吐本身局域网 RTT≈0 测不出 → 真机冒烟定性。
final class PipelinedTransferTests: XCTestCase {
    private var fixtureA: SFTPServerFixture!
    private var fixtureB: SFTPServerFixture!
    private var serverA: SFTPServerFixture.Live!
    private var serverB: SFTPServerFixture.Live!
    private var sourceA: SFTPSource!
    private var sourceB: SFTPSource!
    private var engine = OperationEngine()

    override func setUpWithError() throws {
        fixtureA = SFTPServerFixture()
        guard let a = fixtureA.start() else { throw XCTSkip("本地 sshd 不可用（环境守卫）") }
        serverA = a
        fixtureB = SFTPServerFixture()
        guard let b = fixtureB.start() else { throw XCTSkip("第二个 sshd 实例起不来（环境守卫）") }
        serverB = b
        sourceA = Self.makeSource(serverA)
        sourceB = Self.makeSource(serverB)
        XCTAssertNotEqual(sourceA.sourceID, sourceB.sourceID)
    }

    override func tearDown() {
        sourceA?.closeConnection(); sourceB?.closeConnection()
        sourceA = nil; sourceB = nil
        fixtureA?.cleanup(); fixtureB?.cleanup()
        fixtureA = nil; fixtureB = nil
        serverA = nil; serverB = nil
    }

    private static func makeSource(_ live: SFTPServerFixture.Live) -> SFTPSource {
        let config = SFTPConnectionConfig(
            host: "127.0.0.1", port: UInt16(live.port), username: live.username,
            auth: .keyFile(path: live.keyPath, passphrase: live.keyPassphrase))
        let store = SFTPHostKeyStore(defaults: UserDefaults(
            suiteName: "fly.pump.\(UUID().uuidString)")!)
        return SFTPSource(config: config, homeDirectory: live.remoteBase.path, hostKeyStore: store)
    }

    private func root(_ live: SFTPServerFixture.Live) -> String {
        "sftp://127.0.0.1:\(live.port)\(live.remoteBase.path)"
    }

    private static func payload(_ n: Int, seed: Int) -> Data {
        Data((0..<n).map { UInt8(($0 &* seed) % 256) })
    }

    private func writeWhole(_ source: SFTPSource, _ path: TCPath, _ data: Data) throws {
        var sent = false
        try source.streamWrite(path, totalBytes: Int64(data.count)) {
            if sent { return Data() }
            sent = true
            return data
        }
    }

    private func readAll(_ source: SFTPSource, _ path: TCPath) throws -> Data {
        let reader = try source.openReader(path)
        var data = Data()
        while let chunk = try reader(SFTPTransfer.chunkSize), !chunk.isEmpty { data.append(chunk) }
        return data
    }

    private func runWithTimeout(_ work: @escaping () throws -> Void,
                                timeout: TimeInterval = 60) throws {
        let box = PumpErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do { try work() } catch { box.set(error) }
            sem.signal()
        }
        XCTAssertEqual(sem.wait(timeout: .now() + timeout), .success,
                       "传输超时未返回（疑似流水线死锁）")
        if let e = box.takeError() { throw e }
    }

    // MARK: - 鉴别力锁：在途峰值 > 1（旧串行恒 1）

    /// 4×chunkSize + 尾巴：读窗、写窗峰值必须都 > 1（并发流水线证据）。
    func testPumpKeepsMultipleInflightRequests() throws {
        let name = "peak.bin"
        let payload = Self.payload(4 * SFTPTransfer.chunkSize + 1024, seed: 31)
        try writeWhole(sourceA, TCPath("\(root(serverA))/\(name)"), payload)
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == name })

        sourceA.debugResetTransferPeaks()
        sourceB.debugResetTransferPeaks()
        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }
        XCTAssertGreaterThan(sourceA.debugMaxReadInflight, 1,
                             "读路必须是预取窗口（在途峰值 > 1），实得 \(sourceA.debugMaxReadInflight)")
        XCTAssertGreaterThan(sourceB.debugMaxWriteInflight, 1,
                             "写路必须是并发窗口（在途峰值 > 1），实得 \(sourceB.debugMaxWriteInflight)")
    }

    // MARK: - 完整性（块边界 ±1）

    func testByteIntegrityAcrossChunkBoundaries() throws {
        let sizes = [SFTPTransfer.chunkSize - 1, SFTPTransfer.chunkSize,
                     SFTPTransfer.chunkSize + 1, 3 * SFTPTransfer.chunkSize]
        var names: [String] = []
        var payloads: [String: Data] = [:]
        for (i, n) in sizes.enumerated() {
            let name = "edge\(i).bin"
            names.append(name)
            let p = Self.payload(n, seed: i &+ 17)
            payloads[name] = p
            try writeWhole(sourceA, TCPath("\(root(serverA))/\(name)"), p)
        }
        let items = try sourceA.listDirectory(TCPath(root(serverA)))
            .filter { payloads.keys.contains($0.name) }
        XCTAssertEqual(items.count, sizes.count)

        try runWithTimeout {
            try self.engine.performCopy(items, to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB)
        }
        for name in names {
            let got = try readAll(sourceB, TCPath("\(root(serverB))/\(name)"))
            XCTAssertEqual(got, payloads[name], "\(name) 跨源泵送必须逐字节一致")
        }
    }

    // MARK: - 进度帧 done 单调、末帧 done == total

    func testByteProgressMonotonicAndFinalFull() throws {
        let name = "prog.bin"
        let payload = Self.payload(3 * SFTPTransfer.chunkSize + 4096, seed: 5)
        try writeWhole(sourceA, TCPath("\(root(serverA))/\(name)"), payload)
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == name })

        let frames = PumpFrameBox()
        try runWithTimeout {
            try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                        srcSource: self.sourceA, dstSource: self.sourceB,
                                        byteProgress: { done, total in frames.add(done, total) })
        }
        let all = frames.snapshot()
        XCTAssertFalse(all.isEmpty, "必须有字节进度帧")
        let total = all[0].total
        XCTAssertGreaterThan(total, 0)
        var lastDone: Int64 = -1
        for f in all {
            XCTAssertEqual(f.total, total, "同一文件 total 恒定")
            XCTAssertGreaterThanOrEqual(f.done, lastDone, "done 必须单调不减")
            lastDone = f.done
        }
        XCTAssertEqual(all.last?.done, total, "末帧 done 必须 == total")
    }

    // MARK: - 取消（块边界抛 .cancelled，不静默截断）

    func testCancelThrowsCancelledNoTruncation() throws {
        let name = "cancel.bin"
        let payload = Self.payload(8 * SFTPTransfer.chunkSize, seed: 11)
        try writeWhole(sourceA, TCPath("\(root(serverA))/\(name)"), payload)
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == name })

        let cancel = CancelFlag()
        let frames = PumpFrameBox()
        var thrown: Error?
        // 第 2 帧出现时置取消 → 块边界抛错（取消延迟上界 = 一个窗口）。
        try runWithTimeout {
            do {
                try self.engine.performCopy([item], to: TCPath(self.root(self.serverB)),
                                            srcSource: self.sourceA, dstSource: self.sourceB,
                                            byteProgress: { done, total in
                    frames.add(done, total)
                    if frames.count >= 2 { cancel.cancel() }
                }, cancel: cancel)
            } catch { thrown = error }
        }
        guard case TCError.cancelled? = thrown else {
            return XCTFail("取消须抛 .cancelled，实得 \(String(describing: thrown))")
        }
    }

    // MARK: - 写错误透传（写到只读目录 → 原样上抛、句柄不悬漏）

    func testWriteErrorPropagatesFromReadOnlyDir() throws {
        let roDir = serverA.remoteBase.appendingPathComponent("readonly-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: roDir, withIntermediateDirectories: true)
        let name = "big.bin"
        let payload = Self.payload(2 * SFTPTransfer.chunkSize + 1, seed: 23)
        try writeWhole(sourceA, TCPath("\(root(serverA))/\(name)"), payload)
        let item = try XCTUnwrap(
            try sourceA.listDirectory(TCPath(root(serverA))).first { $0.name == name })

        // 目标目录设只读 → streamWrite openFile(create) 失败。
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roDir.path) }

        var thrown: Error?
        try runWithTimeout {
            do {
                try self.engine.performCopy([item],
                                            to: TCPath("sftp://127.0.0.1:\(self.serverB.port)\(roDir.path)"),
                                            srcSource: self.sourceA, dstSource: self.sourceB)
            } catch { thrown = error }
        }
        XCTAssertNotNil(thrown, "写到只读目录必须抛错（不能静默成功/截断）")
    }
}

/// 进度帧收集盒（并发访问，锁保护）。
private final class PumpFrameBox {
    private let lock = NSLock()
    private var frames: [(done: Int64, total: Int64)] = []
    func add(_ done: Int64, _ total: Int64) {
        lock.lock(); frames.append((done, total)); lock.unlock()
    }
    func snapshot() -> [(done: Int64, total: Int64)] {
        lock.lock(); defer { lock.unlock() }; return frames
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
}

private final class PumpErrorBox {
    private let lock = NSLock()
    private var error: Error?
    func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
    func takeError() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
}
