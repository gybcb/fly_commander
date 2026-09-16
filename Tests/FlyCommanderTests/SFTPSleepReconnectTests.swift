import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 休眠唤醒修复回归锁：死连接判丢 + 懒重连（对齐 FTP keepsConnection 语义）。
/// 用例 1 = 唤醒模拟（杀 sshd 进程树 → 旧连接被打死 → 原地重拉 → 同一
/// SFTPSource 下次操作应自动重连成功）。现状（修复前）必红：死连接永不自愈。
/// 用例 2 = 防过度重连：服务器语义否定应答（noSuchFile）不丢连接。
final class SFTPSleepReconnectTests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var source: SFTPSource!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: "fly.sfpsleep.\(UUID().uuidString)")!
        fixture = SFTPServerFixture()
        guard let live = fixture.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        server = live
        let config = SFTPConnectionConfig(
            host: "127.0.0.1",
            port: UInt16(server.port),
            username: server.username,
            auth: .keyFile(path: server.keyPath, passphrase: server.keyPassphrase)
        )
        source = SFTPSource(config: config,
                            homeDirectory: server.remoteBase.path,
                            hostKeyStore: SFTPHostKeyStore(defaults: defaults))
    }

    override func tearDown() {
        source?.closeConnection()
        source = nil
        fixture?.cleanup()
        fixture = nil
        server = nil
        defaults = nil
    }

    private var root: TCPath {
        TCPath("sftp://127.0.0.1:\(server.port)\(server.remoteBase.path)")
    }

    func testDeadConnectionReconnectsLazilyWithoutRebuildingSource() throws {
        // 1) 建活连接
        XCTAssertNoThrow(try source.listDirectory(root))
        let connBefore = source._connection
        XCTAssertNotNil(connBefore, "首操作已建连")

        // 2) 杀服务器进程树（fork-per-connection 子进程全灭 → OS 对活连接发 RST）
        fixture.killServerTree()

        // 3) 死连接上的操作必须报错（不是静默成功）
        XCTAssertThrowsError(try source.listDirectory(root))

        // 4) 原地重拉（同 config 同端口）= 「唤醒后服务器还活着」
        guard fixture.restartInPlace() else {
            throw XCTSkip("sshd 原地重拉失败（端口未释放）")
        }

        // 5) 主断言：**同一个 SFTPSource** 下次操作懒重连成功。修复前必红。
        XCTAssertNoThrow(try source.listDirectory(root))
        XCTAssertNotIdentical(source._connection, connBefore, "重连必须是新连接对象")
    }

    func testServerSemanticErrorKeepsConnection() throws {
        // 热身建连
        XCTAssertNoThrow(try source.listDirectory(root))
        let connBefore = source._connection
        XCTAssertNotNil(connBefore)

        // 不存在路径的 stat = 服务器语义否定应答（noSuchFile → nil）
        let missing = TCPath("sftp://127.0.0.1:\(server.port)\(server.remoteBase.path)/no-such-entry")
        XCTAssertNil(try source.stat(missing))

        // 连接**不被丢弃**：身份不变（语义错误触发重连风暴 = 每次 noSuchFile 重付握手）
        XCTAssertIdentical(source._connection, connBefore)
        // 变异证伪：mapped 无条件 _connection = nil → 此断言翻红。
    }
}
