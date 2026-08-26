import Foundation
import TCCore

/// SMB 挂载管理器抽象（单测注入 fake；真实现见 SMBMountManager）。
protocol SMBMountManagerLike {
    func mount(_ config: SMBConnectionConfig, secret: String?) throws -> URL
    func unmount(_ mountPoint: URL) throws
}
extension SMBMountManager: SMBMountManagerLike {}

/// SMB 连接编排 + 持久化：活动连接表（sourceID→SMBSource）+ 最近连接（UserDefaults，不含密码）
/// + Keychain（FlyCommander.smb，独立 service，与 SFTP 不串）。
/// connect 同步阻塞（mount 可达数秒）→ **须非主线程调**。
final class SMBConnectionStore {
    static let shared = SMBConnectionStore()

    private var sources: [String: SMBSource] = [:]
    private var recent: [SMBConnectionRecord] = []
    private let credentials: SMBCredentialsStore
    private let mountManager: SMBMountManagerLike
    private let defaults: UserDefaults
    private let storeKey = "smb.recentConnections"

    init(mountManager: SMBMountManagerLike = SMBMountManager(),
         credentials: SMBCredentialsStore = SMBCredentialsStore(),
         defaults: UserDefaults = .standard) {
        self.mountManager = mountManager
        self.credentials = credentials
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([SMBConnectionRecord].self, from: data) {
            recent = list
        }
    }

    /// 建立（或复用）到 server/share 的连接：
    /// 同 sourceID 已挂 → 直接复用（不重挂）；否则 mount → 建源 → 存表 →
    /// 按 remember 存/删 Keychain 凭据 → 记最近连接。
    func connect(_ request: SMBConnectionRequest) throws -> (SMBSource, home: TCPath) {
        if let existing = sources[request.record.sourceID] {
            return (existing, home: existing.homePath)
        }
        let mountPoint = try mountManager.mount(request.config, secret: request.secret)
        let source = SMBSource(config: request.config, mountPoint: mountPoint)
        sources[request.record.sourceID] = source
        updateCredentials(request: request)
        touchRecent(request.record)
        return (source, home: source.homePath)
    }

    func source(for id: String) -> SMBSource? { sources[id] }

    /// 断开并移除活动连接（unmount；凭据保留，可重连）。
    /// 挂载点在 root 外（复用了 Finder 的 /Volumes/<share>）时经 putBackMount 挂回原处，
    /// 断连不该吞掉用户的 Finder 卷。
    func disconnect(_ id: String) {
        if let src = sources.removeValue(forKey: id) {
            do {
                if let mm = mountManager as? SMBMountManager {
                    try mm.putBackMount(src.mountPoint, config: src.config, secret: loadSecret(for: src.config))
                } else {
                    try mountManager.unmount(src.mountPoint)
                }
            } catch {
                // 卸载/挂回失败不阻断断连（残留由下次启动 reclaimStale 回收；
                // 挂回失败时共享处于未挂载状态，用户重连即可）。
            }
            src.closeConnection()
        }
    }

    func disconnectAll() { for id in Array(sources.keys) { disconnect(id) } }

    var recentConnections: [SMBConnectionRecord] { recent }

    /// 回读已记住的密码（记录标记 remembers 时供表单预填）。
    func loadSecret(for record: SMBConnectionRecord) throws -> String? {
        try credentials.load(for: record.config())
    }

    /// 断连时供 putBackMount 挂回原处取密码：按 config 取（Keychain 键 credentialAccount 与 record 一致）。
    /// 取不到/Keychain 失败返回 nil（挂回走匿名挂载，用户重连即可补密码）。
    private func loadSecret(for config: SMBConnectionConfig) -> String? {
        do { return try credentials.load(for: config) } catch { return nil }
    }

    // MARK: - 凭据 / 最近连接

    private func updateCredentials(request: SMBConnectionRequest) {
        do {
            if request.remember, let secret = request.secret, !secret.isEmpty {
                try credentials.save(secret, for: request.config)
            } else {
                // 未勾选"记住"（或无密码）→ 清掉该账号既有凭据，避免残留旧密码。
                try credentials.forget(for: request.config)
            }
        } catch {
            // Keychain 失败不阻断连接（记忆功能降级，下次需重输）。
        }
    }

    /// 最近连接置顶去重（同 credentialAccount 只留一条——键与 Keychain 凭据一致，
    /// 同一共享不同用户名不合并，供表单按人预填），最多 10 条。
    func touchRecent(_ record: SMBConnectionRecord) {
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
