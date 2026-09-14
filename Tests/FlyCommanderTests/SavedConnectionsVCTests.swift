import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// 统一「已保存连接列表」真窗回归锁（RemoteConnectionViewController 主战场，三协议共用一张表）。
///
/// 夹具：vc.store 注入 RemoteConnectionStore(keychains: 三协议共用一个 FakeKeychain +
/// 隔离 defaults) 的 hermetic store；executors 注入同步 fake（TransferEngine
/// runInBackground/onMain 注入先例）→ 无真挂载 / 无真 Keychain / 无真 sshd。
///
/// 变异证伪（红面映射，红=该测试唯一红）：
/// ①  删 tableViewSelectionDidChange 里 loadRecordIntoForm 调用 → testClickLoadsRecordIntoForm… 红
/// ②  删 savedTable.onActivate 接线（或 connectSelected 取 secret 半句）→ testDoubleClickConnects… 红
/// ③  删 saveTapped 里 store.save → testSaveAddsToListAndNeverPersistsSecret 红（列表不增）
/// ④  改 save(id:) 覆盖为「删除+置顶」 → testOverwriteKeepsPosition 红（位置变）
/// ⑤  remove(id:) 无条件 forget（删共享判定半句）→ testDeleteSharesKeychainUntilLast 首断言红
/// ⑥  save cap 判断删 → testSaveWhenFullShowsFullError 红（不报错反入库）
/// ⑦  bind 表漏 savedTitleLabel → testZhRepaintCoversSavedSection 红（旧英文残留）
/// ⑧  loadRecordIntoForm 漏 setProto → testCrossProtoClickSwitchesSegment 红（表单协议没跟上）
/// ⑨  executors 查表删掉 guard 直接强跑（缺 key 崩溃或静默）→ testMissingExecutor… 红（无未接线提示）
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

    private func makeStore() -> RemoteConnectionStore {
        RemoteConnectionStore(keychains: [.sftp: keychain, .smb: keychain, .ftp: keychain],
                              defaults: defaults)
    }

    private func makeVC() -> (RemoteConnectionViewController, RemoteConnectionStore) {
        let store = makeStore()
        let vc = RemoteConnectionViewController()
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

    private func statusText(_ content: NSView, id: String = "connectStatus") -> String {
        field(in: content, identifier: id)?.stringValue ?? "<missing>"
    }

    // MARK: ① 单击载入（SMB 分支）

    func testSMBClickLoadsRecordIntoForm() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-1", name: "nas",
                                                  server: "tru", share: "dl", domain: "WG",
                                                  username: "bob"), secret: "pw-1")
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

    // MARK: ① 单击载入（SFTP keyFile 分支：passphrase 路由）

    func testSFTPClickLoadsRecordAndFillsPassphrase() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .sftp, id: "id-1", name: "dev",
                                                  host: "h", port: 2222, username: "bob",
                                                  authKind: .keyFile, keyPath: "/k/id"), secret: "pp-1")
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

    // MARK: ⑧ 跨协议单击载入：表单段控件须跟着切协议

    func testCrossProtoClickSwitchesSegment() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-1", name: "nas",
                                                  server: "tru", share: "dl", username: "bob"), secret: nil)
        vc.prepare()
        XCTAssertEqual(vc.proto, .sftp, "初始默认协议=sftp")
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertEqual(vc.proto, .smb, "单击 smb 条目 → 表单协议跟着切 smb（旧两 VC 各一协议，无此问题；统一表单必锁）")
    }

    // MARK: ② 双击直连（SMB 分支，用 fake 捕获请求参数 + 失败态合同）

    func testSMBDoubleClickConnectsWithStoredParamsAndSecret() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-1", name: "nas",
                                                  server: "tru", share: "dl", username: "bob"), secret: "pw-1")
        vc.prepare()
        struct FakeErr: Error {}
        var received: RemoteConnectionRequest?
        var calls = 0
        vc.executors = [.smb: { (req: RemoteConnectionRequest, completion: @escaping (Result<RemoteConnection, Error>) -> Void) in
            calls += 1
            received = req
            completion(.failure(FakeErr()))   // 失败回主线程合同不变；避免真 mount
        }]
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        vc.savedTable.onActivate?()           // 双击/Return 同路
        XCTAssertEqual(calls, 1, "双击须恰好触发一次连接")
        XCTAssertEqual(received?.proto, .smb)
        XCTAssertEqual(received?.server, "tru")
        XCTAssertEqual(received?.share, "dl")
        XCTAssertEqual(received?.username, "bob")
        XCTAssertEqual(received?.secret, "pw-1", "remembers 条目双击直连须带 Keychain 密钥")
        XCTAssertTrue(statusText(vc.view).hasPrefix(L10n.t(.connectFailedPrefix)),
                      "fake 失败回主线程后状态应为失败前缀")
    }

    // MARK: ② 双击直连（SFTP 分支，成功路 onConnected 合同）

    func testSFTPDoubleClickSuccessClosesAndReports() throws {
        // 无窗跑（close() 在裸 xctest harness 里 SIGSEGV=缩减 SDK 已证坑，探针背书）：
        // view.window=nil 时生产成功路的 window?.close() 自动跳过，onConnected 合同照常。
        let store = makeStore()
        let vc = RemoteConnectionViewController()
        vc.store = store
        _ = vc.view
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .sftp, id: "id-1", name: "dev",
                                                  host: "h", port: 22, username: "bob",
                                                  authKind: .password), secret: "pw")
        vc.prepare()
        let source = SFTPSource(config: SFTPConnectionConfig(host: "h", port: 22, username: "bob",
                                                             auth: .password("x")),
                                homeDirectory: "/home/bob", hostKeyStore: SFTPHostKeyStore())
        let home = SFTPSource.tcPath(host: "h", port: 22, remotePath: "/home/bob")
        var connected: (any FileSource, TCPath)?
        vc.onConnected = { connected = ($0, $1) }
        vc.executors = [.sftp: { (_: RemoteConnectionRequest, completion: @escaping (Result<RemoteConnection, Error>) -> Void) in
            completion(.success(RemoteConnection(source: source, home: home)))
        }]
        vc.savedTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        vc.savedTable.onActivate?()
        XCTAssertEqual(connected?.1, home, "成功路走 onConnected 合同（home 已升 TCPath）")
    }

    // MARK: ⑨ 缺执行器（FTP 注入缝未接线）：状态行提示未接线，不静默失败/不崩溃

    func testMissingExecutorShowsNotWiredHint() throws {
        let (vc, _) = makeVC()
        vc.prepare()
        vc.setProto(.ftp)
        field(in: vc.view, identifier: "hostField")?.stringValue = "h"
        button(in: vc.view, identifier: "connectButton")?.performClick(nil)
        XCTAssertEqual(statusText(vc.view), L10n.t(.protoNotWired, L10n.t(.protoFTP)),
                       "executors 缺 ftp 项 → 状态行提示未接线（不引用任何 FTP 类型的注入缝合同）")
    }

    // MARK: ③ 保存新建 + 明文不落盘（SMB 分支）

    func testSMBSaveAddsToListAndNeverPersistsSecret() throws {
        let (vc, _) = makeVC()
        vc.prepare()
        vc.setProto(.smb)
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
        let raw = String(data: defaults.data(forKey: RemoteConnectionStore.storeKey)!, encoding: .utf8)!
        XCTAssertFalse(raw.contains("topsecret"), "UserDefaults JSON 永不含明文")
        XCTAssertEqual(statusText(c), L10n.t(.savedDone))
    }

    // MARK: ④ 选中改名覆盖=原位

    func testOverwriteKeepsPosition() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-a", name: "first", server: "a", share: "s", username: "u"), secret: nil)
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-b", name: "second", server: "b", share: "s", username: "u"), secret: nil)
        vc.prepare()
        vc.setProto(.smb)
        vc.savedTable.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)  // 选 "first"
        field(in: vc.view, identifier: "serverField")?.stringValue = "a-new"
        button(in: vc.view, identifier: "saveConnectionButton")?.performClick(nil)
        let names = store.savedConnections.map(\.name)
        XCTAssertEqual(names, ["second", "first"], "选中保存=按 id 原位覆盖（数量与位置都不变）")
        XCTAssertEqual(store.savedConnections.last?.server, "a-new")
    }

    // MARK: ⑤ 删除 + 共享凭据条件 forget（统一表混装三协议 → 存活判定须含服务名，见 credentialKey）

    func testDeleteSharesKeychainUntilLast() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        // 同 server/share/user（同 credentialAccount）两条不同名条目
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-1", name: "one", server: "h", share: "s", username: "u"), secret: "pw")
        _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-2", name: "two", server: "h", share: "s", username: "u"), secret: "pw")
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

    func testSaveWhenFullShowsFullError() throws {
        let (vc, store) = makeVC()
        vc.prepare()
        for i in 0..<RemoteConnectionStore.savedCap {
            _ = try store.save(RemoteConnectionRecord(proto: .smb, id: "id-\(i)", name: "n\(i)", server: "h\(i)", share: "s", username: "u"), secret: nil)
        }
        vc.prepare()
        vc.setProto(.smb)
        let c = vc.view
        field(in: c, identifier: "serverField")?.stringValue = "over"
        field(in: c, identifier: "shareField")?.stringValue = "s"
        button(in: c, identifier: "saveConnectionButton")?.performClick(nil)
        XCTAssertEqual(statusText(c), L10n.t(.savedListFull))
        XCTAssertEqual(store.savedConnections.count, RemoteConnectionStore.savedCap, "拒存不改列表")
    }

    // MARK: ⑦ 语言重刷覆盖新区（含协议段标签）

    func testZhRepaintCoversSavedSection() {
        let (vc, _) = makeVC()
        vc.prepare()
        L10n.current = .zh
        vc.refreshLocalizedText()
        func hasLabel(_ s: String) -> Bool {
            func walk(_ v: NSView) -> Bool {
                if let f = v as? NSTextField, f.stringValue == s { return true }
                if let b = v as? NSButton, b.title == s { return true }   // 按钮标题在 title 非 stringValue
                if let seg = v as? NSSegmentedControl, (0..<seg.segmentCount).contains(where: { seg.label(forSegment: $0) == s }) { return true }
                return v.subviews.contains(where: walk)
            }
            return walk(vc.view)
        }
        XCTAssertTrue(hasLabel(L10n.t(.savedConnectionsTitle)), "区题应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.savedListEmpty)), "空态应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.saveConnection)), "保存按钮应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.deleteConnection)), "删除按钮应为中文")
        XCTAssertTrue(hasLabel(L10n.t(.fieldTLS)), "TLS 勾选应为中文（协议专有行也须在绑定表内）")
    }
}
