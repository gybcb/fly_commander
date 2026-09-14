import XCTest
@testable import FlyCommander
import TCCore

/// 统一「已保存连接」门面的合同锁（取代 ConnectionStore / SMBConnectionStore 的
/// 列表 + Keychain 职责）。三件事必须锁死：
/// ① 旧两列表键一次性迁入新键，**旧键保留不删**（回滚/排障可见）；
/// ② Keychain 坐标（服务名 + 账号）**逐字沿用各协议现状** → 存量密文无需改写即可回读；
/// ③ 统一表混装三协议 → 凭据共享/孤儿判定必须含服务名（同账号串分属两服务不算共享）。
final class RemoteConnectionStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var sftpKC: FakeKeychain!
    private var smbKC: FakeKeychain!
    private var ftpKC: FakeKeychain!

    override func setUp() {
        super.setUp()
        L10n.current = .en
        suiteName = "fly.remotestore.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        sftpKC = FakeKeychain(); smbKC = FakeKeychain(); ftpKC = FakeKeychain()
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        sftpKC = nil; smbKC = nil; ftpKC = nil
        L10n.current = .en
        super.tearDown()
    }

    private func makeStore() -> RemoteConnectionStore {
        RemoteConnectionStore(keychains: [.sftp: sftpKC, .smb: smbKC, .ftp: ftpKC], defaults: defaults)
    }

    // MARK: - ① 迁移

    /// 旧 sftp + smb 两列表键 → 新键；旧键**原样保留**（不删）。
    func testMigratesBothLegacyKeysOnceAndKeepsThem() throws {
        let sftpLegacy = try JSONEncoder().encode([
            SFTPConnectionRecord(name: "dev", id: "s-1", host: "h", port: 22, username: "bob", auth: .password),
        ])
        let smbLegacy = try JSONEncoder().encode([
            SMBConnectionRecord(name: "nas", id: "m-1", server: "tru", share: "dl", domain: nil, username: "u"),
        ])
        defaults.set(sftpLegacy, forKey: RemoteConnectionStore.legacySFTPKey)
        defaults.set(smbLegacy, forKey: RemoteConnectionStore.legacySMBKey)

        let store = makeStore()
        XCTAssertEqual(store.savedConnections.count, 2, "两旧表都须迁入")
        XCTAssertEqual(Set(store.savedConnections.map(\.proto)), [.sftp, .smb])
        XCTAssertEqual(store.record(forSourceID: "sftp://h")?.id, "s-1", "id 逐字保留（收藏重连依赖）")
        XCTAssertEqual(store.record(forSourceID: "smb://tru/dl")?.name, "nas")
        // 迁移后已落新键
        XCTAssertNotNil(defaults.data(forKey: RemoteConnectionStore.storeKey))
        // 旧键仍在（变异证伪： migrate 里加 removeObject → 本断言红）
        XCTAssertNotNil(defaults.data(forKey: RemoteConnectionStore.legacySFTPKey), "旧 sftp 键不得删")
        XCTAssertNotNil(defaults.data(forKey: RemoteConnectionStore.legacySMBKey), "旧 smb 键不得删")
    }

    /// 新键已存在 → 不再读旧键（迁移只发生一次；变异：把 store 分支改成总 merge → 红）。
    func testNewKeyPresentSkipsMigration() throws {
        let rec = RemoteConnectionRecord(proto: .ftp, id: "f-1", name: "only", host: "fh", port: 990, username: "u")
        defaults.set(try JSONEncoder().encode([rec]), forKey: RemoteConnectionStore.storeKey)
        let legacy = try JSONEncoder().encode([
            SFTPConnectionRecord(name: "dev", id: "s-1", host: "h", port: 22, username: "bob", auth: .password),
        ])
        defaults.set(legacy, forKey: RemoteConnectionStore.legacySFTPKey)

        let store = makeStore()
        XCTAssertEqual(store.savedConnections.count, 1)
        XCTAssertEqual(store.savedConnections.first?.proto, .ftp)
    }

    /// 整表解码失败静默跳过该源（坏数据不得把启动路径带崩；与旧 store 的 `try?` 同容忍度）。
    func testCorruptLegacySourceIsSkippedNotFatal() throws {
        defaults.set(Data("{ not json".utf8), forKey: RemoteConnectionStore.legacySFTPKey)
        let smbLegacy = try JSONEncoder().encode([
            SMBConnectionRecord(name: "nas", id: "m-1", server: "tru", share: "dl", domain: nil, username: "u"),
        ])
        defaults.set(smbLegacy, forKey: RemoteConnectionStore.legacySMBKey)
        let store = makeStore()
        XCTAssertEqual(store.savedConnections.count, 1, "坏源丢弃，好源照常迁入")
        XCTAssertEqual(store.savedConnections.first?.proto, .smb)
    }

    // MARK: - ② Keychain 坐标逐字沿用（存量密文无感可读）

    /// 统一记录的 service/credentialAccount 与旧记录逐字相同（红面=改任一格式串）。
    func testCredentialCoordinatesMatchLegacyRecordsVerbatim() {
        let sftp = SFTPConnectionRecord(name: "dev", id: "s-1", host: "h", port: 2222,
                                        username: "bob", auth: .keyFile, keyPath: "/k")
        XCTAssertEqual(RemoteConnectionRecord(sftp).service, "FlyCommander.sftp")
        XCTAssertEqual(RemoteConnectionRecord(sftp).credentialAccount, sftp.credentialAccount)
        XCTAssertEqual(RemoteConnectionRecord(sftp).sourceID, sftp.sourceID)
        XCTAssertEqual(RemoteConnectionRecord(sftp).paramsSummary, sftp.paramsSummary)

        let smb = SMBConnectionRecord(name: "nas", id: "m-1", server: "tru", share: "dl",
                                      domain: "WG", username: "bob")
        XCTAssertEqual(RemoteConnectionRecord(smb).service, "FlyCommander.smb")
        XCTAssertEqual(RemoteConnectionRecord(smb).credentialAccount, smb.credentialAccount)
        XCTAssertEqual(RemoteConnectionRecord(smb).paramsSummary, smb.paramsSummary)
    }

    /// ftp 与 sftp 同构账号规则，但服务名单独一支（默认端口 21 不进 sourceID）。
    func testFTPServiceIsSeparateButAccountRuleIsomorphic() {
        let ftp = RemoteConnectionRecord(proto: .ftp, id: "f-1", host: "h", port: 21, username: "u")
        XCTAssertEqual(ftp.service, "FlyCommander.ftp")
        XCTAssertEqual(ftp.credentialAccount, "h:21:u")
        XCTAssertEqual(ftp.sourceID, "ftp://h", "默认端口 21 省略")
        XCTAssertEqual(RemoteConnectionRecord(proto: .ftp, id: "f", host: "h", port: 990, username: "u").sourceID,
                       "ftp://h:990")
    }

    /// 迁移后按旧 store 写的密文，能被统一 store 直接回读（不重写任何 Keychain 条目）。
    func testSecretWrittenByLegacyCoordinatesReadsBack() throws {
        sftpKC.items["h:22:bob"] = "legacy-pw"      // 模拟旧 CredentialsStore 已写入的密文
        let legacy = try JSONEncoder().encode([
            SFTPConnectionRecord(name: "dev", id: "s-1", host: "h", port: 22, username: "bob",
                                 auth: .password, remembers: true),
        ])
        defaults.set(legacy, forKey: RemoteConnectionStore.legacySFTPKey)

        let store = makeStore()
        guard let rec = store.record(forSourceID: "sftp://h") else { return XCTFail("条目未迁入") }
        XCTAssertEqual(try store.loadSecret(for: rec), "legacy-pw", "存量密文无需改写即可回读")
        XCTAssertEqual(sftpKC.setCalls, 0, "回读路径绝不重写 Keychain")
    }

    // MARK: - ③ 跨协议凭据隔离 + save 三分支

    /// 同账号串、不同服务（sftp vs ftp 的 `h:22:u` 之类）不算共享 → 删一个不 forget 另一个。
    /// 红面=credentialKey 退化成只含 account（统一表混装协议后必错杀）。
    func testSameAccountStringAcrossProtosIsNotSharedCredential() throws {
        let store = makeStore()
        // 账号串刻意相同：sftp 记录 host=h port=22 username=u → "h:22:u"；
        // 另建一条 proto .ftp，host=h port=22 username=u → 同为 "h:22:u"。
        _ = try store.save(RemoteConnectionRecord(proto: .sftp, id: "s-1", name: "a", host: "h", port: 22, username: "u"), secret: "pw")
        _ = try store.save(RemoteConnectionRecord(proto: .ftp, id: "f-1", name: "b", host: "h", port: 22, username: "u"), secret: "pw")
        XCTAssertEqual(sftpKC.items.count, 1, "sftp 密文落 FlyCommander.sftp")
        XCTAssertEqual(ftpKC.items.count, 1, "ftp 密文落 FlyCommander.ftp（同账号串不同服务）")

        store.remove(id: "s-1")
        XCTAssertEqual(sftpKC.deleteCalls, 1, "sftp 自己无兄弟 → 该 forget")
        XCTAssertEqual(ftpKC.deleteCalls, 0, "ftp 侧同账号串不得被误清（服务隔离）")
    }

    /// save 三分支（选中 id 命中=原位覆盖 / 无命中同名=原位替换 / 都无=新 id 置顶）。
    func testSaveThreeBranchPlacementSemantics() throws {
        let store = makeStore()
        let first = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-1", name: "one", server: "a", share: "s", username: "u"), secret: nil)
        let second = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-2", name: "two", server: "b", share: "s", username: "u"), secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.id), [second.id, first.id], "新条目置顶")
        // 分支①：带既有条目 id 保存 → 原位覆盖（位置与数量都不变）
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-1", name: "one", server: "a2", share: "s", username: "u"), secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.id), [second.id, first.id], "id 命中=原位")
        XCTAssertEqual(store.savedConnections.last?.server, "a2")
        // 分支②：新 id 但同名 → 原位替换同名条目（不追加）
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-9", name: "one", server: "a3", share: "s", username: "u"), secret: nil, force: true)
        XCTAssertEqual(store.savedConnections.count, 2, "同名原位替换不增条")
        XCTAssertEqual(store.savedConnections.last?.id, "m-9", "id 换新")
    }

    /// 同名校验在无 force 时抛 sameNameExists（VC 侧确认覆盖后带 force 重试）。
    func testSameNameRejectedWithoutForce() throws {
        let store = makeStore()
        _ = try store.save(RemoteConnectionRecord(proto: .sftp, id: "s-1", name: "dup", host: "a", port: 22, username: "u"), secret: nil)
        XCTAssertThrowsError(try store.save(
            RemoteConnectionRecord(proto: .sftp, id: "s-2", name: "dup", host: "b", port: 22, username: "u"),
            secret: nil)) { e in
            XCTAssertEqual(e as? RemoteConnectionStore.SaveError, .sameNameExists)
        }
    }

    /// 明文永不下列表键（UserDefaults JSON）。
    func testSecretNeverReachesUserDefaults() throws {
        let store = makeStore()
        _ = try store.save(RemoteConnectionRecord(proto: .ftp, id: "f-1", name: "n", host: "h", port: 990, username: "u"), secret: "topsecret")
        let raw = String(data: defaults.data(forKey: RemoteConnectionStore.storeKey)!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("topsecret"))
        XCTAssertEqual(ftpKC.items["h:990:u"], "topsecret")
    }

    /// remembers=false 的条目不写 Keychain，loadSecret 返 nil。
    func testEmptySecretClearsRemembers() throws {
        let store = makeStore()
        let rec = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-1", name: "n", server: "h", share: "s", username: "u"), secret: "")
        XCTAssertFalse(rec.remembers)
        XCTAssertEqual(smbKC.setCalls, 0)
        XCTAssertNil(try store.loadSecret(for: rec))
    }

    /// record(forSourceID:) 未命中返 nil（收藏重连分支的整个依赖面）。
    func testRecordLookupMissReturnsNil() throws {
        let store = makeStore()
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "m-1", name: "n", server: "h", share: "s", username: "u"), secret: nil)
        XCTAssertNil(store.record(forSourceID: "ftp://nope"))
    }
}
