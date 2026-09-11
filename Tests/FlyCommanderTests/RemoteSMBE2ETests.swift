import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// SMB e2e：真实 mount_smbfs 到 env 指定的 NAS。无 env → XCTSkip（CI/无 NAS 环境不红）。
/// 覆盖真实挂载一步（其余 IO/映射逻辑已在 SMBSourceTests 用 temp-dir 覆盖）。
final class RemoteSMBE2ETests: XCTestCase {
    private var server: String!
    private var share: String!
    private var user: String!
    private var pass: String!
    private var domain: String?
    private var keychain: FakeKeychain!
    private var store: SMBConnectionStore!

    override func setUpWithError() throws {
        let e = ProcessInfo.processInfo.environment
        server = e["FLY_SMB_TEST_SERVER"]
        share = e["FLY_SMB_TEST_SHARE"]
        user = e["FLY_SMB_TEST_USER"]
        pass = e["FLY_SMB_TEST_PASS"]
        domain = e["FLY_SMB_TEST_DOMAIN"]
        guard let server, let share, let user, let pass else {
            throw XCTSkip("未配置 FLY_SMB_TEST_SERVER/SHARE/USER/PASS，跳过 SMB e2e")
        }
        // 独立 defaults，不污染真实最近连接
        let d = UserDefaults(suiteName: "smb_e2e_\(UUID().uuidString)")!
        // 预置凭据：若被测共享正是用户 Finder 已挂载的共享，connect 走外部复用，
        // tearDown 的 disconnectAll → putBackMount 需 loadSecret 拿到密码才能重挂；
        // 空 FakeKeychain 会拿 nil → 匿名重挂密码保护共享失败 → 卸掉用户 /Volumes/<share>。
        keychain = FakeKeychain()
        let cfg = SMBConnectionConfig(server: server, share: share, domain: domain, username: user)
        try keychain.set(pass, account: cfg.credentialAccount)
        store = SMBConnectionStore(mountManager: SMBMountManager(),
                                    credentials: SMBCredentialsStore(keychain: keychain),
                                    defaults: d)
    }
    override func tearDown() {
        store?.disconnectAll()
        store = nil
    }

    func testMountListWriteDeleteUnmount() throws {
        let server = self.server!
        let share = self.share!
        let user = self.user!
        let pass = self.pass!
        // 挂载 + 浏览
        // connect 已不写 Keychain（保存列表语义）——setUp 预置的密码常驻 keychain，
        // tearDown 断连复用 Finder 卷时 loadSecret 直接取到它挂回原处。
        let req = SMBConnectionRequest(server: server, share: share, domain: domain,
                                       username: user, secret: pass)
        let (src, home) = try store.connect(req)
        XCTAssertTrue(src.isRemote)
        let listing = try src.listDirectory(home)   // 非空断言（真 NAS 必有内容）
        // listing 可空（空 share）故不强断非空，但 home 根须可列
        // 建目录 + 写文件 + 读回 + 删
        let dirName = "flye2e_\(UUID().uuidString.prefix(8))"
        let dirPath = TCPath("smb://\(server)/\(share)/\(dirName)")
        try src.makeDirectory(at: dirPath)
        let fPath = TCPath("smb://\(server)/\(share)/\(dirName)/probe.bin")
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        var sent = false
        try src.streamWrite(fPath, totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }
        // 列目录验证存在 + 大小
        let inDir = try src.listDirectory(dirPath)
        let hit = try XCTUnwrap(inDir.first { $0.name == "probe.bin" },
                                "probe.bin 应存在：\(inDir.map(\.name))")
        XCTAssertEqual(hit.size, 4096)
        // 读回逐字节
        var acc = Data()
        let reader = try src.openReader(fPath)
        while let chunk = try reader(64 * 1024) { acc.append(chunk) }
        XCTAssertEqual(acc, payload, "读回内容须与写入一致")
        // 删（远端递归删，isRemote → 上层会确认；此处直调 source 不弹确认）
        try src.removeItem(at: dirPath)
        let after = try src.stat(dirPath)
        XCTAssertNil(after, "删后目录应不存在")
        _ = listing   // 明确使用，避免未用变量
    }
}
