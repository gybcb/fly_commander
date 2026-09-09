import Foundation
import TCCore

/// 一次连接请求（连接窗表单 → 编排入口）。
public struct ConnectionRequest: Equatable {
    public var host: String
    public var port: UInt16
    public var username: String
    public var auth: SFTPConnectionRecord.AuthKind
    public var keyPath: String?
    /// 密码或密钥 passphrase（未勾选"记住"时仅本次使用）。
    public var secret: String?
    /// 勾选"记住"：密码/passphrase 写入 Keychain。
    public var remember: Bool

    public init(host: String, port: UInt16, username: String,
                auth: SFTPConnectionRecord.AuthKind, keyPath: String? = nil,
                secret: String? = nil, remember: Bool = false) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.keyPath = keyPath
        self.secret = secret
        self.remember = remember
    }

    public var record: SFTPConnectionRecord {
        SFTPConnectionRecord(host: host, port: port, username: username,
                             auth: auth, keyPath: keyPath, remembers: remember)
    }

    public var config: SFTPConnectionConfig {
        record.config(secret: secret)
    }
}

/// 连接编排 + 持久化。
/// - 活动连接表：sourceID → SFTPSource（同 host:port 复用同一连接）；
/// - 最近连接：UserDefaults（JSON，仅 SFTPConnectionRecord，不含密钥）。
/// connect 为同步阻塞调用（SSH 握手可达数秒）——**必须在非主线程调用**。
final class ConnectionStore {
    static let shared = ConnectionStore()

    private var sources: [String: SFTPSource] = [:]
    private var recent: [SFTPConnectionRecord] = []
    private let credentials: CredentialsStore
    private let defaults: UserDefaults
    private let storeKey = "sftp.recentConnections"

    init(credentials: CredentialsStore = CredentialsStore(),
         defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([SFTPConnectionRecord].self, from: data) {
            recent = list
        }
    }

    /// 建立（或复用）到 host:port 的连接：建源 → 连接 → 解析远端 home。
    /// 成功后按 remember 存/删 Keychain 凭据、更新最近连接列表。
    func connect(_ request: ConnectionRequest) throws -> (SFTPSource, home: String) {
        if let existing = sources[request.record.sourceID] {
            return (existing, home: existing.homeDirectory)
        }
        let source = SFTPSource(config: request.config,
                                homeDirectory: "/",
                                hostKeyStore: SFTPHostKeyStore(defaults: defaults))
        do {
            let home = try source.resolveHome()
            source.homeDirectory = home   // 连接已建立，补上真实 home
            sources[request.record.sourceID] = source
            updateCredentials(request: request)
            touchRecent(request.record)
            return (source, home: home)
        } catch {
            source.closeConnection()
            throw error
        }
    }

    func source(for id: String) -> SFTPSource? { sources[id] }

    /// 为传输创建**独立连接的**第二条 SFTPSource，用于 copyFile 期间不阻塞浏览源的 NSLock。
    ///
    /// 设计取舍：
    /// - **多付一次 SSH 握手**是有意的隔离代价：浏览源的 SFTPConnection 被 copyFile 的
    ///   NSLock 全程持有（SFTPClient 单线程约束），复用同一连接则 listDirectory/stat
    ///   会被阻塞到传输结束；独立连接解决此问题。
    /// - **同源判定不受影响**：OperationEngine 用 sourceID 字符串相等判定同源，
    ///   两个 SFTPSource 实例的 sourceID 一致 → 仍走 cp 快路径。
    /// - **凭据来源**：优先用浏览源内存 config 里已有的密码/passphrase；内存无值时
    ///   Keychain 回读（remember=true 存过才有）。都取不到 → 返回 nil，
    ///   调用方回落到共享源（现状行为，传输期间浏览会阻塞）。
    /// - **生命周期**：调用方负责传输结束后 closeConnection；本方法不进 sources 表、
    ///   不 touchRecent、不动 Keychain。resolveHome 兼作建连验证（失败 → nil），
    ///   homeDirectory 预置浏览源值，避免中途依赖 home 解析结果。
    func transferSource(for sourceID: String) -> SFTPSource? {
        guard let browseSource = sources[sourceID] else { return nil }
        // 从浏览源的内存 config 重建 SFTPConnectionConfig。
        // 凭据来源：优先用内存 config 中已有的 secret（连接时传入的密码/passphrase），
        // 仅当内存中无值时尝试 Keychain 回读（sandbox 环境下 Keychain 可能不可用）。
        let browseConfig = browseSource.config
        let record = SFTPConnectionRecord(host: browseConfig.host, port: browseConfig.port,
                                          username: browseConfig.username,
                                          auth: browseConfig.auth.keyKind,
                                          keyPath: browseConfig.auth.keyPath)
        let secret: String?
        switch browseConfig.auth {
        case .password(let pw):
            // 密码直接在内存 config 中（.password(pw)），无需 Keychain。
            secret = pw.isEmpty ? nil : pw
        case .keyFile(_, let passphrase):
            // passphrase 可能在连接时已存入内存 config（.keyFile(path:passphrase:)）。
            // 若为 nil（key 不需要 passphrase 或未传入），尝试 Keychain 回读。
            if let pp = passphrase, !pp.isEmpty {
                secret = pp
            } else {
                do {
                    secret = try credentials.load(for: record.config(secret: nil))
                } catch {
                    // Keychain 不可用（sandbox 等）→ 无法建连，降级为 nil
                    return nil
                }
            }
        }
        let newConfig = record.config(secret: secret)
        let transferSource = SFTPSource(config: newConfig,
                                        homeDirectory: browseSource.homeDirectory,
                                        hostKeyStore: SFTPHostKeyStore(defaults: defaults))
        do {
            _ = try transferSource.resolveHome()
        } catch {
            transferSource.closeConnection()
            return nil
        }
        return transferSource
    }

    /// 断开并移除活动连接（凭据保留，可重连）。
    func disconnect(_ id: String) {
        sources.removeValue(forKey: id)?.closeConnection()
    }

    func disconnectAll() {
        for id in sources.keys { disconnect(id) }
    }

    var activeIDs: [String] { sources.keys.sorted() }
    var recentConnections: [SFTPConnectionRecord] { recent }

    /// 回读已记住的密码/passphrase（记录标记 remembers 时供表单预填）。
    func loadSecret(for record: SFTPConnectionRecord) throws -> String? {
        try credentials.load(for: record.config(secret: nil))
    }

    // MARK: - 凭据 / 最近连接

    private func updateCredentials(request: ConnectionRequest) {
        do {
            if request.remember, let secret = request.secret {
                try credentials.save(secret, for: request.config)
            } else {
                try credentials.forget(for: request.config)
            }
        } catch {
            // Keychain 失败不阻断连接（记忆功能降级，下次需重输）。
        }
    }

    /// 最近连接置顶去重，最多 10 条。
    func touchRecent(_ record: SFTPConnectionRecord) {
        recent.removeAll { $0.credentialAccount == record.credentialAccount }
        recent.insert(record, at: 0)
        if recent.count > 10 { recent.removeLast(recent.count - 10) }
        persistRecent()
    }

    func removeRecent(account: String) {
        recent.removeAll { $0.credentialAccount == account }
        persistRecent()
    }

    private func persistRecent() {
        guard let data = try? JSONEncoder().encode(recent) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
