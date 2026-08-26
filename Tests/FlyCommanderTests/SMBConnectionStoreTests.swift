import XCTest
@testable import FlyCommander
import TCCore

/// fake 挂载管理器：mount 造一个 temp 目录当挂载点，返回其 URL；记录 unmount 调用。
final class FakeMountManager: SMBMountManagerLike {
    var mounted: [String: URL] = [:]
    var unmounted: [String] = []
    func mount(_ config: SMBConnectionConfig, secret: String?) throws -> URL {
        if let u = mounted[config.sourceID] { return u }
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake_smb_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        mounted[config.sourceID] = u
        return u
    }
    func unmount(_ mp: URL) throws { unmounted.append(mp.path) }
}

final class SMBConnectionStoreTests: XCTestCase {
    private func fakeDefaults() -> UserDefaults {
        let s = "smbtest_\(UUID().uuidString)"
        return UserDefaults(suiteName: s)!
    }

    func testConnectReusesSameSourceID() throws {
        let mm = FakeMountManager()
        let store = SMBConnectionStore(mountManager: mm,
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil, username: "u", secret: "p")
        let (a, _) = try store.connect(req)
        let (b, _) = try store.connect(req)
        XCTAssertTrue(a === b, "同 sourceID 复用同一 source 实例")
        XCTAssertEqual(mm.mounted.count, 1, "只挂一次")
    }

    func testDisconnectUnmountsAndRemoves() throws {
        let mm = FakeMountManager()
        let store = SMBConnectionStore(mountManager: mm,
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil, username: "u", secret: "p")
        let (src, home) = try store.connect(req)
        XCTAssertEqual(home.pathString, "/s", "home = share 根")
        store.disconnect(src.sourceID)
        XCTAssertEqual(mm.unmounted.count, 1)
        XCTAssertNil(store.source(for: src.sourceID))
    }

    func testRecentConnectionDedupAndNoSecret() throws {
        let d = fakeDefaults()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: d)
        let r1 = SMBConnectionRecord(server: "h", share: "s", domain: nil, username: "u", remembers: true)
        let r2 = SMBConnectionRecord(server: "h", share: "s", domain: nil, username: "u")
        store.touchRecent(r1)
        store.touchRecent(r2)   // 同 credentialAccount → 去重
        XCTAssertEqual(store.recentConnections.count, 1)
        // 重启（新实例同 defaults）仍能读回
        let store2 = SMBConnectionStore(mountManager: FakeMountManager(),
                                        credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                        defaults: d)
        XCTAssertEqual(store2.recentConnections.count, 1)
        XCTAssertEqual(store2.recentConnections[0].server, "h")
    }

    func testRememberedSecretGoesToKeychainAndNeverToRecent() throws {
        let d = fakeDefaults()
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: d)
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", secret: "s3cr3t-xyz", remember: true)
        _ = try store.connect(req)
        let account = req.record.credentialAccount
        XCTAssertEqual(try kc.get(account: account), "s3cr3t-xyz", "记住 → 密码进 Keychain")
        // 最近连接（UserDefaults 持久化）绝不含密码
        let raw = String(data: d.data(forKey: "smb.recentConnections")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("s3cr3t-xyz"), "recent JSON 不得含密码")
        XCTAssertFalse(raw.contains("s3cr3t"), "recent JSON 不得含密码片段")
    }

    func testUnrememberedConnectDeletesExistingCredential() throws {
        let kc = FakeKeychain()
        let credStore = SMBCredentialsStore(keychain: kc)
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: credStore,
                                       defaults: fakeDefaults())
        let config = SMBConnectionConfig(server: "h", share: "s", domain: nil, username: "u")
        try credStore.save("old-pass", for: config)
        XCTAssertEqual(try kc.get(account: config.credentialAccount), "old-pass")
        // 未勾选"记住" → 清掉该账号既有凭据
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", secret: "tmp-pass")
        _ = try store.connect(req)
        XCTAssertNil(try kc.get(account: config.credentialAccount), "未记住 → 删除既有凭据")
        XCTAssertEqual(kc.deleteCalls, 1)
    }

    func testRememberWithoutSecretDoesNotSave() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", remember: true)   // 无密码
        _ = try store.connect(req)
        XCTAssertEqual(kc.setCalls, 0, "secret 为 nil 时不得写入 Keychain")
        XCTAssertNil(try kc.get(account: req.record.credentialAccount))
    }

    func testRecentCappedAtTen() throws {
        let d = fakeDefaults()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: d)
        for i in 0..<15 {
            store.touchRecent(SMBConnectionRecord(server: "h\(i)", share: "s", domain: nil, username: "u"))
        }
        XCTAssertEqual(store.recentConnections.count, 10, "最近连接最多 10 条")
        XCTAssertEqual(store.recentConnections[0].server, "h14", "最新在前")
        XCTAssertEqual(store.recentConnections[9].server, "h5")
    }

    func testLoadSecretRoundTrip() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", secret: "pw", remember: true)
        _ = try store.connect(req)
        XCTAssertEqual(try store.loadSecret(for: req.record), "pw")
    }

    /// service 隔离：SMB 门面默认挂 "FlyCommander.smb"，与 SFTP 的 "FlyCommander.sftp" 不串。
    /// 只读 service 字符串，不触发任何 SecItem 调用（hermetic）。
    func testDefaultServiceIsSMBNotSFTP() {
        let kc = SMBCredentialsStore().keychain as? KeychainCredentialsStore
        XCTAssertEqual(kc?.service, "FlyCommander.smb")
        XCTAssertNotEqual(kc?.service, "FlyCommander.sftp")
    }
}
