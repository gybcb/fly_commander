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

/// 可持久化连接记录（**不含密码**）。密码只在 Keychain（service "FlyCommander.smb"）。
public struct SMBConnectionRecord: Codable, Equatable {
    public var server: String
    public var share: String
    public var domain: String?
    public var username: String
    public var remembers: Bool

    public init(server: String, share: String, domain: String?,
                username: String, remembers: Bool = false) {
        self.server = server
        self.share = share
        self.domain = domain
        self.username = username
        self.remembers = remembers
    }

    public var sourceID: String { "smb://\(server)/\(share)" }
    public var credentialAccount: String { "\(server)|\(domain ?? "")|\(share)|\(username)" }
    public var displayName: String { "\(server)/\(share)（\(username)）" }
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
