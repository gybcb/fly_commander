import XCTest
@testable import FlyCommander
import TCCore

final class FakeUpdateFetcher: UpdateFetching {
    enum Behavior { case canned(Data), fail }
    var behavior: Behavior = .fail
    var calls = 0
    func fetch(_ url: URL) throws -> Data {
        calls += 1
        switch behavior {
        case .canned(let d): return d
        case .fail: throw URLError(.cannotConnectToHost)
        }
    }
}

/// UpdateChecker 编排回归锁：决策全注入（假 fetcher/假 clock/hermetic defaults/同步线程），
/// 不碰网络不死锁。每条带变异证伪注释。
final class UpdateCheckerTests: XCTestCase {
    private let manifestJSON = """
    {"version":"9.9.9","dmgURL":"\(UpdateManifest.expectedDmgURL(version: "9.9.9"))","sha256":"\
    \(String(repeating: "a", count: 64))","notes":"big"}
    """
    private let oldJSON = """
    {"version":"0.0.1","dmgURL":"\(UpdateManifest.expectedDmgURL(version: "0.0.1"))","sha256":"\
    \(String(repeating: "b", count: 64))","notes":"old"}
    """

    private func makeChecker(json: String, local: String = "0.0.5",
                             arch: String = UpdateManifest.arm64Key,
                             fetcher: FakeUpdateFetcher? = nil)
        -> (UpdateChecker, FakeUpdateFetcher, UpdateStore, () -> TimeInterval) {
        let d = UserDefaults(suiteName: "cktest_\(UUID().uuidString)")!
        let store = UpdateStore(defaults: d)
        var fakeNow: TimeInterval = 100_000
        let fetch = fetcher ?? FakeUpdateFetcher()
        if fetcher == nil { fetch.behavior = .canned(Data(json.utf8)) }   // 显式注入者自管 behavior
        // arch 显式注入：默认 arm64——fixture 是 arm64 模板，测试必须跨机（Intel 上跑 CI 测试）确定。
        let c = UpdateChecker(fetcher: fetch, store: store, localVersion: local, archKey: arch)
        c.now = { fakeNow }
        // 同步线程注入：后台闭包直调、回调不排 main queue（裸进程无 main runloop）。
        c.runInBackground = { work in work() }
        c.onMain = { work in work() }
        _ = fakeNow   // 保持可变捕获存活
        return (c, fetch, store, { fakeNow })
    }

    func testNewerManifestReportsAvailable() {
        let (c, _, store, now) = makeChecker(json: manifestJSON)
        var outcome: UpdateChecker.Outcome?
        c.check(manual: false) { outcome = $0 }
        if case .available(let m)? = outcome { XCTAssertEqual(m.version, "9.9.9") }
        else { XCTFail("应 available，实为 \(String(describing: outcome))") }
        XCTAssertNotNil(store.lastCheck, "检查发起即记时点")
        XCTAssertEqual(store.lastCheck, now(), "记的是注入时钟值")
    }

    func testOlderManifestUpToDate() {
        let (c, _, _, _) = makeChecker(json: oldJSON)
        var outcome: UpdateChecker.Outcome?
        c.check(manual: true) { outcome = $0 }
        XCTAssertEqual(outcome.map { "\($0)" }, Optional("upToDate"))
    }

    func testFetchFailureAutoPathFailedOutcome() {
        let f = FakeUpdateFetcher()   // behavior 默认 .fail
        let (c, _, store, _) = makeChecker(json: manifestJSON, fetcher: f)
        var outcome: UpdateChecker.Outcome?
        c.check(manual: false) { outcome = $0 }
        XCTAssertEqual(outcome.map { "\($0)" }, Optional("failed"))
        XCTAssertNotNil(store.lastCheck, "失败也计时点——防断网时每分钟重试")
    }

    func testThrottleUnder24hAutoOnly() {
        let (c, fetch, store, nowFn) = makeChecker(json: manifestJSON)
        store.lastCheck = 100_000                       // now()=100_000 → 差 0
        var outcome: UpdateChecker.Outcome?
        c.check(manual: false) { outcome = $0 }
        XCTAssertEqual(outcome.map { "\($0)" }, Optional("throttled"))
        XCTAssertEqual(fetch.calls, 0, "节流命中不发网络请求")
        c.check(manual: true) { outcome = $0 }          // 手动忽略节流
        if case .available? = outcome {} else { XCTFail("manual 应无视节流") }
        XCTAssertEqual(fetch.calls, 1)
        // -1s/+1s 边界：差恰好 24h → 放行。
        store.lastCheck = 100_000 - UpdateChecker.checkInterval
        c.check(manual: false) { outcome = $0 }
        if case .available? = outcome {} else { XCTFail("恰好 24h 应放行") }
        _ = nowFn
        // 变异证伪：节流条件 < 改成 <= → 边界断言翻红。
    }

    func testSkippedVersionSilentAutoManualStillReports() throws {
        let (c, _, store, _) = makeChecker(json: manifestJSON)
        store.skippedVersion = "9.9.9"
        var outcome: UpdateChecker.Outcome?
        c.check(manual: false) { outcome = $0 }
        XCTAssertEqual(outcome.map { "\($0)" }, Optional("skipped"), "跳过版本自动路静默")
        c.check(manual: true) { outcome = $0 }
        if case .available? = outcome {} else { XCTFail("手动路无视跳过") }
    }

    func testInvalidManifestIsFailedNotCrash() {
        let (c, fetch, _, _) = makeChecker(json: manifestJSON)
        fetch.behavior = .canned(Data("garbage".utf8))
        var outcome: UpdateChecker.Outcome?
        c.check(manual: true) { outcome = $0 }
        XCTAssertEqual(outcome.map { "\($0)" }, Optional("failed"), "坏清单归一化 failed")
    }
}
