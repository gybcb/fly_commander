import XCTest
@testable import FlyCommander
import TCCore

/// T2：SessionRecorder 一次性 degraded 语义 + SessionPolicy 真值表。
final class SessionRecordingTests: XCTestCase {
    private func startup(resolved: String, candidate: String?) -> SessionRecorder.SideStartup {
        SessionRecorder.SideStartup(resolved: resolved, candidate: candidate)
    }

    func testRemoteNeverRecorded() {
        let r = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: nil)])
        XCTAssertNil(r.valueToRecord(side: .left, current: "/a", isRemote: true),
                     "远端串永不写入（该侧下次回落默认目录）")
        XCTAssertNil(r.valueToRecord(side: .left, current: nil, isRemote: true))
    }

    func testNoStartupRecordsCurrent() {
        let r = SessionRecorder(startups: [:])
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/x", isRemote: false), "/x")
        XCTAssertNil(r.valueToRecord(side: .left, current: nil, isRemote: false))
    }

    func testNonDegradedRecordsCurrent() {
        let r = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: "/a")])
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a")
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a/b", isRemote: false), "/a/b")
    }

    /// 候选 /a/b/c 不可用被上溯到 /a 启动；用户未离开 → 持续写回原候选，不被祖先覆盖。
    func testDegradedStayingOnAncestorKeepsOriginalCandidate() {
        let r = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: "/a/b/c")])
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b/c")
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b/c",
                       "多次记录保持原候选（幂等）")
    }

    /// 一次性语义：离开上溯落点即失效，再回到同一祖先也只记当前值。
    func testDegradedClearedOnceUserLeavesAndDoesNotComeBack() {
        let r = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: "/a/b/c")])
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b/c")
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a/other", isRemote: false), "/a/other")
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a",
                       "回到同一祖先不得再回吐旧候选（degraded 已清除）")
    }

    /// 候选侧（快照里手改/旧版遗留的垃圾串）也必须被拦下：degraded 回吐分支原先会把远端串
    /// 原样写回，让垃圾永久留在记忆里。非法候选 → 写回当前（上溯落点），垃圾随之自愈。
    func testDegradedWithIllegalCandidateWritesCurrentInstead() {
        for garbage in ["sftp://h:22/a", "smb://s/share/a", "", "   ", "relative/path", "~foo"] {
            let r = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: garbage)])
            XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a",
                           "非法候选不得写回：\(garbage)")
        }
        // 合法候选仍照旧回吐（未被这次收紧误伤），且首尾空白被 trim。
        let ok = SessionRecorder(startups: [.left: startup(resolved: "/a", candidate: " /a/b/c \n")])
        XCTAssertEqual(ok.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b/c")
    }

    func testSidesAreIndependent() {
        let r = SessionRecorder(startups: [
            .left: startup(resolved: "/a", candidate: "/a/b"),
            .right: startup(resolved: "/c", candidate: nil),
        ])
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b")
        XCTAssertEqual(r.valueToRecord(side: .right, current: "/c", isRemote: false), "/c")
        // 右侧变化不影响左侧的 degraded 状态
        XCTAssertEqual(r.valueToRecord(side: .right, current: "/d", isRemote: false), "/d")
        XCTAssertEqual(r.valueToRecord(side: .left, current: "/a", isRemote: false), "/a/b")
    }

    func testRestoreEnabledTruthTable() {
        XCTAssertTrue(SessionPolicy.restoreEnabled(explicitStartPath: nil, argumentDisabled: false))
        XCTAssertFalse(SessionPolicy.restoreEnabled(explicitStartPath: "/x", argumentDisabled: false))
        XCTAssertFalse(SessionPolicy.restoreEnabled(explicitStartPath: nil, argumentDisabled: true))
        XCTAssertFalse(SessionPolicy.restoreEnabled(explicitStartPath: "/x", argumentDisabled: true))
    }

    func testRecordingEnabledTruthTable() {
        XCTAssertTrue(SessionPolicy.recordingEnabled(restoreEnabled: true, hasInjectedSnapshot: false))
        XCTAssertFalse(SessionPolicy.recordingEnabled(restoreEnabled: true, hasInjectedSnapshot: true))
        XCTAssertFalse(SessionPolicy.recordingEnabled(restoreEnabled: false, hasInjectedSnapshot: false))
        XCTAssertFalse(SessionPolicy.recordingEnabled(restoreEnabled: false, hasInjectedSnapshot: true))
    }

    /// 快照选用：开关关闭时注入也不看（显式启动目录压过记忆——UI 测试契约）；
    /// 设置了注入就以注入为准，注入解码失败（nil）**绝不回落** stored。
    func testSnapshotToUse() {
        let injected = SessionSnapshot(version: 1, leftPath: "/inj", rightPath: nil, active: "left")
        let stored = SessionSnapshot(version: 1, leftPath: "/sto", rightPath: nil, active: "left")
        XCTAssertEqual(SessionPolicy.snapshotToUse(restoreEnabled: true, hasInjectedSnapshot: true,
                                                   injected: injected, stored: stored), injected,
                       "开关开启且设置了注入 → 用注入")
        XCTAssertNil(SessionPolicy.snapshotToUse(restoreEnabled: true, hasInjectedSnapshot: true,
                                                 injected: nil, stored: stored),
                     "注入存在但解码失败 → 用 fallback，绝不回落 stored（否则坏注入静默恢复真实记忆）")
        XCTAssertEqual(SessionPolicy.snapshotToUse(restoreEnabled: true, hasInjectedSnapshot: false,
                                                   injected: nil, stored: stored), stored,
                       "未设置注入 → 用持久化快照")
        XCTAssertNil(SessionPolicy.snapshotToUse(restoreEnabled: false, hasInjectedSnapshot: true,
                                                 injected: injected, stored: stored),
                     "开关关闭（显式起始目录/参数域禁用）时任何快照都不用")
        XCTAssertNil(SessionPolicy.snapshotToUse(restoreEnabled: true, hasInjectedSnapshot: false,
                                                 injected: nil, stored: nil))
    }

    /// 坏注入（存在但解码失败）→ 既不写回，也不读 stored（隔离契约）。
    func testCorruptInjectionDisablesRecordingAndIgnoresStored() {
        XCTAssertFalse(SessionPolicy.recordingEnabled(restoreEnabled: true, hasInjectedSnapshot: true),
                       "注入存在即关闭写回——哪怕它解不出快照")
        let stored = SessionSnapshot(version: 1, leftPath: "/sto", rightPath: nil, active: "left")
        XCTAssertNil(SessionPolicy.snapshotToUse(restoreEnabled: true, hasInjectedSnapshot: true,
                                                 injected: nil, stored: stored))
    }
}
