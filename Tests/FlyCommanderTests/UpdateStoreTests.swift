import XCTest
@testable import FlyCommander

/// UpdateStore 持久化回归锁。每条带变异证伪注释。
final class UpdateStoreTests: XCTestCase {
    private func fakeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "updatetest_\(UUID().uuidString)")!
    }

    func testLastCheckAndSkippedRoundTrip() {
        let d = fakeDefaults()
        let store = UpdateStore(defaults: d)
        XCTAssertNil(store.lastCheck); XCTAssertNil(store.skippedVersion)
        store.lastCheck = 1_000_000
        store.skippedVersion = "0.0.6"
        // 新实例同 suite 读回（重启不重置）。
        let store2 = UpdateStore(defaults: d)
        XCTAssertEqual(store2.lastCheck, 1_000_000)
        XCTAssertEqual(store2.skippedVersion, "0.0.6")
        store2.skippedVersion = nil
        XCTAssertNil(UpdateStore(defaults: d).skippedVersion, "setter nil = 清空")
        // 变异证伪：getter 键名与 setter 键名写岔 → 读回 nil 红。
    }

    func testTestIsolationSuppressesWrites() {
        let d = fakeDefaults()
        let store = UpdateStore(defaults: d)
        UserDefaults.standard.set(true, forKey: "flyDisableSessionRestore")
        defer { UserDefaults.standard.removeObject(forKey: "flyDisableSessionRestore") }
        store.lastCheck = 123
        store.skippedVersion = "9.9.9"
        // 抑制模式下写被吞：直查 defaults 无值。
        XCTAssertNil(d.object(forKey: "update.lastCheck"))
        XCTAssertNil(d.string(forKey: "update.skippedVersion"))
        // 变异证伪：删 persist 闸（guard 行）→ 两断言红（UI 测试污染用户偏好）。
    }
}
