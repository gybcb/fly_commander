import XCTest
@testable import TCCore

/// 更新清单解码/校验回归锁（信任锚定：dmgURL 恒 = 官方模板，sha256 恒 ASCII 小写 hex）。
/// 每条带变异证伪注释。
final class UpdateManifestTests: XCTestCase {

    private let valid = """
    {"version":"0.0.6","dmgURL":"\(UpdateManifest.expectedDmgURL(version: "0.0.6"))","sha256":"\(String(repeating: "a", count: 64))","notes":"fix"}
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

    func testRejectsForeignHost() {
        // 供应链锚定：第三方 https 主机即便 scheme=https、sha 自洽也必须拒绝
        // （updates 分支被篡改时投毒不进外部载荷）。
        let s = valid.replacingOccurrences(of: "github.com/gybcb/fly_commander",
                                           with: "evil.example.com/payload")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
        // 变异证伪：isValid 的 dmgURL 全等比较改回 scheme=="https" → 此断言假绿。
    }

    func testRejectsURLVersionMismatch() {
        // 清单 version=0.0.6 但直链指向别的版本（可驱动降级安装）→ 拒绝。
        let mismatch = """
        {"version":"0.0.6","dmgURL":"\(UpdateManifest.expectedDmgURL(version: "0.0.1"))","sha256":"\(String(repeating: "a", count: 64))","notes":"fix"}
        """
        XCTAssertThrowsError(try UpdateManifest.decode(Data(mismatch.utf8)))
    }

    func testRejectsNonHTTPSURL() {
        // 劫持/明文下载源必须拒绝：http:// 不合规。
        let s = valid.replacingOccurrences(of: "https://", with: "http://")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
        // 变异证伪：删 dmgURL 全等比较只留 scheme 检查 → 此断言假绿。
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

    func testRejectsFullwidthHexDigits() {
        // Unicode 坑锁：Character.isHexDigit 认全角「６」等且 !isUppercase 也放行，
        // 但发布链只产 [0-9a-f]——全角形态必须拒（闸门字符集恒 ASCII 白名单）。
        let s = valid.replacingOccurrences(of: String(repeating: "a", count: 64),
                                           with: "６" + String(repeating: "a", count: 63))
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8)))
        // 变异证伪：hex 白名单改回 { $0.isHexDigit && !$0.isUppercase } → 此断言假绿。
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
