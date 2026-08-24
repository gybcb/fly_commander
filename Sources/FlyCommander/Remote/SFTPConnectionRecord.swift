import Foundation
import TCCore

/// 可持久化的连接记录（**不含任何密钥**）：host/端口/用户名/认证方式/密钥路径。
/// 密码与 passphrase 只存在于 Keychain（见 CredentialsStore）或内存。
public struct SFTPConnectionRecord: Codable, Equatable {
    public enum AuthKind: String, Codable, Equatable {
        case password
        case keyFile
    }

    public var host: String
    public var port: UInt16
    public var username: String
    public var auth: AuthKind
    /// keyFile 认证时的 OpenSSH 私钥路径（路径本身不是秘密）。
    public var keyPath: String?
    /// 是否已有记住的密码/passphrase（仅展示用；真值以 Keychain 为准）。
    public var remembers: Bool

    public init(host: String, port: UInt16, username: String,
                auth: AuthKind, keyPath: String? = nil, remembers: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.keyPath = keyPath
        self.remembers = remembers
    }

    /// 数据源标识（同源判定），与 SFTPConnectionConfig.sourceID 一致。
    public var sourceID: String {
        var s = "sftp://\(host)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    /// 凭据账号（Keychain 键），与 SFTPConnectionConfig.credentialAccount 一致。
    public var credentialAccount: String { "\(host):\(port):\(username)" }

    /// 展示名：host:port/username。
    public var displayName: String {
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
