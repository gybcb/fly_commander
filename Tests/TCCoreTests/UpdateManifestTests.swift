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

    // MARK: - 双架构 assets

    private let assetsJSON = """
    {"version":"1.2.3",\
    "assets":{\
    "arm64":{"dmgURL":"\(UpdateManifest.expectedDmgURL(version: "1.2.3", arch: UpdateManifest.arm64Key))","sha256":"\(String(repeating: "a", count: 64))"},\
    "x86_64":{"dmgURL":"\(UpdateManifest.expectedDmgURL(version: "1.2.3", arch: UpdateManifest.x86_64Key))","sha256":"\(String(repeating: "b", count: 64))"}},\
    "notes":"two arches"}
    """

    func testAssetsSelectsByArch() throws {
        let a = try UpdateManifest.decode(Data(assetsJSON.utf8), arch: UpdateManifest.arm64Key)
        XCTAssertEqual(a.dmgURL, UpdateManifest.expectedDmgURL(version: "1.2.3", arch: "arm64"))
        XCTAssertEqual(a.sha256, String(repeating: "a", count: 64))
        let x = try UpdateManifest.decode(Data(assetsJSON.utf8), arch: UpdateManifest.x86_64Key)
        XCTAssertEqual(x.dmgURL, UpdateManifest.expectedDmgURL(version: "1.2.3", arch: "x86_64"))
        XCTAssertEqual(x.sha256, String(repeating: "b", count: 64))
        // 变异证伪：decode 忽略 arch 恒取 arm64 → x86_64 断言翻红。
    }

    func testLegacyTopLevelOnlyAcceptedForArm64RejectedForX86() {
        // 旧清单（无 assets，顶层 arm64 字段）：arm64 机可用；Intel 机选不到 x86_64 → invalid。
        XCTAssertNoThrow(try UpdateManifest.decode(Data(valid.utf8), arch: UpdateManifest.arm64Key))
        XCTAssertThrowsError(try UpdateManifest.decode(Data(valid.utf8), arch: UpdateManifest.x86_64Key))
        // 变异证伪：旧字段回退分支去掉 arch==arm64 条件 → Intel 被塞 arm64 包，断言翻红。
    }

    func testAssetsMissingRequestedArchIsInvalid() {
        // assets 只有 arm64 → x86_64 机无包可下 = 无更新（invalid），不得回落 arm64。
        let s = """
        {"version":"1.2.3","assets":{"arm64":{"dmgURL":"\(UpdateManifest.expectedDmgURL(version: "1.2.3"))","sha256":"\(String(repeating: "a", count: 64))"}},"notes":"arm only"}
        """
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8), arch: UpdateManifest.x86_64Key))
    }

    func testX86AssetOnForeignHostRejected() {
        // x86_64 资产的直链同样过主机锚定：换主机 → 拒（锚定不区分架构）。
        let s = assetsJSON.replacingOccurrences(of: "github.com/gybcb/fly_commander/releases/download/v1.2.3/FlyCommander_1.2.3_x86_64.dmg",
                                                with: "evil.example.com/x.dmg")
        XCTAssertThrowsError(try UpdateManifest.decode(Data(s.utf8), arch: UpdateManifest.x86_64Key))
    }

    func testUnknownArchKeyRejected() {
        // 清单里的未知架构键不影响解码；请求未知架构 → invalid（不给未知架构发包）。
        XCTAssertThrowsError(try UpdateManifest.decode(Data(assetsJSON.utf8), arch: "riscv64"))
    }
}
