import Foundation

/// 自托管更新清单（`updates` 分支 latest.json）的解码模型 + 结构校验。
/// 发布链在每次发布后写此文件；App 读 raw.githubusercontent 直链解析。
///
/// **双架构**：清单按 CPU 架构分列产物（assets: arm64 / x86_64），App 解码时按**本机实际
/// 架构**选中对应条目 → 得到唯一的 (dmgURL, sha256)。`decode(arch:)` 之外，本模型对本机
/// 架构选中后的**具体**版本/直链/校验和赋值到非可选字段，下游（installer/UI）只见具体值。
///
/// **兼容旧清单**：v0.0.8 及以前清单无 assets、只有顶层 dmgURL/sha256（恒 arm64）。解码时
/// 若 assets 缺失但顶层字段在，则**仅当 arch==arm64** 才当 arm64 资产采信；Intel 机读旧清单
/// 选不到 x86_64 → 视为无可用更新（静默）。
///
/// 纯 Foundation，零 IO（架构由调用方以字符串传入，本文件不探测 CPU）。
public struct UpdateManifest: Equatable {
    public let version: String       // 语义版本，如 "0.0.6"
    public let dmgURL: String        // 本机架构对应产物的完整 https 直链（releases/download/...）
    public let sha256: String        // 小写十六进制 64 字符
    public let notes: String         // 更新说明（可多行，UI 侧原样显示）

    public init(version: String, dmgURL: String, sha256: String, notes: String) {
        self.version = version; self.dmgURL = dmgURL
        self.sha256 = sha256; self.notes = notes
    }

    // MARK: - 架构常量与命名模板

    /// 清单支持的建筑键（与 release.yml 侧命名、CPU 探测三方唯一真源）。
    public static let arm64Key = "arm64"
    public static let x86_64Key = "x86_64"
    public static let supportedArchKeys: [String] = [arm64Key, x86_64Key]

    /// 官方发布直链模板（信任锚定唯一真源；release.yml 侧命名镜像校验同式）。
    /// 文件名 `FlyCommander_<version>_<arch>.dmg`（arm64 / x86_64）。
    public static func expectedDmgURL(version: String, arch: String = arm64Key) -> String {
        "https://github.com/gybcb/fly_commander/releases/download/v\(version)/FlyCommander_\(version)_\(arch).dmg"
    }

    private static func isValidSHA(_ s: String) -> Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        return s.unicodeScalars.count == 64 && s.unicodeScalars.allSatisfy(hex.contains)
    }

    /// 本模型持有的是**已按本机架构选中**后的具体 (version, dmgURL, sha256)。
    /// 结构健全性：version 非空；sha256 恰 64 位 ASCII 小写 hex（显式排 Unicode 数字）；
    /// dmgURL 必须逐字符等于本机版本对应某架构的官方直链模板（主机/路径/版本自洽全锁死，
    /// 篡改清单投毒不进第三方主机或降级包）。注意此处不校验「哪个架构」——decode 阶段已按
    /// 传入 arch 精确比对 expectedDmgURL(version, arch)，这里只是具体值的健全性回锁。
    public var isValid: Bool {
        guard !version.isEmpty else { return false }
        guard Self.isValidSHA(sha256) else { return false }
        let matches = Self.supportedArchKeys.contains { dmgURL == Self.expectedDmgURL(version: version, arch: $0) }
        return matches
    }

    // MARK: - 解码（按本机架构选中）

    /// 清单原始 JSON 形状：version/notes + assets 字典，或旧的顶层 dmgURL/sha256（arm64-only）。
    private struct Raw: Decodable {
        let version: String
        let notes: String?
        let dmgURL: String?
        let sha256: String?
        let assets: [String: Asset]?
        struct Asset: Decodable { let dmgURL: String; let sha256: String }
    }

    /// 解码 + 按 arch 选中 + 校验合一；任一环节不满足 → throw `.invalid`（调用方静默处理）。
    /// `arch` 必须是 `supportedArchKeys` 之一；传入不支持的架构 → 直接 invalid（不给未知架构发包）。
    public static func decode(_ data: Data, arch: String = arm64Key) throws -> UpdateManifest {
        guard supportedArchKeys.contains(arch) else { throw ManifestError.invalid }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) }
        catch { throw ManifestError.invalid }
        guard !raw.version.isEmpty else { throw ManifestError.invalid }

        // 选中本架构资产：assets 优先；缺 assets 时旧顶层字段仅当 arm64 采信。
        let asset: Raw.Asset?
        if let assets = raw.assets {
            asset = assets[arch]
        } else if arch == arm64Key, let u = raw.dmgURL, let s = raw.sha256 {
            asset = Raw.Asset(dmgURL: u, sha256: s)
        } else {
            asset = nil
        }
        guard let a = asset,
              a.dmgURL == expectedDmgURL(version: raw.version, arch: arch),
              isValidSHA(a.sha256) else { throw ManifestError.invalid }

        return UpdateManifest(version: raw.version, dmgURL: a.dmgURL,
                              sha256: a.sha256, notes: raw.notes ?? "")
    }

    public enum ManifestError: Error, Equatable { case invalid }
}
