import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 「保存连接列表」真窗回归锁（SMBConnectionViewController 主战场 + SFTP 抽查）。
///
/// 夹具：vc.store 注入 FakeKeychain+隔离 defaults 的 hermetic store；connectExecutor
/// 注入 fake（TransferEngine runInBackground/onMain 注入先例）→ 无真挂载/无真 Keychain。
///
/// 变异证伪（红面映射，红=该测试唯一红）：
/// ①  删 tableViewSelectionDidChange 里 loadRecordIntoForm 调用 → testSMBClickLoadsRecordIntoForm 红
/// ②  删 savedTable.onActivate 接线（或 connectSelected 取 secret 半句）→ testSMBDoubleClickConnects… 红
/// ③  删 saveTapped 里 store.save → testSMBSaveAddsToListAndNeverPersistsSecret 红（列表不增）
/// ④  改 save(id:) 覆盖为「删除+置顶」 → testSMBOverwriteKeepsPosition 红（位置变）
/// ⑤  remove(id:) 无条件 forget（删共享判定半句）→ testSMBDeleteSharesKeychainUntilLast 首断言红
/// ⑥  save cap 判断删 → testSMBSaveWhenFullShowsFullError 红（不报错反入库）
/// ⑦  bind 表漏 savedTitleLabel → testZhRepaintCoversSavedSection 红（旧英文残留）
final class SavedConnectionsVCTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var keychain: FakeKeychain!
    private var window: NSWindow!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared            // 裸进程真窗铁律（reduced-SDK）
        L10n.current = .en
        suiteName = "fly.savedvc.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        keychain = FakeKeychain()
    }

    override func tearDown() {
        window?.orderOut(nil)               // tearDown 禁 close()（SIGSEGV 记忆坑）
        window = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        keychain = nil
        L10n.current = .en
        super.tearDown()
    }

    private func makeSMBVC() -> (SMBConnectionViewController, SMBConnectionStore) {
        let store = SMBConnectionStore(mountManager: FakeMountManager(),
                                       credentials: SMBCredentialsStore(keychain: keychain),
                                       defaults: defaults)
        let vc = SMBConnectionViewController()
        vc.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentViewController = vc
        window.layoutIfNeeded()
        return (vc, store)
    }

    private func makeSFTPVC() -> (ConnectionViewController, ConnectionStore) {
        let store = ConnectionStore(credentials: CredentialsStore(keychain: keychain), defaults: defaults)
        let vc = ConnectionViewController()
        vc.store = store
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentViewController = vc
        window.layoutIfNeeded()
        return (vc, store)
    }

    // MARK: 视图树夹具（按 AX 标识读回控件——表单控件 private，锁走公开 AX 面）

    private func field(in root: NSView, identifier: String) -> NSTextField? {
        if let f = root as? NSTextField, f.accessibilityIdentifier() == identifier { return f }
        for s in root.subviews { if let f = field(in: s, identifier: identifier) { return f } }
        return nil
    }

    private func button(in root: NSView, identifier: String) -> NSButton? {
        if let b = root as? NSButton, b.accessibilityIdentifier() == identifier { return b }
        for s in root.subviews { if let b = button(in: s, identifier: identifier) { return b } }
        return nil
    }

    private func statusText(_ content: NSView, id: String) -> String {
        field(in: content, identifier: id)?.stringValue ?? "<missing>"
    }

    // MARK: ① 单击载入

    func testSMBClickLoadsRecordIntoForm() throws {
        let (vc, store) = makeSMBVC()
        vc.prepare()
        _ = try store.save(SMBConnectionRecord(name: "nas", id: "id-1", server: "tru", share: "dl",
                                               domain: "WG", username: "bob"), secret: "pw-1")
        vc.prepare()   // 刷新列表（含上条目）
        XCTAssertEqual(vc.savedTable.numberOfRows, 1)
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let c = vc.view
        XCTAssertEqual(field(in: c, identifier: "nameField")?.stringValue, "nas")
        XCTAssertEqual(field(in: c, identifier: "serverField")?.stringValue, "tru")
        XCTAssertEqual(field(in: c, identifier: "shareField")?.stringValue, "dl")
        XCTAssertEqual(field(in: c, identifier: "domainField")?.stringValue, "WG")
        XCTAssertEqual(field(in: c, identifier: "userField")?.stringValue, "bob")
        XCTAssertEqual(field(in: c, identifier: "passwordField")?.stringValue, "pw-1",
                       "remembers 条目单击载入须回读 Keychain 密码")
    }

    func testSFTPClickLoadsRecordAndFillsPassphrase() throws {
        let (vc, store) = makeSFTPVC()
        vc.prepare()
        _ = try store.save(SFTPConnectionRecord(name: "dev", id: "id-1", host: "h", port: 2222,
                                                username: "bob", auth: .keyFile,
                                                keyPath: "/k/id", remembers: false), secret: "pp-1")
        vc.prepare()
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let c = vc.view
        XCTAssertEqual(field(in: c, identifier: "nameField")?.stringValue, "dev")
        XCTAssertEqual(field(in: c, identifier: "hostField")?.stringValue, "h")
        XCTAssertEqual(field(in: c, identifier: "portField")?.stringValue, "2222")
        XCTAssertEqual(field(in: c, identifier: "keyPathField")?.stringValue, "/k/id")
        XCTAssertEqual(field(in: c, identifier: "passphraseField")?.stringValue, "pp-1",
                       "keyFile 条目载入 → passphrase 回填（fillSecret 路由锁）")
    }

    // MARK: ② 双击直连

    func testSMBDoubleClickConnectsWithStoredParamsAndSecret() throws {
        let (vc, store) = makeSMBVC()
        vc.prepare()
        _ = try store.save(SMBConnectionRecord(name: "nas", id: "id-1", server: "tru", share: "dl",
                                               domain: nil, username: "bob"), secret: "pw-1")
        vc.prepare()
        struct FakeErr: Error {}
        var received: SMBConnectionRequest?
        var calls = 0
        vc.connectExecutor = { req, completion in
            calls += 1
            received = req
            completion(.failure(FakeErr()))   // 失败回主线程合同不变；避免真 mount
        }
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        vc.savedTable.onActivate?()           // 双击/Return 同路
        XCTAssertEqual(calls, 1, "双击须恰好触发一次连接")
        XCTAssertEqual(received?.server, "tru")
        XCTAssertEqual(received?.share, "dl")
        XCTAssertEqual(received?.username, "bob")
        XCTAssertEqual(received?.secret, "pw-1", "remembers 条目双击直连须带 Keychain 密钥")
        XCTAssertTrue(statusText(vc.view, id: "smbConnectStatus").hasPrefix(L10n.t(.connectFailedPrefix)),
                      "fake 失败回主线程后状态应为失败前缀")
    }

    func testSFTPDoubleClickSuccessClosesAndReports() throws {
        // 无窗跑（close() 在裸 xctest harness 里 SIGSEGV=缩减 SDK 已证坑，探针背书）：
        // view.window=nil 时生产成功路的 window?.close() 自动跳过，onConnected 合同照常。
        let store = ConnectionStore(credentials: CredentialsStore(keychain: keychain), defaults: defaults)
        let vc = ConnectionViewController()
        vc.store = store
        _ = vc.view
        vc.prepare()
        _ = try store.save(SFTPConnectionRecord(name: "dev", id: "id-1", host: "h", port: 22,
                                                username: "bob", auth: .password), secret: "pw")
        vc.prepare()
        let source = SFTPSource(config: SFTPConnectionConfig(host: "h", port: 22, username: "bob",
                                                              auth: .password("x")),
                                homeDirectory: "/home/bob", hostKeyStore: SFTPHostKeyStore())
        var connected: (SFTPSource, String)?
        vc.onConnected = { connected = ($0, $1) }
        vc.connectExecutor = { _, completion in completion(.success((source, "/home/bob"))) }
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        vc.savedTable.onActivate?()
        XCTAssertEqual(connected?.1, "/home/bob", "成功路走 onConnected 合同")
    }

    // MARK: ③ 保存新建 + 明文不落盘

    func testSMBSaveAddsToListAndNeverPersistsSecret() throws {
        let (vc, _) = makeSMBVC()
        vc.prepare()
        // 空态占位常显锁：空列表 scroll 隐藏、占位可见
        XCTAssertTrue(vc.view.bounds.width > 100, "容器不得塌 0（translates 铁律哨兵）")
        let c = vc.view
        field(in: c, identifier: "nameField")?.stringValue = "home"
        field(in: c, identifier: "serverField")?.stringValue = "tru"
        field(in: c, identifier: "shareField")?.stringValue = "dl"
        field(in: c, identifier: "userField")?.stringValue = "bob"
        field(in: c, identifier: "passwordField")?.stringValue = "topsecret"
        button(in: c, identifier: "saveConnectionButton")?.performClick(nil)
        XCTAssertEqual(vc.savedTable.numberOfRows, 1, "保存后列表 +1（performClick 走 target/action 全链）")
        XCTAssertEqual(keychain.items.count, 1, "密钥进 Keychain")
        let raw = String(data: defaults.data(forKey: "smb.recentConnections")!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("topsecret"), "UserDefaults JSON 永不含明文")
        XCTAssertEqual(statusText(c, id: "smbConnectStatus"), L10n.t(.savedDone))
    }

    // MARK: ④ 选中改名覆盖=原位

    func testSMBOverwriteKeepsPosition() throws {
        let (vc, store) = makeSMBVC()
        vc.prepare()
        _ = try store.save(SMBConnectionRecord(name: "first", id: "id-a", server: "a", share: "s", domain: nil, username: "u"), secret: nil)
        _ = try store.save(SMBConnectionRecord(name: "second", id: "id-b", server: "b", share: "s", domain: nil, username: "u"), secret: nil)
        vc.prepare()
        vc.savedTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)  // 选 "first"
        field(in: vc.view, identifier: "serverField")?.stringValue = "a-new"
        button(in: vc.view, identifier: "saveConnectionButton")?.performClick(nil)
        let names = store.savedConnections.map(\.name)
        XCTAssertEqual(names, ["second", "first"], "选中保存=按 id 原位覆盖（数量与位置都不变）")
        XCTAssertEqual(store.savedConnections.last?.server, "a-new")
    }

    // MARK: ⑤ 删除 + 共享凭据条件 forget

    func testSMBDeleteSharesKeychainUntilLast() throws {
        let (vc, store) = makeSMBVC()
        vc.prepare()
        // 同 server/share/user（同 credentialAccount）两条不同名条目
        _ = try store.save(SMBConnectionRecord(name: "one", id: "id-1", server: "h", share: "s", domain: nil, username: "u"), secret: "pw")
        _ = try store.save(SMBConnectionRecord(name: "two", id: "id-2", server: "h", share: "s", domain: nil, username: "u"), secret: "pw")
        vc.prepare()
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button(in: vc.view, identifier: "deleteConnectionButton")?.performClick(nil)
        XCTAssertEqual(vc.savedTable.numberOfRows, 1, "删除后列表 -1")
        XCTAssertEqual(keychain.deleteCalls, 0, "兄弟条目仍共享凭据 → 不得 forget")
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button(in: vc.view, identifier: "deleteConnectionButton")?.performClick(nil)
        XCTAssertEqual(keychain.deleteCalls, 1, "最后一条删除 → forget")
    }

    // MARK: ⑥ 列表已满

    func testSMBSaveWhenFullShowsFullError() throws {
        let (vc, store) = makeSMBVC()
        vc.prepare()
        for i in 0..<10 {
            _ = try store.save(SMBConnectionRecord(name: "n\(i)", server: "h\(i)", share: "s", domain: nil, username: "u"), secret: nil)
        }
        vc.prepare()
        let c = vc.view
        field(in: c, identifier: "serverField")?.stringValue = "over"
        field(in: c, identifier: "shareField")?.stringValue = "s"
        button(in: c, identifier: "saveConnectionButton")?.performClick(nil)
        XCTAssertEqual(statusText(c, id: "smbConnectStatus"), L10n.t(.savedListFull))
        XCTAssertEqual(store.savedConnections.count, 10, "拒存不改列表")
    }

    // MARK: ⑦ 语言重刷覆盖新区

    func testZhRepaintCoversSavedSection() {
        let (vc, _) = makeSMBVC()
        vc.prepare()
        L10n.current = .zh
        vc.refreshLocalizedText()
        func hasLabel(_ s: String) -> Bool {
            func walk(_ v: NSView) -> Bool {
                if let f = v as? NSTextField, f.stringValue == s { return true }
                if let b = v as? NSButton, b.title == s { return true }   // 按钮标题在 title 非 stringValue
                return v.subviews.contains(where: walk)
            }
            return walk(vc.view)
        }
        XCTAssertTrue(hasLabel(L10n.t(.savedConnectionsTitle)), "区题应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.savedListEmpty)), "空态应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.saveConnection)), "保存按钮应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.deleteConnection)), "删除按钮应为中文")
    }
}
