import XCTest
import Foundation
import Traversio
import TCCore
@testable import FlyCommander

/// rsync 空闲看门狗（2026-10-09 挂死修复）合同锁。
///
/// 背景（真机实证）：对端半死时 `session.nextEvent()` 永久停泊——Traversio 收包路
/// 硬编码不理 cancellation（+SessionRouting.swift:104-107），僵尸 waiter 占死共享
/// 收包闸 → 面板冻结、取消按钮失效、同连接后续操作全卡。修复 = 每圈三竞速
/// （事件 / 空闲定时器 / 取消轮询）+ 超时路整连接作废 + SFTPSource 回收懒重建。
///
/// 分层：
///   1) 纯泵竞速锁（RsyncIdlePump.next，无网络）——超时/取消/健康/抛错/通道关；
///   2) 循环集成锁（真 fixture 连接 + debugPumpFactory 脚本步进器）——超时收口
///      四件套：`.unavailable(rsyncIdleTimeoutCode)` / 路由黄（假绿点防线 B3 同族）
///      / PumpPeaks 计数 / 整连接作废 + 源回收 `_connection = nil`；
///   3) 回归锁：取消上抛不回退、健康序列照常 .handled。
final class RsyncIdleWatchdogTests: XCTestCase {

    // MARK: - helpers

    private func makePeer() -> DirectRsync.Peer {
        DirectRsync.Peer(host: "127.0.0.1", port: 2222, username: "u")
    }
    private func makeItem() -> DirectRsync.ItemTarget {
        DirectRsync.ItemTarget(remotePath: "/tmp/a.bin", dstPath: "/tmp/b.bin", isDirectory: false)
    }

    /// 脚本步进器：按序吐步进；耗尽 = 通道关（.event(nil)）。跨线程（awaitBlocking
    /// 后台 Task 调用）→ 自带锁。
    final class ScriptedStepper: SFTPConnection.RsyncStepper, @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [SFTPConnection.RsyncPumpStep]
        private let error: Error?
        init(_ steps: [SFTPConnection.RsyncPumpStep], error: Error? = nil) {
            self.steps = steps; self.error = error
        }
        func next() async throws -> SFTPConnection.RsyncPumpStep {
            lock.lock()
            if !steps.isEmpty { let s = steps.removeFirst(); lock.unlock(); return s }
            let err = error
            lock.unlock()
            if let err { throw err }
            return .event(nil)
        }
    }

    struct ProbeError: Error, Equatable {}

    /// fixture 连接 + 注入步进器；fixture/captured 生命周期挂源对象（deinit 收尸）。
    private final class FixtureBox {
        let fixture: SFTPServerFixture
        init(_ fixture: SFTPServerFixture) { self.fixture = fixture }
        deinit { fixture.cleanup() }
    }
    /// 步进器工厂捕获的直传结果观测盒（工厂在循环内执行 → 捕获连接）。
    final class Captured: @unchecked Sendable {
        var connection: SFTPConnection?
    }

    private func makeFixtureSource(live: SFTPServerFixture.Live) -> SFTPSource {
        let config = SFTPConnectionConfig(
            host: "127.0.0.1", port: UInt16(live.port), username: live.username,
            auth: .keyFile(path: live.keyPath, passphrase: live.keyPassphrase))
        // 每实例独立 defaults 套件 = 指纹库隔离（先例 SameServerCopyProgressE2ETests:38）。
        let store = SFTPHostKeyStore(defaults: UserDefaults(
            suiteName: "fly.watchdog.\(UUID().uuidString)")!)
        return SFTPSource(config: config, homeDirectory: live.remoteBase.path,
                          hostKeyStore: store)
    }

    // MARK: - 1) 纯泵竞速（鉴别面 = RsyncIdlePump.next 的三 Task 抢盒）

    /// 静默 → 空闲定时器赢（nextEvent 永不返回 = 真机挂死的脚本化等价）。
    func testPumpIdleTimeoutWinsWhenEventSourceSilent() async throws {
        let pump = SFTPConnection.RsyncIdlePump(idleTimeout: 0.2, cancel: nil) {
            try? await Task.sleep(nanoseconds: 10_000_000_000)   // 10s ≫ 阈值：模拟静默
            return nil
        }
        let step = try await pump.next()
        guard case .idleTimedOut = step else {
            return XCTFail("静默必须走超时路，实得 \(step)")
        }
    }

    /// 健康（nextEvent 即时返回）→ 事件赢，定时器/取消轮询被 cancel，不误伤。
    func testPumpEventWinsWhenSourceHealthy() async throws {
        let pump = SFTPConnection.RsyncIdlePump(idleTimeout: 30, cancel: nil) {
            SSHSessionEvent.exitStatus(0)
        }
        // 连续 20 圈（镜像「≤1s 一行的健康 rsync」节奏）——任何一圈误超时即红。
        for i in 0..<20 {
            let step = try await pump.next()
            guard case .event(let ev) = step, case .exitStatus? = ev else {
                return XCTFail("健康源第 \(i) 圈必须事件赢，实得 \(step)")
            }
        }
    }

    /// 静默中取消 → 取消轮询 ≤~100ms 接管（治愈「取消延迟无上界」N4）。
    func testPumpCancelWinsDuringSilence() async throws {
        let flag = CancelFlag()
        let pump = SFTPConnection.RsyncIdlePump(idleTimeout: 30, cancel: flag) {
            try? await Task.sleep(nanoseconds: 60_000_000_000)   // 永不返回
            return nil
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        flag.cancel()
        let started = Date()
        let step = try await pump.next()
        let waited = Date().timeIntervalSince(started)
        guard case .cancelled = step else { return XCTFail("取消必须 ≤阈值接管，实得 \(step)") }
        XCTAssertLessThan(waited, 1.0, "取消响应应在按钮级（实测 \(waited)s）")
    }

    /// nextEvent 真抛 → 泵透传错误（循环 catch 转 channelIssue，既有政策）。
    func testPumpPropagatesEventSourceError() async throws {
        let pump = SFTPConnection.RsyncIdlePump(idleTimeout: 30, cancel: nil) {
            throw ProbeError()
        }
        do {
            _ = try await pump.next()
            XCTFail("必须抛错")
        } catch is ProbeError {
            // 原样透传 = 正确
        }
    }

    /// nil 事件（通道关）→ .event(nil)（循环据此 break → classify）。
    func testPumpRelaysChannelClose() async throws {
        let pump = SFTPConnection.RsyncIdlePump(idleTimeout: 30, cancel: nil) { nil }
        let step = try await pump.next()
        guard case .event(let ev) = step, ev == nil else {
            return XCTFail("通道关必须 .event(nil)，实得 \(step)")
        }
    }

    // MARK: - 2) 循环集成 + 超时收口四件套 + 源回收

    func testIdleTimeoutBailWritesRouteCountsAndRecycles() throws {
        let fixture = SFTPServerFixture()
        guard let live = fixture.start() else { throw XCTSkip("本地 sshd 不可用") }
        let box = FixtureBox(fixture)   // 所有权移交（deinit 收尸）
        let captured = Captured()
        let source = makeFixtureSource(live: live)
        objc_setAssociatedObject(source, "fixtureBox", box, .OBJC_ASSOCIATION_RETAIN)

        source.debugPumpFactory = { conn, _ in
            captured.connection = conn
            return ScriptedStepper([.idleTimedOut])
        }
        let out = try source.runDirectRsync(item: makeItem(), peer: makePeer(),
                                            totalHint: nil, byteProgress: nil,
                                            onFile: nil, cancel: nil)
        XCTAssertEqual(out, .unavailable(DirectOutcome.rsyncIdleTimeoutCode),
                       "超时必须走静默回退 pump（拍板 2026-10-09）")
        XCTAssertTrue(out.isRsyncIdleTimeout)
        XCTAssertNil(source._connection, "超时后源必须弃连接（僵尸闸），pump 走懒重建")

        // 收口三锁在**被弃连接**上验（工厂捕获引用仍可读写——close 幂等标志除外）。
        guard let conn = captured.connection else { return XCTFail("工厂未被调用 = 注入面失效") }
        XCTAssertEqual(conn.lastCopyRoute, .relayed(.channelGone),
                       "假绿点防线（B3 同族）：超时路必须写黄路由，收尾镜像不残留上一条绿")
        XCTAssertEqual(conn.transferPeaks.rsyncIdleTimeoutFiredCount, 1,
                       "看门狗触发必须可观测（PumpPeaks 先例）")
    }

    /// 健康序列回归：exit 0 → .handled + 绿路由，连接原样复用（不误杀）。
    func testHealthyStreamStillEndsHandled() throws {
        let fixture = SFTPServerFixture()
        guard let live = fixture.start() else { throw XCTSkip("本地 sshd 不可用") }
        let box = FixtureBox(fixture)
        let captured = Captured()
        let source = makeFixtureSource(live: live)
        objc_setAssociatedObject(source, "fixtureBox", box, .OBJC_ASSOCIATION_RETAIN)

        source.debugPumpFactory = { conn, _ in
            captured.connection = conn
            return ScriptedStepper([
                .event(.standardOutput(Array(" 45%  12345  0:00:02  (xfr#1)\n".utf8))),
                .event(.exitStatus(0)),
                .event(nil),
            ])
        }
        let out = try source.runDirectRsync(item: makeItem(), peer: makePeer(),
                                            totalHint: nil, byteProgress: nil,
                                            onFile: nil, cancel: nil)
        guard case .handled = out else { return XCTFail("健康路必须 .handled，实得 \(out)") }
        XCTAssertNotNil(source._connection, "健康路连接原样复用")
        XCTAssertEqual(captured.connection?.lastCopyRoute, .directCrossHost)
        XCTAssertEqual(captured.connection?.transferPeaks.rsyncIdleTimeoutFiredCount, 0,
                       "健康路不得记超时账")
    }

    /// 取消路回归：步进器报 .cancelled → 上抛 TCError.cancelled（不回退 pump），
    /// 连接不弃（语义回退 = 服务器没错，僵尸收包者不存在——取消圈 nextEvent 未停泊）。
    func testCancelledStepThrowsCancelledAndKeepsConnection() throws {
        let fixture = SFTPServerFixture()
        guard let live = fixture.start() else { throw XCTSkip("本地 sshd 不可用") }
        let box = FixtureBox(fixture)
        let source = makeFixtureSource(live: live)
        objc_setAssociatedObject(source, "fixtureBox", box, .OBJC_ASSOCIATION_RETAIN)

        source.debugPumpFactory = { _, _ in ScriptedStepper([.cancelled]) }
        do {
            _ = try source.runDirectRsync(item: makeItem(), peer: makePeer(),
                                          totalHint: nil, byteProgress: nil,
                                          onFile: nil, cancel: nil)
            XCTFail("取消必须上抛，不得静默回退")
        } catch let e as TCError {
            guard case .cancelled = e else { return XCTFail("错型：\(e)") }
        }
        XCTAssertNotNil(source._connection, "取消路不弃连接")
    }

    /// 泵抛错路回归：nextEvent 真抛 → channelIssue 政策不变（.unavailable + 黄路由，
    /// **不弃连接**——既有语义，看门狗只加超时路，旧两退路零改动）。
    func testPumpErrorKeepsChannelIssuePolicy() throws {
        let fixture = SFTPServerFixture()
        guard let live = fixture.start() else { throw XCTSkip("本地 sshd 不可用") }
        let box = FixtureBox(fixture)
        let captured = Captured()
        let source = makeFixtureSource(live: live)
        objc_setAssociatedObject(source, "fixtureBox", box, .OBJC_ASSOCIATION_RETAIN)

        source.debugPumpFactory = { conn, _ in
            captured.connection = conn
            return ScriptedStepper([], error: ProbeError())
        }
        let out = try source.runDirectRsync(item: makeItem(), peer: makePeer(),
                                            totalHint: nil, byteProgress: nil,
                                            onFile: nil, cancel: nil)
        guard case .unavailable = out else { return XCTFail("抛错路必须 .unavailable，实得 \(out)") }
        XCTAssertFalse(out.isRsyncIdleTimeout, "抛错路不得冒充看门狗码")
        XCTAssertNotNil(source._connection, "抛错路维持既有语义：不弃连接")
        if case .unavailable(let code) = out {
            XCTAssertEqual(captured.connection?.lastCopyRoute, .relayed(reasonOf(code)))
        }
    }

    /// diagnosticCode 反解（仅测试断言辅助：channelIssue 用 relayReason(for:) 映射 ProbeError
    /// → 默认 channelGone；这里直接按 route 值比对即可，无需反解 → 用恒等）。
    private func reasonOf(_ code: String) -> RelayReason {
        switch code {
        case "needsAuth": return .needsAuth
        case "rsyncMissing": return .rsyncMissing
        case "execRejected": return .execRejected
        case "cpMissing": return .cpMissing
        case "unsupportedFlags": return .unsupportedFlags
        default: return .channelGone
        }
    }
}
