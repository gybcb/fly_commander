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

// MARK: - ConnectionStore（最近连接 + 活动表；不真连接的部分）

final class ConnectionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: ConnectionStore!

    override func setUp() {
        suiteName = "fly.connectionstore.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        store = ConnectionStore(defaults: defaults)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
    }

    func testRecentConnectionsDedupAndOrder() {
        func rec(_ host: String, _ port: UInt16) -> SFTPConnectionRecord {
            SFTPConnectionRecord(host: host, port: port, username: "u", auth: .password)
        }
        store.touchRecent(rec("a", 22))
        store.touchRecent(rec("b", 22))
        // 同 host:port:user 重复 → 置顶且不重复
        store.touchRecent(rec("a", 22))
        XCTAssertEqual(store.recentConnections.map(\.host), ["a", "b"])

        // 持久化：新 store 同 defaults 读回
        let store2 = ConnectionStore(defaults: defaults)
        XCTAssertEqual(store2.recentConnections.map(\.host), ["a", "b"])

        // 超过 10 条裁剪
        for i in 0..<12 { store2.touchRecent(rec("h\(i)", 22)) }
        XCTAssertEqual(store2.recentConnections.count, 10)
    }

    func testRemoveRecent() {
        store.touchRecent(SFTPConnectionRecord(host: "a", port: 22, username: "u", auth: .password))
        store.touchRecent(SFTPConnectionRecord(host: "b", port: 22, username: "u", auth: .password))
        store.removeRecent(account: "a:22:u")
        XCTAssertEqual(store.recentConnections.map(\.host), ["b"])
    }

    /// 失败连接不污染活动表/最近列表（用不可达端口快速失败；不依赖真实网络）。
    func testFailedConnectionLeavesNoState() {
        let request = ConnectionRequest(host: "127.0.0.1", port: 1, username: "u",
                                        auth: .password, secret: "x")
        XCTAssertThrowsError(try store.connect(request))
        XCTAssertTrue(store.activeIDs.isEmpty, "失败连接不应留在活动表")
        XCTAssertTrue(store.recentConnections.isEmpty, "失败连接不应进最近列表")
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
        // remember: true 使凭据写入 Keychain，transferSource 能回读
        let rememberRequest = ConnectionRequest(host: "127.0.0.1", port: UInt16(server.port),
                                                username: server.username, auth: .keyFile,
                                                keyPath: server.keyPath, secret: server.keyPassphrase,
                                                remember: true)
        let (browseSource, _) = try store.connect(rememberRequest)
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
            return XCTFail("transferSource 应返回独立 SFTPSource（Keychain 已记住凭据）")
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
