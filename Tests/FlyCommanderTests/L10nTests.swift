import XCTest
@testable import FlyCommander
@testable import TCCore

final class L10nTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    func testDefaultIsEnglishWhenNoPreference() {
        UserDefaults.standard.removeObject(forKey: "appLanguage")
        XCTAssertEqual(L10n.currentResolvedForTest, .en)
    }
    func testInterpolatedLookupEnglish() {
        XCTAssertEqual(L10n.t(.entered, "sftp://h:22/x"), "Entered sftp://h:22/x")
    }
    func testZhSwitchAndBack() {
        L10n.current = .zh
        XCTAssertEqual(L10n.t(.entered, "/tmp"), "已进入 /tmp")
        L10n.current = .en
        XCTAssertEqual(L10n.t(.entered, "/tmp"), "Entered /tmp")
    }
    func testMissingKeyFallsBackEnglishNotRawKey() {
        L10n.current = .zh
        // testFallbackProbe 只在 en 表：zh 下必须落英文表值，而非 zh 缺失导致的 key.rawValue
        XCTAssertEqual(L10n.t(.testFallbackProbe), "__PROBE_EN__")
    }
    func testOnChangeFiresOnSwitch() {
        var fired = 0
        let token = L10n.observe { fired += 1 }
        L10n.current = .zh
        L10n.current = .en
        L10n.unobserve(token)
        XCTAssertEqual(fired, 2)
    }
}
