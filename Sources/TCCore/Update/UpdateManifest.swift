import Foundation

/// 自托管更新清单（`updates` 分支 latest.json）的解码模型 + 结构校验。
/// 发布链在每次发布后写此文件；App 读 raw.githubusercontent 直链解析。
/// 纯 Foundation，零 IO。
public struct UpdateManifest: Codable, Equatable {
    public let version: String       // 语义版本，如 "0.0.6"
    public let dmgURL: String        // 完整 https 直链（releases/download/...）
    public let sha256: String        // 小写十六进制 64 字符
    public let notes: String         // 更新说明（可多行，UI 侧原样显示）

    public init(version: String, dmgURL: String, sha256: String, notes: String) {
        self.version = version; self.dmgURL = dmgURL
        self.sha256 = sha256; self.notes = notes
    }

    /// 结构健全性 + 信任锚定：version 非空；sha256 恰 64 位 **ASCII** 小写 hex
    /// （显式排 Unicode 数字——isHexDigit 认全角字符，发布链只产 [0-9a-f]）；
    /// dmgURL 必须**逐字符**等于官方发布直链模板
    /// `https://github.com/gybcb/fly_commander/releases/download/v<version>/FlyCommander_<version>_arm64.dmg`
    /// （tag 恒 = "v"+version，release.yml 双校验保证）。主机/路径/版本自洽全锁死——
    /// 被篡改清单即便自带合法 sha256 也投毒不进第三方主机或降级包。
    /// 任一条不满足 → App 视为「清单不可信」静默失败，不弹任何窗。
    public var isValid: Bool {
        guard !version.isEmpty else { return false }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        guard sha256.unicodeScalars.count == 64,
              sha256.unicodeScalars.allSatisfy(hex.contains) else { return false }
        guard dmgURL == Self.expectedDmgURL(version: version) else { return false }
        return true
    }

    /// 官方发布直链模板（信任锚定唯一真源；release.yml 侧命名镜像校验同式）。
    public static func expectedDmgURL(version: String) -> String {
        "https://github.com/gybcb/fly_commander/releases/download/v\(version)/FlyCommander_\(version)_arm64.dmg"
    }

    /// 解码 + 校验合一；失败一律 throw `ManifestError.invalid`（调用方静默处理）。
    public static func decode(_ data: Data) throws -> UpdateManifest {
        let m: UpdateManifest
        do { m = try JSONDecoder().decode(UpdateManifest.self, from: data) }
        catch { throw ManifestError.invalid }
        guard m.isValid else { throw ManifestError.invalid }
        return m
    }

    public enum ManifestError: Error, Equatable { case invalid }
}
