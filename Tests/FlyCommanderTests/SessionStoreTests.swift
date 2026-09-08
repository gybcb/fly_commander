import XCTest
@testable import FlyCommander
import TCCore

/// T2：SessionStore 持久化（独立 UserDefaults suite 隔离，照 ThemeStoreTests）。
final class SessionStoreTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!
    private let key = "session.lastDirectories"

    override func setUp() {
        suiteName = "fly.test.session.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
    }
    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
    }

    private func snap(left: String? = "/l", right: String? = "/r",
                      active: String = "left") -> SessionSnapshot {
        SessionSnapshot(version: 1, leftPath: left, rightPath: right, active: active)
    }

    func testEmptyStoreHasNilSnapshot() {
        XCTAssertNil(SessionStore(defaults: suite).snapshot)
    }

    func testRoundTripThroughSecondStore() {
        XCTAssertTrue(SessionStore(defaults: suite).saveIfChanged(snap(active: "right")))
        XCTAssertEqual(SessionStore(defaults: suite).snapshot, snap(active: "right"),
                       "新实例应从同一 suite 读回同值")
    }

    func testSaveIfChangedTrueOnFirstAndDifferentFalseOnSame() {
        let store = SessionStore(defaults: suite)
        XCTAssertTrue(store.saveIfChanged(snap()), "首次保存应写盘")
        XCTAssertFalse(store.saveIfChanged(snap()), "同值不得重复写盘")
        XCTAssertTrue(store.saveIfChanged(snap(active: "right")), "变化应写盘")
    }

    /// 同值保存必须**一个字节都不写**：外部把键改成哨兵值，若仍写盘必被覆盖。
    func testSaveIfChangedSameValueDoesNotTouchDisk() {
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(snap())
        let sentinel = Data([0x00, 0x01])
        suite.set(sentinel, forKey: key)
        XCTAssertFalse(store.saveIfChanged(snap()))
        XCTAssertEqual(suite.data(forKey: key), sentinel, "同值保存不得写盘")
    }

    /// init 若不用解码结果初始化 lastWritten，新进程首次保存会误判为"变化"。
    func testInitSeedsDedupeFromDecodedSnapshot() {
        SessionStore(defaults: suite).saveIfChanged(snap())
        XCTAssertFalse(SessionStore(defaults: suite).saveIfChanged(snap()))
    }

    func testClearRemovesKeyAndMemory() {
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(snap())
        store.clear()
        XCTAssertNil(suite.data(forKey: key), "clear 应移除持久化键")
        XCTAssertNil(store.snapshot)
        XCTAssertTrue(store.saveIfChanged(snap()), "clear 后同值应视为新值写盘")
    }

    func testCorruptDataDecodesToNilSnapshot() {
        suite.set(Data("not json".utf8), forKey: key)
        XCTAssertNil(SessionStore(defaults: suite).snapshot)
    }

    /// 磁盘上的旧版/残缺 JSON：缺 active、缺 rightPath 也要能用（不整体失败）。
    func testMissingFieldsToleratedFromDisk() {
        suite.set(Data(#"{"leftPath":"/only"}"#.utf8), forKey: key)
        let s = SessionStore(defaults: suite).snapshot
        XCTAssertEqual(s?.leftPath, "/only")
        XCTAssertNil(s?.rightPath)
        XCTAssertEqual(s?.active, "left")
        XCTAssertEqual(s?.version, 1)
    }

    func testDecodeInjected() {
        XCTAssertNil(SessionStore.decodeInjected(nil))
        XCTAssertNil(SessionStore.decodeInjected("not json"))
        let s = SessionStore.decodeInjected(#"{"leftPath":"/inj","active":"right"}"#)
        XCTAssertEqual(s?.leftPath, "/inj")
        XCTAssertEqual(s?.active, "right")
    }
}
