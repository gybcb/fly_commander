import Foundation
import TCCore

/// 统一「已保存连接」列表 + 凭据门面（SFTP/SMB/FTP 三协议共用一张表）。
///
/// 取代 ConnectionStore / SMBConnectionStore 的「已保存列表 + Keychain」职责：
/// - 列表落新键 `remote.connections`；**首次读取时一次性迁移**旧 sftp/smb 两列表键的
///   条目（旧键保留不删，回滚/排障可见）；
/// - Keychain **不合并**：按 proto 选服务（`FlyCommander.sftp` / `.smb` / `.ftp`）+
///   各自账号规则（见 RemoteConnectionRecord.credentialAccount）→ 存量密文无需改写
///   即可回读，新 ftp 走与 sftp 同构的账号规则。
///
/// save/remove/孤儿清理语义逐字沿用旧两 store（见 ConnectionStore.save 的三分支注释）。
final class RemoteConnectionStore {
    static let shared = RemoteConnectionStore()

    static let savedCap = 20
    static let storeKey = "remote.connections"
    /// 旧列表键（迁移来源；迁移后只读不写，保留不删）。
    static let legacySFTPKey = "sftp.recentConnections"
    static let legacySMBKey = "smb.recentConnections"

    private(set) var saved: [RemoteConnectionRecord] = []
    private let keychains: [RemoteProto: KeychainLike]
    private let defaults: UserDefaults

    init(keychains: [RemoteProto: KeychainLike]? = nil, defaults: UserDefaults = .standard) {
        // 缺省按 proto 各建真 Keychain 服务（ftp 与 sftp 同账号规则，服务名单独一支）。
        self.keychains = keychains ?? [
            .sftp: KeychainCredentialsStore(service: "FlyCommander.sftp"),
            .smb: KeychainCredentialsStore(service: "FlyCommander.smb"),
            .ftp: KeychainCredentialsStore(service: "FlyCommander.ftp"),
        ]
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storeKey),
           let list = try? JSONDecoder().decode([RemoteConnectionRecord].self, from: data) {
            saved = list
        } else {
            saved = Self.migrate(defaults: defaults)
            persist()
        }
    }

    /// 旧两列表键 → 统一列表（一次性；旧键原样保留）。整表解码失败静默跳过该源
    /// （与旧 store 的 `try?` 同一容忍度——坏数据不该把整个启动路径带崩）。
    private static func migrate(defaults: UserDefaults) -> [RemoteConnectionRecord] {
        var out: [RemoteConnectionRecord] = []
        if let d = defaults.data(forKey: legacySFTPKey),
           let list = try? JSONDecoder().decode([SFTPConnectionRecord].self, from: d) {
            out.append(contentsOf: list.map(RemoteConnectionRecord.init))
        }
        if let d = defaults.data(forKey: legacySMBKey),
           let list = try? JSONDecoder().decode([SMBConnectionRecord].self, from: d) {
            out.append(contentsOf: list.map(RemoteConnectionRecord.init))
        }
        return out
    }

    // MARK: - 读

    var savedConnections: [RemoteConnectionRecord] { saved }

    /// 按 sourceID 找回已保存条目（收藏重连用：`ftp://…` 分支的全部依赖）。
    func record(forSourceID sourceID: String) -> RemoteConnectionRecord? {
        saved.first { $0.sourceID == sourceID }
    }

    /// 回读已记住的密码/passphrase（条目 remembers 时供单击载入回填表单）。
    func loadSecret(for record: RemoteConnectionRecord) throws -> String? {
        try keychain(for: record.proto)?.get(account: record.credentialAccount)
    }

    // MARK: - 写

    /// 保存错误（VC 层映射 statusLabel 文案）。
    enum SaveError: Error, Equatable {
        case listFull            // cap：新条目拒存
        case sameNameExists      // 无选中保存且同名：VC 已确认覆盖时带 force 重试
    }

    /// 显式保存。语义与旧 ConnectionStore.save / SMBConnectionStore.save 逐字同构：
    /// ① 选中项在编辑（rec.id 命中既有条目）→ 原位覆盖；force 且**另有条目**撞同名
    ///    时一并移除之（杜绝双同 id 孤儿）；
    /// ② 无选中且同名命中 → 原位替换该同名条目（id 换新，不追加）；
    /// ③ 都不命中 → 新 id 置顶（超 cap 拒存）。
    /// secret 非空 → 写 Keychain 且 remembers=true；nil → 不写并 remembers=false。
    /// 被换掉/被移除条目的旧凭据若不再被任何在场条目引用 → 就地 forget（孤儿清理）。
    @discardableResult
    func save(_ record: RemoteConnectionRecord, secret: String?, force: Bool = false) throws -> RemoteConnectionRecord {
        var rec = record
        if rec.id.isEmpty { rec.id = UUID().uuidString }
        let sameName: (RemoteConnectionRecord) -> Bool = {
            $0.id != rec.id && $0.name == rec.name && !rec.name.isEmpty
        }
        if !force, saved.contains(where: sameName) {
            throw SaveError.sameNameExists
        }
        if let secret, !secret.isEmpty {
            try? keychain(for: rec.proto)?.set(secret, account: rec.credentialAccount)
            rec.remembers = true
        } else {
            rec.remembers = false
        }
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

    /// 删除条目。**仅当无其他条目共享同凭据（服务+账号）时才 forget Keychain**
    /// （同凭据多条目共享一条 Keychain 的现状使然——误删会让兄弟条目点连失败）。
    func remove(id: String) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        let rec = saved.remove(at: i)
        if !saved.contains(where: { Self.credentialKey($0) == Self.credentialKey(rec) }) {
            try? keychain(for: rec.proto)?.delete(account: rec.credentialAccount)
        }
        persist()
    }

    /// Keychain 孤儿清理：被替换/被移除条目的旧凭据不再被任何在场条目（含新条目自身）
    /// 引用时就地 forget；仍被兄弟条目共享的不清（同旧两 store 的合同）。
    /// 统一表混装三协议 → 存活判定必须含服务名（同账号串分属两服务不算共享）。
    private func forgetOrphanedSecrets(_ victims: [RemoteConnectionRecord], kept: RemoteConnectionRecord) {
        var live = Set(saved.map(Self.credentialKey))
        live.insert(Self.credentialKey(kept))
        for v in victims where !live.contains(Self.credentialKey(v)) {
            try? keychain(for: v.proto)?.delete(account: v.credentialAccount)
        }
    }

    private static func credentialKey(_ r: RemoteConnectionRecord) -> String {
        "\(r.service)|\(r.credentialAccount)"
    }

    private func keychain(for proto: RemoteProto) -> KeychainLike? { keychains[proto] }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: Self.storeKey)
    }
}
