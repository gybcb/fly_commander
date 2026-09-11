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

    /// 结构健全性：version 非空；dmgURL 是 https URL；sha256 恰 64 位小写 hex；notes 可空。
    /// 任一条不满足 → App 视为「清单不可信」静默失败，不弹任何窗（防被劫持清单投毒）。
    public var isValid: Bool {
        guard !version.isEmpty else { return false }
        guard let u = URL(string: dmgURL), u.scheme == "https" else { return false }
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return false }
        return true
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
