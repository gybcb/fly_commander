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
    /// 已保存连接（显式 save 才进；storeKey 沿用旧键=旧最近连接 JSON 自动导入）。
    private var saved: [SMBConnectionRecord] = []
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
            saved = list
        }
    }

    /// 建立（或复用）到 server/share 的连接：
    /// 同 sourceID 已挂 → 直接复用（不重挂）；否则 mount → 建源 → 存表。
    /// **连接成败都不写已保存列表、不动 Keychain**（issue「保存连接列表」：
    /// touchRecent/updateCredentials 自动路已删，条目只经 save 显式进入）。
    func connect(_ request: SMBConnectionRequest) throws -> (SMBSource, home: TCPath) {
        if let existing = sources[request.record.sourceID] {
            return (existing, home: existing.homePath)
        }
        let mountPoint = try mountManager.mount(request.config, secret: request.secret)
        let source = SMBSource(config: request.config, mountPoint: mountPoint)
        sources[request.record.sourceID] = source
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

    var savedConnections: [SMBConnectionRecord] { saved }

    /// 回读已记住的密码（条目 remembers 时供单击载入回填表单）。
    func loadSecret(for record: SMBConnectionRecord) throws -> String? {
        try credentials.load(for: record.config())
    }

    /// 断连时供 putBackMount 挂回原处取密码：按 config 取（Keychain 键 credentialAccount 与 record 一致）。
    /// 取不到/Keychain 失败返回 nil（挂回走匿名挂载，用户重连即可补密码）。
    private func loadSecret(for config: SMBConnectionConfig) -> String? {
        do { return try credentials.load(for: config) } catch { return nil }
    }

    // MARK: - 凭据 / 已保存连接（与 ConnectionStore 同构语义）

    /// 保存错误（VC 层映射 statusLabel 文案）。
    enum SaveError: Error, Equatable {
        case listFull            // cap 10：新条目拒存
        case sameNameExists      // 无选中保存且同名：VC 已确认覆盖时带 force 重试
    }
    static let savedCap = 10

    /// 显式保存（语义同 SFTP 侧 ConnectionStore.save：id 覆盖原位/force 原位替换同名/
    /// 新 id 置顶/cap 拒存/换账号的旧凭据孤儿清理）。
    @discardableResult
    func save(_ record: SMBConnectionRecord, secret: String?, force: Bool = false) throws -> SMBConnectionRecord {
        var rec = record
        if rec.id.isEmpty { rec.id = UUID().uuidString }
        let sameName: (SMBConnectionRecord) -> Bool = {
            $0.id != rec.id && $0.name == rec.name && !rec.name.isEmpty
        }
        if !force, saved.contains(where: sameName) {
            throw SaveError.sameNameExists
        }
        if let secret, !secret.isEmpty {
            try? credentials.save(secret, for: rec.config())
            rec.remembers = true
        } else {
            rec.remembers = false
        }
        // 三分支落位（同 ConnectionStore.save：选中项改名撞同名 force 时=原位覆盖自身
        // +移除撞名的**其他**条目，杜绝双同 id 孤儿；被换掉的旧凭据账号做孤儿清理）。
        if let i = saved.firstIndex(where: { $0.id == rec.id }) {
            var victims = [saved[i]]
            saved[i] = rec
            if force {
                let doomed = saved.filter { $0.id != rec.id && $0.name == rec.name && !rec.name.isEmpty }
                saved.removeAll { $0.id != rec.id && $0.name == rec.name && !rec.name.isEmpty }
                victims.append(contentsOf: doomed)
            }
            forgetOrphanedSecrets(victims, kept: rec)
        } else if let j = saved.firstIndex(where: sameName) {
            let victim = saved[j]
            saved[j] = rec                      // force 覆盖：原位替换同名条目
            forgetOrphanedSecrets([victim], kept: rec)
        } else {
            guard saved.count < Self.savedCap else { throw SaveError.listFull }
            saved.insert(rec, at: 0)
        }
        persist()
        return rec
    }

    /// Keychain 孤儿清理（同 SFTP 侧 ConnectionStore.forgetOrphanedSecrets 同构）：
    /// 被替换/被移除条目的旧 credentialAccount 不再被任何在场条目（含新条目）引用时
    /// 就地 forget；仍被兄弟共享的不清。
    private func forgetOrphanedSecrets(_ victims: [SMBConnectionRecord], kept: SMBConnectionRecord) {
        var live = Set(saved.map(\.credentialAccount))
        live.insert(kept.credentialAccount)
        for v in victims where !live.contains(v.credentialAccount) {
            try? credentials.forget(for: v.config())
        }
    }

    /// 删除条目。**仅当无其他条目共享同 credentialAccount 时才 forget Keychain**。
    func remove(id: String) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        let rec = saved.remove(at: i)
        if !saved.contains(where: { $0.credentialAccount == rec.credentialAccount }) {
            try? credentials.forget(for: rec.config())
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
