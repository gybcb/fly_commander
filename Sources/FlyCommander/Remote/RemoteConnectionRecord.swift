import Foundation
import TCCore

/// 统一的**已保存连接**记录（三协议共用一张表，**不含任何密钥**）。
///
/// 取代 SFTPConnectionRecord / SMBConnectionRecord 的列表存储角色：两者的字段并集
/// 在此，协议不适用的字段 nil。旧两表首次读取时经 `from(sftp:)`/`from(smb:)` 一次性
/// 迁入新 UserDefaults 键（见 RemoteConnectionStore）。
///
/// Keychain 侧**不做统一**：服务名与账号规则按 proto 沿用各自现状（见 service/
/// credentialAccount），存量密文无需改写即可回读。
struct RemoteConnectionRecord: Codable, Equatable {
    var proto: RemoteProto
    var id: String
    var name: String
    /// sftp/ftp 主机、smb 服务器（同义不同名，分两字段保留各自旧语义）。
    var host: String?
    var port: Int?
    var server: String?
    var share: String?
    var domain: String?
    var username: String
    var authKind: SFTPConnectionRecord.AuthKind?
    var keyPath: String?
    /// ftp：显式 TLS（FTPS，惯例端口 990）。
    var tls: Bool?
    /// 该条目保存时是否把密钥写进了 Keychain（仅展示用；真值以 Keychain 为准）。
    var remembers: Bool

    init(proto: RemoteProto, id: String = UUID().uuidString, name: String = "",
         host: String? = nil, port: Int? = nil, server: String? = nil, share: String? = nil,
         domain: String? = nil, username: String = "",
         authKind: SFTPConnectionRecord.AuthKind? = nil, keyPath: String? = nil,
         tls: Bool? = nil, remembers: Bool = false) {
        self.proto = proto
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.server = server
        self.share = share
        self.domain = domain
        self.username = username
        self.authKind = authKind
        self.keyPath = keyPath
        self.tls = tls
        self.remembers = remembers
    }

    // MARK: - 迁移构造（旧记录 → 统一记录，身份与凭据账号逐字保留）

    init(_ r: SFTPConnectionRecord) {
        self.init(proto: .sftp, id: r.id, name: r.name, host: r.host, port: Int(r.port),
                  username: r.username, authKind: r.auth, keyPath: r.keyPath,
                  remembers: r.remembers)
    }

    init(_ r: SMBConnectionRecord) {
        self.init(proto: .smb, id: r.id, name: r.name, server: r.server, share: r.share,
                  domain: r.domain, username: r.username, authKind: .password,
                  remembers: r.remembers)
    }

    // MARK: - 身份 / 凭据（按 proto 沿用各自现状，保证存量密码无感可读）

    /// Keychain 服务名：sftp="FlyCommander.sftp"、smb="FlyCommander.smb"、ftp="FlyCommander.ftp"。
    var service: String { "FlyCommander.\(proto.rawValue)" }

    /// Keychain 账号：sftp/ftp=`host:port:username`（ftp 与 sftp 同构）；
    /// smb=`server|domain|share|username`。与各自旧记录逐字一致。
    var credentialAccount: String {
        switch proto {
        case .sftp:
            return "\(host ?? ""):\(port ?? 22):\(username)"
        case .ftp:
            return "\(host ?? ""):\(effectiveFTPPort):\(username)"
        case .smb:
            return "\(server ?? "")|\(domain ?? "")|\(share ?? "")|\(username)"
        }
    }

    /// FTP 条目的生效端口：缺省按 TLS 取默认（明文 21 / Implicit FTPS 990）。
    /// 与活源 FTPClient.Config.defaultPort(tls:) 同口径——两套口径必须共用一个判据，
    /// 否则 tls+990 的条目在 record(forSourceID:) 恒查不到（收藏点不中）。
    var effectiveFTPPort: Int { port ?? Int(FTPClient.Config.defaultPort(tls: tls ?? false)) }

    /// 数据源标识（同源判定用），与各 source 的 sourceID 一致。
    var sourceID: String {
        switch proto {
        case .sftp:
            var s = "sftp://\(host ?? "")"
            if let port, port != 22 { s += ":\(port)" }
            return s
        case .smb:
            return "smb://\(server ?? "")/\(share ?? "")"
        case .ftp:
            // 省略的是**该 tls 形态的默认端口**（tls→990 / 否则→21），与
            // FTPClient.Config.sourceID 逐字同构（F10：只省 21 会让 ftps 条目两边串永不相等）。
            var s = "ftp://\(host ?? "")"
            let p = effectiveFTPPort
            if p != Int(FTPClient.Config.defaultPort(tls: tls ?? false)) { s += ":\(p)" }
            return s
        }
    }

    /// 参数摘要（列表行 name 后缀展示；不含密钥）。逐字沿用旧记录格式。
    var paramsSummary: String {
        switch proto {
        case .sftp:
            (port ?? 22) == 22 ? "\(host ?? "")/\(username)" : "\(host ?? ""):\(port ?? 22)/\(username)"
        case .smb:
            "\(server ?? "")/\(share ?? "") (\(username))"
        case .ftp:
            effectiveFTPPort == Int(FTPClient.Config.defaultPort(tls: tls ?? false))
                ? "\(host ?? "")/\(username)" : "\(host ?? ""):\(effectiveFTPPort)/\(username)"
        }
    }

    /// 展示名：name 非空优先，否则参数摘要。
    var displayName: String { name.isEmpty ? paramsSummary : name }

    /// 列表行文本（name + 摘要）。
    var rowText: String { name.isEmpty ? paramsSummary : "\(name) (\(paramsSummary))" }
}
