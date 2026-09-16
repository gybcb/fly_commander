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
    /// 已保存连接（显式 save 才进；storeKey 沿用旧键=旧最近连接 JSON 自动导入）。
    private var saved: [SFTPConnectionRecord] = []
    private let credentials: CredentialsStore
    private let defaults: UserDefaults
    private let storeKey = "sftp.recentConnections"

    init(credentials: CredentialsStore = CredentialsStore(),
         defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([SFTPConnectionRecord].self, from: data) {
            saved = list
        }
    }

    /// 建立（或复用）到 host:port 的连接：建源 → 连接 → 解析远端 home。
    /// **连接成败都不写已保存列表、不动 Keychain**（issue「保存连接列表」：
    /// 旧 touchRecent 自动路已删——列表条目只经 save 显式进入；
    /// Keychain 写入并入 save，取消勾选即 forget 的旧语义随复选框一并退役）。
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

    /// 丢弃全部活动源的**内层连接**（系统唤醒用）——不移除表项：窗格直接持有同一
    /// SFTPSource 实例，closeConnection 只清死连接，下次操作懒重建（对齐懒重连语义）。
    func closeAllConnections() {
        for s in sources.values { s.closeConnection() }
    }

    var activeIDs: [String] { sources.keys.sorted() }
    var savedConnections: [SFTPConnectionRecord] { saved }

    /// 回读已记住的密码/passphrase（条目 remembers 时供单击载入回填表单）。
    func loadSecret(for record: SFTPConnectionRecord) throws -> String? {
        try credentials.load(for: record.config(secret: nil))
    }

    // MARK: - 凭据 / 已保存连接

    /// 保存错误（VC 层映射 statusLabel 文案）。
    enum SaveError: Error, Equatable {
        case listFull            // cap 10：新条目拒存
        case sameNameExists      // 无选中保存且同名：VC 已确认覆盖时带 force 重试
    }

    /// 显式保存。语义（拍板①）：只有走到这里列表才变。
    /// - 同 id=原地覆盖（位置不变，改名/改参数/改密钥都走这条）；
    /// - 新 id=置顶；超 cap 拒存（saveFullError），VC 提示先删。
    /// - secret 非空 → 写 Keychain 且 remembers=true；nil → 不写并 remembers=false。
    ///   被覆盖/被移除条目若换掉了 credentialAccount（改 host/端口/用户名）→ 旧账号
    ///   无人引用时就地 forget（forgetOrphanedSecrets），仍被共享的不清。
    /// - 同名（排除自身 id）且未 force → .sameNameExists；force=原位替换该同名条目
    ///   （批准计划「确认覆盖既有同名条目」——不是又追加一条）。
    @discardableResult
    func save(_ record: SFTPConnectionRecord, secret: String?, force: Bool = false) throws -> SFTPConnectionRecord {
        var rec = record
        if rec.id.isEmpty { rec.id = UUID().uuidString }
        let sameName: (SFTPConnectionRecord) -> Bool = {
            $0.id != rec.id && $0.name == rec.name && !rec.name.isEmpty
        }
        if !force, saved.contains(where: sameName) {
            throw SaveError.sameNameExists
        }
        if let secret, !secret.isEmpty {
            try? credentials.save(secret, for: rec.config(secret: nil))
            rec.remembers = true
        } else {
            rec.remembers = false
        }
        // 三分支落位（同名 force 覆盖的语义见下）：
        // ① 选中项在编辑（rec.id 命中既有条目）→ 原位覆盖该条目；若 force 且**另有条目**
        //    占用同名，一并移除之（用户确认「覆盖既有同名条目」=删掉那条 beta，
        //    保留被选中改名的条目并保持其自身 id/位置）——否则会把 rec 写进 beta 的槽，
        //    与被选条目的原槽形成**两个同 id**（remove 只删首个 → 另一个成孤儿）。
        // ② 无选中（rec.id=新 UUID 未命中）且同名命中 → 原位替换该同名条目（原 beta 就地
        //    换成新条目，id 换新，不追加）。
        // ③ 都不命中 → 新 id 置顶（超 cap 拒存）。
        // 被替换/被移除的条目交给 forgetOrphanedSecrets 做 Keychain 孤儿清理（评审 confirmed）。
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
    static let savedCap = 10

    /// Keychain 孤儿清理（评审轮 confirmed）：Keychain 键=credentialAccount，
    /// 「编辑已保存条目的 host/port/username」=换 Keychain 行——被替换/被移除条目
    /// 的旧账号若不再被任何在场条目（含新条目自身）引用，就地 forget。
    /// 否则「删了连接=删了密码」是假的：旧密文永久滞留且列表内无路径可达。
    /// 仍被兄弟条目共享的账号不清（与 remove(id:) 的条件 forget 同一合同）。
    private func forgetOrphanedSecrets(_ victims: [SFTPConnectionRecord], kept: SFTPConnectionRecord) {
        var live = Set(saved.map(\.credentialAccount))
        live.insert(kept.credentialAccount)
        for v in victims where !live.contains(v.credentialAccount) {
            try? credentials.forget(for: v.config(secret: nil))
        }
    }

    /// 删除条目。**仅当无其他条目共享同 credentialAccount 时才 forget Keychain**
    /// （同凭据多条目共享一条 Keychain 的现状使然——误删会让兄弟条目点连失败）。
    func remove(id: String) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        let rec = saved.remove(at: i)
        if !saved.contains(where: { $0.credentialAccount == rec.credentialAccount }) {
            try? credentials.forget(for: rec.config(secret: nil))
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
