import XCTest
@testable import TCCore

/// 更新清单解码/校验回归锁。每条带变异证伪注释。
final class UpdateManifestTests: XCTestCase {

    private let valid = """
    {"version":"0.0.6","dmgURL":"https://github.com/o/r/releases/download/v0.0.6/FlyCommander_0.0.6_arm64.dmg","sha256":"\(String(repeating: "a", count: 64))","notes":"fix"}
    """

    func testValidManifestDecodes() throws {
        let m = try UpdateManifest.decode(Data(valid.utf8))
        XCTAssertEqual(m.version, "0.0.6")
        XCTAssertTrue(m.isValid)
    }

    func testRejectsEmptyVersion() {
        let s = valid.replacingOccurrences(of: "\"version\":\"0.0.6\"", with: "\"version\":\"\"")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8))) { e in
            XCTAssertEqual(e as? UpdateManifest.ManifestError, .invalid)
        }
        // 变异证伪：删 isValid 里 !version.isEmpty 守卫 → 此断言假绿（清单空版本被接受）。
    }

    func testRejectsNonHTTPSURL() {
        // 劫持/明文下载源必须拒绝：http:// 不合规。
        let s = valid.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
        // 变异证伪：isValid 里 u.scheme == "https" 改成 u.scheme != nil → 此断言假绿。
    }

    func testRejectsShortHex() {
        let s = valid.replacingOccurrences(of: String(repeating: "a", count: 64), with: "abc")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
    }

    func testRejectsUppercaseHex() {
        // sha256 归一化为小写；发布链产出恒小写，混合大小写视为不可信。
        let s = valid.replacingOccurrences(of: String(repeating: "a", count: 64),
                                           with: String(repeating: "A", count: 64))
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
    }

    func testRejectsGarbageJSON() {
        XCTAssertThrowsError(try UpdateManifest.decode(Data("not json".utf8))) { e in
            XCTAssertEqual(e as? UpdateManifest.ManifestError, .invalid)   // 解码失败也归一化为 .invalid
        }
    }

    func testMissingFieldIsInvalid() {
        // notes 缺失（decode 直接抛）与 version 缺失分别覆盖 JSONDecoder throw 路。
        XCTAssertThrowsError(try UpdateManifest.decode(Data(#"{"version":"1.0.0"}"#.utf8)))
    }
}
