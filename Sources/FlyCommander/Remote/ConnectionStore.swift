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
