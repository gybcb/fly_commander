import XCTest
import Traversio

/// T0 spike：验证 Traversio 在本机（缩减 SDK 26.5）下
/// ① 带 passphrase 的 OpenSSH ed25519 密钥认证
/// ② 主机密钥 TOFU（自管 UserDefaults 存储）
/// ③ SFTP list/read/write/rename/mkdir/remove 全链路
/// ④ 错误密码 → 结构化 authenticationRejected（不崩溃）
/// 环境不满足时自动 skip（见 SFTPServerFixture）。
final class SFTPSpikeTests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live?
    private let defaults = UserDefaults(suiteName: "fly.sftpspike.test")!

    override func setUpWithError() throws {
        defaults.removePersistentDomain(forName: "fly.sftpspike.test")
        fixture = SFTPServerFixture()
        server = fixture.start()
        guard server != nil else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
    }

    override func tearDown() {
        fixture?.cleanup()
        server = nil
    }

    private func makeConfig(_ auth: SSHAuthenticationMethod) throws -> SSHClientConfiguration {
        let s = server!
        let policy = SSHHostKeyPolicy.trustOnFirstUse(
            lookup: { host, port in
                let key = "sftp://\(host):\(port)"
                guard let data = self.defaults.data(forKey: key) else { return nil }
                return try SSHTrustedHostKey(rawRepresentation: [UInt8](data))
            },
            store: { request in
                let key = "sftp://\(request.endpointHost):\(request.endpointPort)"
                self.defaults.set(
                    Data(request.trustedHostKey.rawRepresentation), forKey: key)
            }
        )
        return SSHClientConfiguration(
            host: "127.0.0.1",
            port: UInt16(s.port),
            username: s.username,
            authentication: auth,
            hostKeyPolicy: policy
        )
    }

    private var keyAuth: SSHAuthenticationMethod {
        try! .privateKeyPEM(contentsOfFile: server!.keyPath,
                            passphrase: server!.keyPassphrase)
    }

    func testKeyAuthSFTPSmoke() async throws {
        let config = try makeConfig(keyAuth)
        let connection = try await SSHClient.connect(configuration: config)
        do {
            try await runSFTPSmoke(on: connection)
        } catch {
            try? await connection.close()
            throw error
        }
        try? await connection.close()
    }

    private func runSFTPSmoke(on connection: SSHConnection) async throws {
        let sftp = try await connection.openSFTP()
        do {
            let base = server!.remoteBase.path

            // mkdir
            let dir = base + "/spike_dir"
            try await sftp.makeDirectory(dir)
            var attrs = try await sftp.stat(dir)
            // 目录位（S_IFDIR）：SFTP 权限含文件类型位，按位判断更稳。
            XCTAssertEqual((attrs.permissions ?? 0) & 0o170000, 0o040000)

            // write + stat size
            let filePath = dir + "/spike.txt"
            let payload = Data((0..<1024).map { UInt8($0 % 251) })
            try await sftp.writeFile(filePath, data: [UInt8](payload))
            attrs = try await sftp.stat(filePath)
            XCTAssertEqual(attrs.size, UInt64(payload.count))

            // read back byte-exact
            let readBack = try await sftp.readFile(filePath)
            XCTAssertEqual(Data(readBack), payload)

            // rename
            let renamed = dir + "/spike2.txt"
            try await sftp.rename(filePath, to: renamed)
            let oldGone: SSHSFTPFileAttributes? = try? await sftp.stat(filePath)
            XCTAssertNil(oldGone)
            _ = try await sftp.stat(renamed)

            // list 映射（大小）
            let entries = try await sftp.listDirectory(dir)
            let names = Set(entries.filter { $0.filename != "." && $0.filename != ".." }.map(\.filename))
            XCTAssertEqual(names, ["spike2.txt"])
            let entry = entries.first { $0.filename == "spike2.txt" }!
            XCTAssertEqual(entry.attributes.size, UInt64(payload.count))

            // remove file + directory
            try await sftp.removeFile(renamed)
            let fileGone: SSHSFTPFileAttributes? = try? await sftp.stat(renamed)
            XCTAssertNil(fileGone)
            try await sftp.removeDirectory(dir)
            let dirGone: SSHSFTPFileAttributes? = try? await sftp.stat(dir)
            XCTAssertNil(dirGone)
        } catch {
            try? await sftp.close()
            throw error
        }
        try? await sftp.close()
    }

    func testTofuRejectsChangedHostKey() async throws {
        // 第一次连接成功（TOFU 存指纹）。
        _ = try await connectAndDisconnect(auth: keyAuth)
        // 指纹已存。
        XCTAssertNotNil(defaults.data(forKey: "sftp://127.0.0.1:\(server!.port)"))
        // 换主机密钥（重启 sshd 前改不了 HostKey 文件——用 requireMatch 语义等价验证：
        // 篡改存储的指纹，应被 TOFU 拒绝）。
        defaults.set(Data([0, 1, 2, 3]), forKey: "sftp://127.0.0.1:\(server!.port)")
        do {
            _ = try await connectAndDisconnect(auth: keyAuth)
            XCTFail("篡改指纹后连接应被拒绝")
        } catch {
            // 预期：主机密钥不匹配（存储值解析失败或不匹配）。
        }
    }

    func testWrongPasswordRejected() async throws {
        let config = try makeConfig(.password("definitely-wrong-password"))
        do {
            _ = try await SSHClient.connect(configuration: config)
            XCTFail("错误密码应被拒绝")
        } catch let error as SSHClientError {
            guard case .authenticationRejected = error else {
                return XCTFail("预期 authenticationRejected，实际 \(error)")
            }
        }
    }

    private func connectAndDisconnect(auth: SSHAuthenticationMethod) async throws {
        let connection = try await SSHClient.connect(configuration: try makeConfig(auth))
        try await connection.close()
    }
}
