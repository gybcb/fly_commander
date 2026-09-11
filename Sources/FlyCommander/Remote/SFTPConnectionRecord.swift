import Foundation
import TCCore

/// 可持久化的**已保存连接**记录（**不含任何密钥**）：名称/id/host/端口/用户名/
/// 认证方式/密钥路径。密码与 passphrase 只存在于 Keychain（见 CredentialsStore）或内存。
///
/// 语义（issue「保存连接列表」）：已保存彻底取代旧「最近连接」——只有用户显式保存
/// 才有条目，connect 成败都不自动写。旧 UserDefaults JSON（无 name/id 的最近连接）
/// 经自定义解码自动导入为初始已保存条目（name=displayName、id=新生成），零迁移。
public struct SFTPConnectionRecord: Codable, Equatable {
    public enum AuthKind: String, Codable, Equatable {
        case password
        case keyFile
    }

    /// 用户可编辑名（同名校验在 VC 层：同名=确认覆盖）。
    public var name: String
    /// 稳定身份（保存覆盖/删除的键）。UUID 字符串，Codable 直存。
    public var id: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var auth: AuthKind
    /// keyFile 认证时的 OpenSSH 私钥路径（路径本身不是秘密）。
    public var keyPath: String?
    /// 该条目保存时是否把密钥写进了 Keychain（仅展示用；真值以 Keychain 为准）。
    public var remembers: Bool

    public init(name: String = "", id: String = UUID().uuidString,
                host: String, port: UInt16, username: String,
                auth: AuthKind, keyPath: String? = nil, remembers: Bool = false) {
        self.name = name
        self.id = id
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.keyPath = keyPath
        self.remembers = remembers
    }

    // 旧「最近连接」JSON 缺 name/id → 兜底导入（name=displayName、id=新 UUID）。
    // 解码整表失败会静默丢表（store 侧 try?），所以这里只兜缺字段、不新增抛错路径。
    private enum CodingKeys: String, CodingKey {
        case name, id, host, port, username, auth, keyPath, remembers
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        username = try c.decode(String.self, forKey: .username)
        auth = try c.decode(AuthKind.self, forKey: .auth)
        keyPath = try c.decodeIfPresent(String.self, forKey: .keyPath)
        remembers = try c.decodeIfPresent(Bool.self, forKey: .remembers) ?? false
        let dn = port == 22 ? "\(host)/\(username)" : "\(host):\(port)/\(username)"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? dn
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    }

    /// 数据源标识（同源判定），与 SFTPConnectionConfig.sourceID 一致。
    public var sourceID: String {
        var s = "sftp://\(host)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    /// 凭据账号（Keychain 键），与 SFTPConnectionConfig.credentialAccount 一致。
    public var credentialAccount: String { "\(host):\(port):\(username)" }

    /// 展示名：name 非空优先，否则 host:port/username 摘要。
    public var displayName: String {
        name.isEmpty ? (port == 22 ? "\(host)/\(username)" : "\(host):\(port)/\(username)")
                     : name
    }

    /// 参数摘要（列表行 name 后缀展示；不含密钥）。
    public var paramsSummary: String {
        port == 22 ? "\(host)/\(username)" : "\(host):\(port)/\(username)"
    }

    /// 凭据就绪后还原运行时配置。password 认证 secret=密码；
    /// keyFile 认证 secret=passphrase（nil 表示无 passphrase）。
    public func config(secret: String?) -> SFTPConnectionConfig {
        let runtimeAuth: SFTPConnectionConfig.Auth
        switch auth {
        case .password:
            runtimeAuth = .password(secret ?? "")
        case .keyFile:
            runtimeAuth = .keyFile(path: keyPath ?? "", passphrase: secret)
        }
        return SFTPConnectionConfig(host: host, port: port, username: username, auth: runtimeAuth)
    }
}
