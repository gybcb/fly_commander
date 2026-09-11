import Foundation

/// SMB 连接配置（运行时身份，不含密码）。密码只在 mount 调用时传入。
public struct SMBConnectionConfig: Equatable {
    public let server: String
    public let share: String
    public let domain: String?
    public let username: String

    public init(server: String, share: String, domain: String?, username: String) {
        self.server = server
        self.share = share
        self.domain = domain
        self.username = username
    }

    /// 数据源标识（同源判定），与 record.sourceID 一致。
    public var sourceID: String { "smb://\(server)/\(share)" }
    /// 凭据账号（Keychain 键），与 record.credentialAccount 一致。
    public var credentialAccount: String { "\(server)|\(domain ?? "")|\(share)|\(username)" }
}

/// 可持久化**已保存连接**记录（**不含密码**）。密码只在 Keychain（service "FlyCommander.smb"）。
///
/// 语义（issue「保存连接列表」）：已保存彻底取代旧「最近连接」——只有显式保存才有
/// 条目。旧 UserDefaults JSON（无 name/id）经自定义解码自动导入（name=displayName、
/// id=新 UUID），零迁移。
public struct SMBConnectionRecord: Codable, Equatable {
    /// 用户可编辑名（同名校验在 VC 层：同名=确认覆盖）。
    public var name: String
    /// 稳定身份（保存覆盖/删除的键）。
    public var id: String
    public var server: String
    public var share: String
    public var domain: String?
    public var username: String
    public var remembers: Bool

    public init(name: String = "", id: String = UUID().uuidString, server: String, share: String,
                domain: String?, username: String, remembers: Bool = false) {
        self.name = name
        self.id = id
        self.server = server
        self.share = share
        self.domain = domain
        self.username = username
        self.remembers = remembers
    }

    // 旧「最近连接」JSON 缺 name/id → 兜底导入（与 SFTP 侧同构）。
    private enum CodingKeys: String, CodingKey {
        case name, id, server, share, domain, username, remembers
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        server = try c.decode(String.self, forKey: .server)
        share = try c.decode(String.self, forKey: .share)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        username = try c.decode(String.self, forKey: .username)
        remembers = try c.decodeIfPresent(Bool.self, forKey: .remembers) ?? false
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "\(server)/\(share) (\(username))"
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
    }

    public var sourceID: String { "smb://\(server)/\(share)" }
    public var credentialAccount: String { "\(server)|\(domain ?? "")|\(share)|\(username)" }
    /// 展示名：name 非空优先，否则 server/share (username) 摘要。
    public var displayName: String { name.isEmpty ? "\(server)/\(share) (\(username))" : name }
    /// 参数摘要（列表行 name 后缀展示；ASCII 括号沿用终审 I-1）。
    public var paramsSummary: String { "\(server)/\(share) (\(username))" }
    public func config() -> SMBConnectionConfig {
        SMBConnectionConfig(server: server, share: share, domain: domain, username: username)
    }
}

/// 一次连接请求（连接窗表单 → 编排入口）。secret=密码（未记住仅本次用）。
public struct SMBConnectionRequest: Equatable {
    public var server: String
    public var share: String
    public var domain: String?
    public var username: String
    public var secret: String?
    public var remember: Bool

    public init(server: String, share: String, domain: String?,
                username: String, secret: String? = nil, remember: Bool = false) {
        self.server = server
        self.share = share
        self.domain = domain
        self.username = username
        self.secret = secret
        self.remember = remember
    }

    public var record: SMBConnectionRecord {
        SMBConnectionRecord(server: server, share: share, domain: domain,
                            username: username, remembers: remember)
    }
    public var config: SMBConnectionConfig { record.config() }
}
