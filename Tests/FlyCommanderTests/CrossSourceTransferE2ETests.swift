import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// T6 e2e：真实 sshd 上的跨源传输（本地 LocalFileSource ⇄ 远端 SFTPSource），
/// 走与 UI 完全同一条链路：真实 FilePane + OperationEngine 跨源流式。
///
/// 覆盖计划要求的四类：
/// - 上传 1MB → 远端 list 验证存在与大小；
/// - 下载 → 逐字节一致；
/// - 远端→本地 move → 源消失（跨源 move = 流式写 + 删源）；
/// - 远端内 move/copy → 服务端 rename 生效。
///
/// 每个用例都新建窗格 + 显式 revealItem，避免加载保留焦点导致选中项漂移。
final class CrossSourceTransferE2ETests: XCTestCase {
    private var fixture: SFTPServerFixture!
    private var server: SFTPServerFixture.Live!
    private var localDir: URL!
    private var source: SFTPSource!
    private var engine = OperationEngine()

    override func setUpWithError() throws {
        localDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xsrc_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)

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
        try? FileManager.default.removeItem(at: localDir)
        localDir = nil
    }

    private var remoteRoot: String {
        "sftp://127.0.0.1:\(server.port)\(server.remoteBase.path)"
    }

    /// 新远端窗格并聚焦指定文件（每次新建 → 焦点必落在首个文件，reveal 锁死目标）。
    private func remotePane(focused: String) throws -> FilePane {
        let pane = FilePane(id: .right, source: source, startPath: TCPath(remoteRoot))
        pane.load()
        XCTAssertTrue(pane.revealItem(id: pane.itemByID.first { $0.value.name == focused }?.key ?? ""),
                      "远端窗格应能聚焦 \(focused)")
        return pane
    }

    /// 新本地窗格并聚焦指定文件。
    private func localPane(focused: String) throws -> FilePane {
        let pane = FilePane(id: .left, source: LocalFileSource(), startPath: TCPath(url: localDir))
        pane.load()
        XCTAssertTrue(pane.revealItem(id: pane.itemByID.first { $0.value.name == focused }?.key ?? ""),
                      "本地窗格应能聚焦 \(focused)")
        return pane
    }

    /// 远端写一个文件（固定可复现内容）。
    private func writeRemote(name: String, bytes: Int) throws -> Data {
        let payload = Data((0..<bytes).map { UInt8(($0 &* 31) % 256) })
        var sent = false
        try source.streamWrite(TCPath("\(remoteRoot)/\(name)"), totalBytes: Int64(payload.count)) {
            if sent { return Data() }
            sent = true
            return payload
        }
        return payload
    }

    func testUploadOneMegabyteLocalToRemote() throws {
        let name = "up_\(UUID().uuidString.prefix(8)).bin"
        try Data((0..<(1024 * 1024)).map { UInt8($0 % 251) })
            .write(to: localDir.appendingPathComponent(name))
        let item = try XCTUnwrap(try localPane(focused: name).operationTargets.first,
                                 "本地窗格应选中 \(name)")

        try engine.performCopy([item], to: TCPath(remoteRoot),
                               srcSource: LocalFileSource(), dstSource: source)
        // copy 语义：本地源文件保留
        XCTAssertTrue(FileManager.default.fileExists(atPath: localDir.appendingPathComponent(name).path))
        // 远端 list 验证存在 + 大小
        let listed = try source.listDirectory(TCPath(remoteRoot))
        let hit = try XCTUnwrap(listed.first { $0.name == name },
                                "远端应有 \(name)：\(listed.map(\.name))")
        XCTAssertEqual(hit.size, 1024 * 1024)
        XCTAssertFalse(hit.isDirectory)
    }

    func testDownloadRemoteToLocalByteExact() throws {
        let name = "dl_\(UUID().uuidString.prefix(8)).bin"
        let payload = try writeRemote(name: name, bytes: 1024 * 1024)
        let item = try XCTUnwrap(try remotePane(focused: name).operationTargets.first,
                                 "远端窗格应选中 \(name)")

        try engine.performCopy([item], to: TCPath(url: localDir),
                               srcSource: source, dstSource: LocalFileSource())
        let downloaded = try Data(contentsOf: localDir.appendingPathComponent(name))
        XCTAssertEqual(downloaded, payload, "下载必须逐字节一致")
    }

    func testMoveRemoteToLocalDisappearsAtSource() throws {
        let name = "mv_\(UUID().uuidString.prefix(8)).bin"
        let payload = try writeRemote(name: name, bytes: 4096)
        let item = try XCTUnwrap(try remotePane(focused: name).operationTargets.first,
                                 "远端窗格应选中 \(name)")

        try engine.performMove([item], to: TCPath(url: localDir),
                               srcSource: source, dstSource: LocalFileSource())
        // 本地有、内容一致
        XCTAssertEqual(try Data(contentsOf: localDir.appendingPathComponent(name)), payload)
        // 远端源消失
        let after = try source.listDirectory(TCPath(remoteRoot))
        XCTAssertFalse(after.contains { $0.name == name }, "move 后远端源应消失：\(after.map(\.name))")
    }

    func testRemoteInternalMoveAndCopyUseServerRename() throws {
        // 远端内 copy（同源快路径 → SFTP 服务端 copy）：copy 进新子目录
        let cName = "rc_\(UUID().uuidString.prefix(8)).bin"
        let cPayload = try writeRemote(name: cName, bytes: 2048)
        let cItem = try XCTUnwrap(try remotePane(focused: cName).operationTargets.first)
        let copySub = "\(server.remoteBase.path)/copied"
        try source.makeDirectory(at: TCPath("sftp://127.0.0.1:\(server.port)\(copySub)"))
        try engine.performCopy([cItem], to: TCPath("sftp://127.0.0.1:\(server.port)\(copySub)"),
                               srcSource: source, dstSource: source)
        // 源仍在 + 副本出现且内容一致
        let rootList = try source.listDirectory(TCPath(remoteRoot))
        XCTAssertTrue(rootList.contains { $0.name == cName }, "copy 后源应仍在：\(rootList.map(\.name))")
        let copyList = try source.listDirectory(TCPath("sftp://127.0.0.1:\(server.port)\(copySub)"))
        let copyHit = try XCTUnwrap(copyList.first { $0.name == cName }, "副本应出现：\(copyList.map(\.name))")
        XCTAssertEqual(copyHit.size, Int64(cPayload.count))

        // 远端内 move（同源快路径 → SFTP 服务端 rename）：move 进另一个子目录
        let mName = "rm_\(UUID().uuidString.prefix(8)).bin"
        _ = try writeRemote(name: mName, bytes: 2048)
        let mItem = try XCTUnwrap(try remotePane(focused: mName).operationTargets.first)
        let moveSub = "\(server.remoteBase.path)/moved"
        try source.makeDirectory(at: TCPath("sftp://127.0.0.1:\(server.port)\(moveSub)"))
        try engine.performMove([mItem], to: TCPath("sftp://127.0.0.1:\(server.port)\(moveSub)"),
                               srcSource: source, dstSource: source)
        let rootList2 = try source.listDirectory(TCPath(remoteRoot))
        XCTAssertFalse(rootList2.contains { $0.name == mName }, "远端内 move 后源应消失：\(rootList2.map(\.name))")
        let moveList = try source.listDirectory(TCPath("sftp://127.0.0.1:\(server.port)\(moveSub)"))
        XCTAssertTrue(moveList.contains { $0.name == mName }, "目标子目录应有 \(mName)：\(moveList.map(\.name))")
    }
}
