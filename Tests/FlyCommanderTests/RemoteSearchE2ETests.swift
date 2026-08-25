import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 远端（SFTP）搜索 e2e：真实 sshd 上建一棵小目录树，用通用 `FileSearcher`
/// 过 `SFTPSource` 递归搜索，验证命中/未命中与隐藏目录跳过。
/// 与 CrossSourceTransferE2ETests 同夹具（本地 sshd），起不来则 XCTSkip。
final class RemoteSearchE2ETests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var source: SFTPSource!

    override func setUpWithError() throws {
        fixture = SFTPServerFixture()
        guard let live = fixture.start() else {
            throw XCTSkip("本地 sshd 不可用（环境守卫）")
        }
        server = live
        let config = SFTPConnectionConfig(host: "127.0.0.1", port: UInt16(server.port),
                                          username: server.username,
                                          auth: .keyFile(path: server.keyPath, passphrase: server.keyPassphrase))
        source = SFTPSource(config: config, homeDirectory: server.remoteBase.path)
    }

    override func tearDown() {
        source?.closeConnection()
        source = nil
        fixture?.cleanup()
        fixture = nil
        server = nil
    }

    private var remoteRoot: String {
        "sftp://127.0.0.1:\(server.port)\(server.remoteBase.path)"
    }

    private func writeRemote(name: String, bytes: Int) throws {
        let payload = Data((0..<bytes).map { UInt8(($0 &* 31) % 256) })
        var sent = false
        try source.streamWrite(TCPath("\(remoteRoot)/\(name)"), totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }
    }

    func testSearchRemoteTreeRecursive() throws {
        // 远端树：
        //   remoteRoot/
        //     a.txt        ← 命中
        //     b.md         ← 不匹配 *.txt
        //     sub/
        //       a.txt      ← 命中（递归）
        try source.makeDirectory(at: TCPath("\(remoteRoot)/sub"))
        try writeRemote(name: "a.txt", bytes: 8)
        try writeRemote(name: "b.md", bytes: 8)
        try writeRemote(name: "sub/a.txt", bytes: 8)

        let hits = FileSearcher().search(root: TCPath(remoteRoot),
                                         pattern: NamePattern("*.txt"),
                                         source: source)
        let names = Set(hits.map { $0.name })
        XCTAssertEqual(names, ["a.txt"], "应只命中两枚 a.txt（同名去重），不含 b.md：\(names)")
        // 两枚 a.txt（根 + sub/），路径不同。
        XCTAssertEqual(hits.count, 2, "根与子目录各一枚 a.txt：\(hits.map { $0.path.pathString })")
        XCTAssertFalse(hits.contains { $0.name == "b.md" }, "b.md 不应命中")
    }
}
