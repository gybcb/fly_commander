import XCTest
@testable import FlyCommander
import TCCore

/// fake 挂载管理器：mount 造一个 temp 目录当挂载点，返回其 URL；记录 unmount 调用。
final class FakeMountManager: SMBMountManagerLike {
    var mounted: [String: URL] = [:]
    var unmounted: [String] = []
    var mountCalls = 0
    func mount(_ config: SMBConnectionConfig, secret: String?) throws -> URL {
        mountCalls += 1
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
        XCTAssertEqual(mm.mountCalls, 1, "mount 只被调用一次（独立于 memoized fake）")
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

    func testSaveNewInsertsAtHeadAndPersists() throws {
        let d = fakeDefaults()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: d)
        _ = try store.save(SMBConnectionRecord(name: "A", id: "id-a", server: "a", share: "s", domain: nil, username: "u"), secret: nil)
        _ = try store.save(SMBConnectionRecord(name: "B", id: "id-b", server: "b", share: "s", domain: nil, username: "u"), secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.name), ["B", "A"], "新条目置顶")
        // 重启（新实例同 defaults）仍能读回
        let store2 = SMBConnectionStore(mountManager: FakeMountManager(),
                                        credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                        defaults: d)
        XCTAssertEqual(store2.savedConnections.map(\.server), ["b", "a"])
    }

    /// 同 id 覆盖=原位替换（与「新建置顶」可区分）。
    func testSaveByIdOverwritesInPlace() throws {
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        let a = SMBConnectionRecord(name: "A", id: "id-a", server: "a", share: "s", domain: nil, username: "u")
        _ = try store.save(a, secret: nil)
        _ = try store.save(SMBConnectionRecord(name: "Z", server: "z", share: "s", domain: nil, username: "u"), secret: nil)
        var edited = a
        edited.server = "a2"; edited.name = "A2"
        _ = try store.save(edited, secret: nil)
        XCTAssertEqual(store.savedConnections.map(\.name), ["Z", "A2"], "覆盖不改位置")
    }

    /// connect 成败都不写已保存列表、不动 Keychain（拍板①「彻底取代」核心锁）。
    func testConnectWritesNoSavedEntryOrKeychain() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "h", share: "s", domain: nil,
                                       username: "u", secret: "s3cr3t-xyz", remember: true)
        _ = try store.connect(req)
        XCTAssertTrue(store.savedConnections.isEmpty, "成功连接不再自动入列表")
        XCTAssertEqual(kc.setCalls, 0, "connect 不再自动写 Keychain")
    }

    /// save 存密钥：Keychain 有值、UserDefaults JSON 永不含明文；同名 force=原位覆盖。
    func testSaveSecretKeychainOnlyAndForceReplace() throws {
        let kc = FakeKeychain()
        let d = fakeDefaults()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: d)
        let saved = try store.save(SMBConnectionRecord(name: "n", server: "h", share: "s", domain: nil, username: "u"),
                                   secret: "s3cr3t-xyz")
        XCTAssertTrue(saved.remembers)
        XCTAssertEqual(kc.items[saved.credentialAccount], "s3cr3t-xyz", "密钥只进 Keychain")
        let raw = String(data: d.data(forKey: "smb.recentConnections")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("s3cr3t"), "列表 JSON 不得含密码片段")
        // 同名无 force → 报错；force → 原位替换而非追加
        XCTAssertThrowsError(try store.save(SMBConnectionRecord(name: "n", server: "h2", share: "s", domain: nil, username: "u"), secret: nil)) { e in
            XCTAssertEqual(e as? SMBConnectionStore.SaveError, .sameNameExists)
        }
        _ = try store.save(SMBConnectionRecord(name: "n", server: "h2", share: "s", domain: nil, username: "u"), secret: nil, force: true)
        XCTAssertEqual(store.savedConnections.count, 1)
        XCTAssertEqual(store.savedConnections[0].server, "h2")
    }

    /// 删除独占凭据条目 → forget Keychain；同 credentialAccount 兄弟条目在场时不误删。
    func testRemoveForgetsKeychainOnlyWhenAccountUnshared() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let r1 = try store.save(SMBConnectionRecord(name: "one", server: "h", share: "s", domain: nil, username: "u"), secret: "pw")
        let r2 = try store.save(SMBConnectionRecord(name: "two", server: "h", share: "s", domain: nil, username: "u"), secret: "pw")
        store.remove(id: r1.id)
        XCTAssertEqual(kc.deleteCalls, 0, "r2 仍共享同凭据 → 不 forget")
        XCTAssertEqual(kc.items[r2.credentialAccount], "pw")
        store.remove(id: r2.id)
        XCTAssertEqual(kc.deleteCalls, 1, "最后一条删 → forget")
        XCTAssertNil(kc.items[r2.credentialAccount])
        XCTAssertTrue(store.savedConnections.isEmpty)
    }

    /// 选中条目改名撞其他条目同名 + force：原位覆盖自身+移除撞名条目，杜绝双同 id 孤儿
    /// （同 SFTP 侧 testSelectedRenameCollisionForceLeavesNoDuplicateID 同构）。
    /// 变异证伪：把 SMBConnectionStore.save 分支恢复为「sameName 命中先」原顺序 →
    /// id 唯一性断言红（出现重复 id）。
    func testSelectedRenameCollisionForceLeavesNoDuplicateID() throws {
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        func rec(_ server: String, name: String, id: String) -> SMBConnectionRecord {
            SMBConnectionRecord(name: name, id: id, server: server, share: "s", domain: nil, username: "u")
        }
        _ = try store.save(rec("a", name: "alpha", id: "id-A"), secret: nil)
        _ = try store.save(rec("b", name: "beta", id: "id-B"), secret: nil)
        let edited = rec("a", name: "beta", id: "id-A")
        XCTAssertThrowsError(try store.save(edited, secret: nil)) { e in
            XCTAssertEqual(e as? SMBConnectionStore.SaveError, .sameNameExists)
        }
        _ = try store.save(edited, secret: nil, force: true)
        let after = store.savedConnections
        XCTAssertEqual(after.count, 1, "撞名条目被覆盖移除")
        XCTAssertEqual(Set(after.map(\.id)).count, after.count, "id 唯一（修前红=双 id-A）")
        XCTAssertEqual(after[0].id, "id-A", "保留被选中改名字条目自身的 id")
        store.remove(id: "id-A")
        XCTAssertTrue(store.savedConnections.isEmpty, "无孤儿残留")
    }

    /// 就地覆盖换 server/share（=换 Keychain 账号）→ 旧账号孤儿就地 forget
    /// （同 SFTP 侧 testInPlaceEditChangingParamsForgetsOrphanedAccount 同构）。
    /// 变异证伪：删 SMBConnectionStore.save 的 forgetOrphanedSecrets 调用 →
    /// 旧账号残留断言红。
    func testInPlaceEditChangingParamsForgetsOrphanedAccount() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        func rec(_ server: String, share: String, id: String) -> SMBConnectionRecord {
            SMBConnectionRecord(name: "E", id: id, server: server, share: share, domain: nil, username: "u")
        }
        let saved = try store.save(rec("srv1", share: "pub", id: "id-E"), secret: "pw1")
        XCTAssertEqual(kc.items[saved.credentialAccount], "pw1")
        // 单击载入后改 share（选中态 id 覆盖路）：旧 server|share 账号成孤儿
        _ = try store.save(rec("srv1", share: "private", id: "id-E"), secret: "pw2")
        XCTAssertNil(kc.items[saved.credentialAccount], "旧账号孤儿 → 就地 forget")
        XCTAssertEqual(kc.deleteCalls, 1)
        // force 改名撞车路同样清理：victim(beta) 的独占凭据不滞留
        let kc2 = FakeKeychain()
        let store2 = SMBConnectionStore(mountManager: FakeMountManager(),
                                        credentials: SMBCredentialsStore(keychain: kc2),
                                        defaults: fakeDefaults())
        let beta = SMBConnectionRecord(name: "beta", id: "id-B", server: "b", share: "s", domain: nil, username: "ub")
        _ = try store2.save(SMBConnectionRecord(name: "alpha", id: "id-A", server: "a", share: "s", domain: nil, username: "ua"), secret: "pwA")
        let savedBeta = try store2.save(beta, secret: "pwB")
        _ = try store2.save(SMBConnectionRecord(name: "beta", id: "id-A", server: "a", share: "s", domain: nil, username: "ua"), secret: nil, force: true)
        XCTAssertNil(kc2.items[savedBeta.credentialAccount], "被移除的 beta 独占凭据不滞留")
    }

    func testSavedCappedAtTen() throws {
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        for i in 0..<10 {
            _ = try store.save(SMBConnectionRecord(name: "n\(i)", server: "h\(i)", share: "s", domain: nil, username: "u"), secret: nil)
        }
        XCTAssertEqual(store.savedConnections.count, 10, "已保存最多 10 条")
        XCTAssertEqual(store.savedConnections[0].server, "h9", "最新在前")
        XCTAssertThrowsError(try store.save(SMBConnectionRecord(name: "over", server: "hz", share: "s", domain: nil, username: "u"), secret: nil)) { e in
            XCTAssertEqual(e as? SMBConnectionStore.SaveError, .listFull)
        }
    }

    /// 旧「最近连接」JSON（无 name/id）自动导入为初始已保存条目（零迁移）。
    func testLegacyRecentJSONImportsAsSaved() throws {
        let d = fakeDefaults()
        let legacy = Data(#"[{"server":"h","share":"s","username":"u","remembers":false}]"#.utf8)
        d.set(legacy, forKey: "smb.recentConnections")
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: d)
        XCTAssertEqual(store.savedConnections.count, 1)
        XCTAssertEqual(store.savedConnections[0].name, "h/s (u)", "缺 name → 摘要兜底")
        XCTAssertFalse(store.savedConnections[0].id.isEmpty, "缺 id → 生成非空 UUID")
    }

    /// 同 server/share 不同用户名 → credentialAccount 不同（Keychain 键隔离）。
    func testDifferentUsersKeepSeparateCredentials() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let alice = try store.save(SMBConnectionRecord(name: "alice", server: "h", share: "s", domain: nil, username: "alice"), secret: "pa")
        let bob = try store.save(SMBConnectionRecord(name: "bob", server: "h", share: "s", domain: nil, username: "bob"), secret: "pb")
        XCTAssertNotEqual(alice.credentialAccount, bob.credentialAccount)
        XCTAssertEqual(kc.items.count, 2)
    }

    func testLoadSecretRoundTrip() throws {
        let kc = FakeKeychain()
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: kc),
                                       defaults: fakeDefaults())
        let saved = try store.save(SMBConnectionRecord(name: "n", server: "h", share: "s", domain: nil, username: "u"), secret: "pw")
        XCTAssertEqual(try store.loadSecret(for: saved), "pw")
    }

    /// service 隔离：SMB 门面默认挂 "FlyCommander.smb"，与 SFTP 的 "FlyCommander.sftp" 不串。
    /// 只读 service 字符串，不触发任何 SecItem 调用（hermetic）。
    func testDefaultServiceIsSMBNotSFTP() {
        let kc = SMBCredentialsStore().keychain as? KeychainCredentialsStore
        XCTAssertEqual(kc?.service, "FlyCommander.smb")
        XCTAssertNotEqual(kc?.service, "FlyCommander.sftp")
    }

    /// disconnect 对"复用 Finder 卷"的连接走 put-back 分支（as? SMBMountManager 下转 +
    /// config 版 loadSecret）：unmount 后把共享挂回**原外部挂载点**。
    func testDisconnectReusedFinderVolumePutsBackAtOriginalPoint() throws {
        let finderLine = """
        //shaogaoyang@truenas._smb._tcp.local/downloads on /Volumes/downloads (smbfs, nodev, nosuid, mounted by user)
        """
        var unmountArgs: [[String]] = []
        var mountArgs: [[String]] = []
        let mm = SMBMountManager(
            runMount: { args in mountArgs.append(args); return (0, "") },
            runUnmount: { args in unmountArgs.append(args); return (0, "") },
            runList: { finderLine },
            ensureDirectories: { _ in }   // 免触 /Volumes（hermetic）
        )
        let store = SMBConnectionStore(mountManager: mm,
                                       credentials: SMBCredentialsStore(keychain: FakeKeychain()),
                                       defaults: fakeDefaults())
        let req = SMBConnectionRequest(server: "truenas._smb._tcp.local", share: "downloads",
                                       domain: nil, username: "shaogaoyang")
        let (src, _) = try store.connect(req)
        XCTAssertEqual(src.mountPoint.path, "/Volumes/downloads", "connect 复用 Finder 卷")
        XCTAssertEqual(mountArgs.count, 0, "外部已挂载 → connect 不触发 mount_smbfs")

        store.disconnect(src.sourceID)

        XCTAssertEqual(unmountArgs, [["/sbin/umount", "-f", "/Volumes/downloads"]], "先卸原挂载点")
        XCTAssertEqual(mountArgs.count, 1, "断连触发一次挂回重挂")
        XCTAssertEqual(mountArgs[0][3], "/Volumes/downloads", "挂回原外部挂载点（而非 app 根）")
        XCTAssertTrue(mountArgs[0][2].contains("@truenas._smb._tcp.local/downloads"), "重挂同一共享")
        XCTAssertNil(store.source(for: src.sourceID), "断连后活动表清空")
    }
}
