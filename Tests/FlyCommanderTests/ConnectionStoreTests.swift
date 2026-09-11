import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T5 单测：
/// - SFTPConnectionRecord：Codable 往返、sourceID/credentialAccount 一致性、config 还原（不含密钥）；
/// - CredentialsStore：KeychainLike fake 上的存/取/忘语义；
/// - ConnectionStore：最近连接置顶去重/持久化（UserDefaults 隔离）、活动表注册/断开。
final class ConnectionRecordTests: XCTestCase {
    func testRecordRoundTripAndIdentity() throws {
        let record = SFTPConnectionRecord(host: "example.com", port: 2222,
                                          username: "bob", auth: .keyFile,
                                          keyPath: "/home/bob/.ssh/id_ed25519",
                                          remembers: true)
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(SFTPConnectionRecord.self, from: data)
        XCTAssertEqual(decoded, record)

        XCTAssertEqual(record.sourceID, "sftp://example.com:2222")
        XCTAssertEqual(record.credentialAccount, "example.com:2222:bob")
        XCTAssertEqual(record.displayName, "example.com:2222/bob")

        // 默认 22 端口不进 sourceID
        let plain = SFTPConnectionRecord(host: "h", port: 22, username: "u", auth: .password)
        XCTAssertEqual(plain.sourceID, "sftp://h")

        // config 还原：record 本身不含密钥，secret 参数注入
        let pwRecord = SFTPConnectionRecord(host: "h", port: 22, username: "u", auth: .password)
        let pwConfig = pwRecord.config(secret: "s3cret")
        XCTAssertEqual(pwConfig, SFTPConnectionConfig(host: "h", port: 22, username: "u",
                                                      auth: .password("s3cret")))
        // 序列化产物不含密码
        let pwRemember = SFTPConnectionRecord(host: "h", port: 22, username: "u",
                                              auth: .password, remembers: true)
        let payload = String(data: try JSONEncoder().encode(pwRemember), encoding: .utf8)!
        XCTAssertFalse(payload.contains("s3cret"), "记录 JSON 不得含密码")
    }

    /// 旧「最近连接」JSON（无 name/id）→ 自动导入为已保存条目：name=摘要兜底、
    /// id=新 UUID 且稳定（往返不再变）。兼容解码是「零迁移」拍板的唯一实现点。
    func testLegacyJSONDecodesAsSavedEntry() throws {
        let legacy = Data(#"[{"host":"h","port":22,"username":"u","auth":"password","remembers":true}]"#.utf8)
        let list = try JSONDecoder().decode([SFTPConnectionRecord].self, from: legacy)
        XCTAssertEqual(list.count, 1)
        let r = list[0]
        XCTAssertEqual(r.name, "h/u", "缺 name → displayName 兜底")
        XCTAssertFalse(r.id.isEmpty, "缺 id → 生成非空 UUID")
        XCTAssertTrue(r.remembers)
        // 往返：name/id 已固化，二次解码值不变
        let again = try JSONDecoder().decode([SFTPConnectionRecord].self,
                                             from: try JSONEncoder().encode(list))
        XCTAssertEqual(again, list)
    }

    func testRequestBuildsConfig() {
        let req = ConnectionRequest(host: "h", port: 22, username: "u",
                                    auth: .keyFile, keyPath: "/k",
                                    secret: "pp", remember: false)
        XCTAssertEqual(req.config, SFTPConnectionConfig(host: "h", port: 22, username: "u",
                                                        auth: .keyFile(path: "/k", passphrase: "pp")))
        XCTAssertFalse(req.record.remembers)
    }
}

// MARK: - KeychainLike fake（内存实现，避免真 Keychain 弹授权框）

final class FakeKeychain: KeychainLike {
    var items: [String: String] = [:]
    var setCalls = 0
    var deleteCalls = 0

    func set(_ value: String, account: String) throws {
        setCalls += 1
        items[account] = value
    }

    func get(account: String) throws -> String? { items[account] }

    func delete(account: String) throws {
        deleteCalls += 1
        items[account] = nil
    }
}

final class CredentialsStoreTests: XCTestCase {
    private func config(_ auth: SFTPConnectionConfig.Auth = .password("x")) -> SFTPConnectionConfig {
        SFTPConnectionConfig(host: "h1", port: 22, username: "u1", auth: auth)
    }

    func testSaveLoadForget() throws {
        let fake = FakeKeychain()
        let store = CredentialsStore(keychain: fake)
        let c = config(.password("pw-123"))

        XCTAssertNil(try store.load(for: c))
        try store.save("pw-123", for: c)
        XCTAssertEqual(try store.load(for: c), "pw-123")
        // 覆盖保存（先删后加，不报 duplicate）
        try store.save("pw-456", for: c)
        XCTAssertEqual(try store.load(for: c), "pw-456")
        try store.forget(for: c)
        XCTAssertNil(try store.load(for: c))
        // 幂等删除不报错
        try store.forget(for: c)
    }

    func testAccountKeysIsolatedPerHostPortUser() throws {
        let fake = FakeKeychain()
        let store = CredentialsStore(keychain: fake)
        let a = SFTPConnectionConfig(host: "h1", port: 22, username: "u1", auth: .password("1"))
        let b = SFTPConnectionConfig(host: "h1", port: 2222, username: "u1", auth: .password("2"))
        let c = SFTPConnectionConfig(host: "h2", port: 22, username: "u1", auth: .password("3"))
        try store.save("1", for: a)
        try store.save("2", for: b)
        try store.save("3", for: c)
        XCTAssertEqual(try store.load(for: a), "1")
        XCTAssertEqual(try store.load(for: b), "2")
        XCTAssertEqual(try store.load(for: c), "3")
        XCTAssertEqual(fake.items.count, 3)
    }
}

// MARK: - ConnectionStore（已保存列表 + 活动表；不真连接的部分）

final class ConnectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: FakeKeychain!
    private var store: ConnectionStore!

    override func setUp() {
        suiteName = "fly.connectionstore.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        keychain = FakeKeychain()
        store = ConnectionStore(credentials: CredentialsStore(keychain: keychain), defaults: defaults)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        store = nil
    }

    private func rec(_ host: String, _ port: UInt16 = 22,
                     name: String = "", id: String = UUID().uuidString) -> SFTPConnectionRecord {
        SFTPConnectionRecord(name: name, id: id, host: host, port: port, username: "u", auth: .password)
    }

    func testSaveNewInsertsAtHead() throws {
        _ = try store.save(rec("a", name: "A"), secret: nil)
        _ = try store.save(rec("b", name: "B"), secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.name), ["B", "A"], "新条目置顶")
        // 持久化：新 store 同 defaults 读回
        let store2 = ConnectionStore(credentials: CredentialsStore(keychain: FakeKeychain()), defaults: defaults)
        XCTAssertEqual(store2.savedConnections.map(\.host), ["b", "a"])
    }

    /// 同 id 覆盖=原位替换（列表位置不变，与「新建置顶」可区分）。
    func testSaveByIdOverwritesInPlace() throws {
        let a = rec("a", name: "A", id: "id-a")
        _ = try store.save(a, secret: nil)
        _ = try store.save(rec("z", name: "Z"), secret: nil)
        var edited = a
        edited.host = "a2"
        edited.name = "A2"
        _ = try store.save(edited, secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.name), ["Z", "A2"], "覆盖不改位置")
        XCTAssertEqual(store.savedConnections.count, 2)
    }

    func testSavedCappedAtTen() throws {
        for i in 0..<10 { _ = try store.save(rec("h\(i)", name: "n\(i)"), secret: nil) }
        XCTAssertEqual(store.savedConnections.count, 10)
        XCTAssertThrowsError(try store.save(rec("overflow", name: "over"), secret: nil)) { e in
            XCTAssertEqual(e as? ConnectionStore.SaveError, .listFull)
        }
        XCTAssertEqual(store.savedConnections.count, 10, "拒存不改列表")
    }

    func testSameNameRejectedWithoutForceReplacesInPlaceWithForce() throws {
        _ = try store.save(rec("a", name: "dup"), secret: nil)
        XCTAssertThrowsError(try store.save(rec("b", name: "dup"), secret: nil)) { e in
            XCTAssertEqual(e as? ConnectionStore.SaveError, .sameNameExists)
        }
        // force=原位覆盖同名条目（不是追加第二条）
        let replaced = try store.save(rec("b", name: "dup"), secret: nil, force: true)
        XCTAssertEqual(store.savedConnections.count, 1)
        XCTAssertEqual(store.savedConnections[0].host, "b")
        XCTAssertEqual(store.savedConnections[0].id, replaced.id)
        // 空名不参与同名校验（两条无名条目可共存）
        _ = try store.save(rec("c", name: ""), secret: nil)
        _ = try store.save(rec("d", name: ""), secret: nil)
    }

    /// 选中条目改名撞**其他条目**同名 + force 确认 → 原位覆盖自身+移除撞名条目。
    /// 评审轮 confirmed：修前 force 分支先按同名命中把 rec 写进 beta 的槽，rec 仍带
    /// id-A，与被选条目原槽形成**两个同 id**；remove 只删首个 → 另一个成永久孤儿
    /// （UI 无法再删，重启后依旧）。修法=同 id 命中优先（编辑自身语义），force 时
    /// 再清掉**其他**同名条目。
    /// 变异证伪（红面映射）：把 ConnectionStore.save 分支恢复为「sameName 命中先」
    /// 原顺序 → 本条 ids 唯一性断言红（出现重复 id）+ remove 后 count 断言红。
    func testSelectedRenameCollisionForceLeavesNoDuplicateID() throws {
        _ = try store.save(rec("a", name: "alpha", id: "id-A"), secret: nil)
        _ = try store.save(rec("b", name: "beta", id: "id-B"), secret: nil)
        // UI 实况：选中 alpha 行（selectedRecordID=id-A）→ 表单改名 "beta" → 确认覆盖
        let edited = rec("a", name: "beta", id: "id-A")
        XCTAssertThrowsError(try store.save(edited, secret: nil)) { e in
            XCTAssertEqual(e as? ConnectionStore.SaveError, .sameNameExists)
        }
        _ = try store.save(edited, secret: nil, force: true)
        let after = store.savedConnections
        XCTAssertEqual(after.count, 1, "撞名条目被覆盖移除，不追加")
        XCTAssertEqual(Set(after.map(\.id)).count, after.count, "id 唯一（修前此处红=双 id-A）")
        XCTAssertEqual(after[0].id, "id-A", "保留被选中改名字条目自身的 id")
        // 孤儿锁：删掉唯一条目后列表必空（修前 remove(id-A) 后残留第二个 id-A）
        store.remove(id: "id-A")
        XCTAssertTrue(store.savedConnections.isEmpty, "无孤儿残留")
    }

    /// 评审轮 confirmed：就地覆盖换 host/端口/用户名 = 换 Keychain 账号，旧账号若不再被
    /// 任何在场条目引用必须就地 forget——否则旧密文永久滞留、无列表路径可达
    /// （「删了连接=删了密码」成假）。共享账号的兄弟条目在场时不清（同 remove 合同）。
    /// 变异证伪（红面映射）：删 ConnectionStore.save 三处 forgetOrphanedSecrets 调用
    /// （或把 helper 体清空）→ 换参数覆盖后 keychain.items 仍含旧账号 → 第一条断言红；
    /// 兄弟共享断言不受影响（它走 remove 的条件 forget 路）。
    func testInPlaceEditChangingParamsForgetsOrphanedAccount() throws {
        let saved = try store.save(rec("h1", name: "E"), secret: "pw1")
        XCTAssertEqual(keychain.items[saved.credentialAccount], "pw1")
        // 单击载入后改 host（同 id 原位覆盖路，密码换值）
        var edited = saved
        edited.host = "h2"
        _ = try store.save(edited, secret: "pw2")
        XCTAssertNil(keychain.items["h1:22:u"], "旧账号孤儿 → 就地 forget")
        XCTAssertEqual(keychain.items["h2:22:u"], "pw2", "新账号落 Keychain")
        XCTAssertEqual(keychain.deleteCalls, 1)
        // 兄弟共享：删掉 h2 条目但 h3（同 credentialAccount）仍在 → 不 forget
        _ = try store.save(SFTPConnectionRecord(name: "S", host: "h2", port: 22, username: "u", auth: .password), secret: "pw2")
        store.remove(id: edited.id)
        XCTAssertEqual(keychain.deleteCalls, 1, "h2:22:u 仍被兄弟引用 → 不得 forget")
        XCTAssertEqual(keychain.items["h2:22:u"], "pw2")
    }

    /// 删除独占凭据条目 → forget Keychain；兄弟条目共享同 credentialAccount 时不误删。
    func testRemoveForgetsKeychainOnlyWhenAccountUnshared() throws {
        let secret = "pw-shared"
        // 两条目同 host:port:user（同 credentialAccount），不同 name
        let r1 = try store.save(rec("h", name: "one"), secret: secret)
        let r2 = try store.save(rec("h", name: "two"), secret: secret)
        XCTAssertEqual(keychain.items[r1.credentialAccount], secret)
        store.remove(id: r1.id)
        XCTAssertEqual(keychain.deleteCalls, 0, "仍被 r2 共享 → 不 forget")
        XCTAssertEqual(keychain.items[r2.credentialAccount], secret)
        store.remove(id: r2.id)
        XCTAssertEqual(keychain.deleteCalls, 1, "最后一条删 → forget")
        XCTAssertNil(keychain.items[r2.credentialAccount])
        XCTAssertTrue(store.savedConnections.isEmpty)
    }

    /// secret 非空 → remembers=true 且密钥只进 Keychain，UserDefaults JSON 永不含明文。
    func testSaveWritesSecretToKeychainNeverToDefaults() throws {
        let rec1 = try store.save(rec("h", name: "n"), secret: "s3cr3t-xyz")
        XCTAssertTrue(rec1.remembers)
        XCTAssertEqual(keychain.items[rec1.credentialAccount], "s3cr3t-xyz")
        let raw = String(data: defaults.data(forKey: "sftp.recentConnections")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("s3cr3t"), "列表 JSON 不得含密码")
        // secret 为 nil → remembers=false 且不写 Keychain
        let rec2 = try store.save(rec("h2", name: "n2"), secret: nil)
        XCTAssertFalse(rec2.remembers)
    }

    func testLoadSecretRoundTrip() throws {
        let saved = try store.save(rec("h", name: "n"), secret: "pw")
        XCTAssertEqual(try store.loadSecret(for: saved), "pw")
    }

    /// 连接失败不污染活动表/已保存列表/Keychain（成败都不自动写 = 拍板①的核心锁）。
    func testFailedConnectionLeavesNoState() {
        let request = ConnectionRequest(host: "127.0.0.1", port: 1, username: "u",
                                        auth: .password, secret: "x", remember: true)
        XCTAssertThrowsError(try store.connect(request))
        XCTAssertTrue(store.activeIDs.isEmpty, "失败连接不应留在活动表")
        XCTAssertTrue(store.savedConnections.isEmpty, "connect 不写已保存列表")
        XCTAssertEqual(keychain.setCalls, 0, "connect 不写 Keychain")
    }
}

// MARK: - e2e：真实 sshd 上的连接编排（复用 T4 fixture）

final class ConnectionStoreE2ETests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ConnectionStore!

    override func setUpWithError() throws {
        suiteName = "fly.connectione2e.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        fixture = SFTPServerFixture()
        guard let live = fixture.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        server = live
        store = ConnectionStore(defaults: defaults)
    }

    override func tearDown() {
        store?.disconnectAll()
        store = nil
        fixture?.cleanup()
        fixture = nil
        server = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
    }

    private func keyRequest() -> ConnectionRequest {
        ConnectionRequest(host: "127.0.0.1", port: UInt16(server.port),
                          username: server.username, auth: .keyFile,
                          keyPath: server.keyPath, secret: server.keyPassphrase,
                          remember: false)
    }

    func testConnectResolvesHomeAndLists() throws {
        let (source, home) = try store.connect(keyRequest())
        XCTAssertTrue(home.hasPrefix("/"), "远端 home 应为绝对路径：\(home)")
        XCTAssertEqual(source.homeDirectory, home)
        // 活动表已注册（sourceID 键）
        XCTAssertTrue(store.activeIDs.contains(source.sourceID))
        // 在 fixture 工作区写一个文件并列出（home 是真实用户主目录，不便断言其内容）
        let work = server.remoteBase.path
        var sent = false
        try source.streamWrite(TCPath("sftp://127.0.0.1:\(server.port)\(work)/t5_probe.txt"),
                               totalBytes: 5) {
            if sent { return Data() }
            sent = true
            return Data("hello".utf8)
        }
        let items = try source.listDirectory(TCPath("sftp://127.0.0.1:\(server.port)\(work)"))
        XCTAssertEqual(items.map(\.name), ["t5_probe.txt"])
        XCTAssertEqual(items.first?.size, 5)
    }

    func testReuseSameSourceForSameEndpoint() throws {
        let first = try store.connect(keyRequest())
        let second = try store.connect(keyRequest())
        XCTAssertTrue(first.0 === second.0, "同 host:port 应复用同一 SFTPSource")
        XCTAssertEqual(first.0.sourceID, second.0.sourceID)
    }

    func testDisconnectRemovesActiveSource() throws {
        let (source, _) = try store.connect(keyRequest())
        let id = source.sourceID
        XCTAssertTrue(store.source(for: id) !== nil)
        store.disconnect(id)
        XCTAssertNil(store.source(for: id))
        // 断开后可重连：新源实例，连接在其内部按需重建（惰性语义）
        let again = try store.connect(keyRequest())
        XCTAssertFalse(again.0 === source, "disconnect 后重连应建新的源实例")
        _ = try again.0.stat(TCPath("sftp://127.0.0.1:\(server.port)/"))
    }

    /// T2 e2e：transferSource 返回独立连接，可独立执行 copyItem，
    /// 且关闭后不影响浏览源。
    func testTransferSourceReturnsIndependentConnection() throws {
        // passphrase 在连接时已进内存 config → transferSource 直接复用（旧 remember/Keychain 路已退役）。
        let request = ConnectionRequest(host: "127.0.0.1", port: UInt16(server.port),
                                        username: server.username, auth: .keyFile,
                                        keyPath: server.keyPath, secret: server.keyPassphrase)
        let (browseSource, _) = try store.connect(request)
        let id = browseSource.sourceID
        let work = server.remoteBase.path

        // 先在 fixture 工作区写一个源文件
        let srcPath = TCPath("sftp://127.0.0.1:\(server.port)\(work)/t2_src.txt")
        var sent = false
        try browseSource.streamWrite(srcPath, totalBytes: 6) {
            if sent { return Data() }
            sent = true
            return Data("hello!".utf8)
        }

        // transferSource 应返回独立连接（非 nil，且不同于浏览源实例）
        guard let transferSrc = store.transferSource(for: id) else {
            return XCTFail("transferSource 应返回独立 SFTPSource（passphrase 在内存 config 中）")
        }
        XCTAssertFalse(transferSrc === browseSource, "transferSource 必须是独立实例")
        XCTAssertEqual(transferSrc.sourceID, browseSource.sourceID, "sourceID 应一致（同源判定用）")
        XCTAssertEqual(transferSrc.homeDirectory, browseSource.homeDirectory, "home 应复制浏览源值")

        // 用 transferSource 执行 copyItem（独立连接，证明可用）
        let dstPath = TCPath("sftp://127.0.0.1:\(server.port)\(work)/t2_dst.txt")
        try transferSrc.copyItem(from: srcPath, to: dstPath)
        let items = try browseSource.listDirectory(TCPath("sftp://127.0.0.1:\(server.port)\(work)"))
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("t2_src.txt"), "源文件应存在")
        XCTAssertTrue(names.contains("t2_dst.txt"), "copyItem 目标应存在")

        // 关闭 transferSource 不影响浏览源
        transferSrc.closeConnection()
        let probe = try browseSource.stat(TCPath("sftp://127.0.0.1:\(server.port)\(work)/t2_src.txt"))
        XCTAssertNotNil(probe, "transferSource.closeConnection 后浏览源仍应可用")
    }

    /// 无活动源时 transferSource 应返回 nil。
    func testTransferSourceWithNoActiveSourceReturnsNil() {
        XCTAssertNil(store.transferSource(for: "sftp://nonexistent:22"),
                     "无活动源时应返回 nil")
    }
}
