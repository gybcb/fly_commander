import XCTest
@testable import FlyCommander
import TCCore

/// UpdateInstaller 编排回归锁：download/digest/runShell 全假，断言 shell 参数序列而非
/// 真跑 hdiutil/cp。调用记录走引用类型 spy（Swift 值捕获陷阱：`[[String]]` 返回即定格快照）。
/// 每条带变异证伪注释。
final class UpdateInstallerTests: XCTestCase {
    private let manifest = UpdateManifest(
        version: "9.9.9", dmgURL: "https://example.com/f.dmg",
        sha256: String(repeating: "a", count: 64), notes: "x")

    /// 引用型壳间谍：记录参数序列 + 可脚本化 cp 失败。
    private final class ShellSpy {
        var calls: [[String]] = []
        var failCp = false
        var failAll = false
        func call(_ args: [String]) -> (Int32, String) {
            calls.append(args)
            if failAll { return (1, "boom") }
            if failCp && args[0] == "/bin/cp" { return (1, "disk full") }
            return (0, "")
        }
    }

    private func makeInstaller(spy: ShellSpy, hex: String? = nil) -> UpdateInstaller {
        UpdateInstaller(
            runShell: { spy.call($0) },
            download: { _ in URL(fileURLWithPath: "/fake/temp/d.dmg") },
            digest: { _ in hex ?? self.manifest.sha256 },
            currentBundleURL: URL(fileURLWithPath: "/fake/FlyCommander.app"),
            tempDir: URL(fileURLWithPath: "/fake/temp"))
    }

    private final class Recorder {
        var phases: [UpdateInstaller.Phase] = []
        var result: Result<Void, UpdateInstaller.InstallError>?
    }

    @discardableResult
    private func run(_ inst: UpdateInstaller) -> Recorder {
        let rec = Recorder()
        inst.install(manifest: manifest, onPhase: { rec.phases.append($0) }) { rec.result = $0 }
        XCTAssertNotNil(rec.result)
        return rec
    }

    func testHappyPathShellSequence() {
        let spy = ShellSpy()
        let rec = run(makeInstaller(spy: spy))
        XCTAssertEqual(rec.phases, [.download, .verify, .replace], "三阶段按序回调")
        guard case .success? = rec.result else { XCTFail("happy path 应成功"); return }
        XCTAssertEqual(spy.calls.count, 4)
        guard spy.calls.count == 4 else { return }   // 索引前置守卫：变异红时报错而非 SIGSEGV
        XCTAssertEqual(spy.calls[0][0], "/usr/bin/hdiutil"); XCTAssertEqual(spy.calls[0][1], "attach")
        XCTAssertEqual(spy.calls[0].last, "/fake/temp/d.dmg", "attach 目标是下载的 dmg")
        XCTAssertTrue(spy.calls[0].contains("-nobrowse"), "挂载点不弹进 Finder")
        XCTAssertEqual(spy.calls[0][3], "-mountpoint")
        XCTAssertEqual(spy.calls[1][0], "/bin/mv")
        XCTAssertEqual(spy.calls[1][1], "/fake/FlyCommander.app", "旧 bundle 先让位")
        XCTAssertTrue(spy.calls[1][2].hasPrefix("/fake/temp/fc-update-old-"), "让位=移进 temp 可回滚")
        XCTAssertEqual(spy.calls[2][0], "/bin/cp"); XCTAssertEqual(spy.calls[2][1], "-R")
        XCTAssertEqual(spy.calls[2][3], "/fake/FlyCommander.app", "新 bundle 落回原位")
        XCTAssertTrue(spy.calls[2][2].contains("/fc-update-mnt-"), "源=挂载点内 FlyCommander.app")
        XCTAssertEqual(spy.calls[3][0], "/usr/bin/hdiutil"); XCTAssertEqual(spy.calls[3][1], "detach")
        // 变异证伪：把 detach 挪到 cp 之前 → calls[2] 变 detach 红。
    }

    func testChecksumMismatchStopsBeforeAnyShell() {
        let spy = ShellSpy()
        let rec = run(makeInstaller(spy: spy, hex: String(repeating: "f", count: 64)))
        XCTAssertEqual(rec.phases, [.download, .verify], "哈希不过不进 replace 阶段")
        guard case .failure(.checksumMismatch)? = rec.result else { XCTFail("必须 checksumMismatch"); return }
        XCTAssertEqual(spy.calls.count, 0, "红线：哈希不过，挂载之前零副作用")
        // 变异证伪：删 hex==manifest.sha256 守卫 → calls 变 4 且 success，此断言红。
    }

    func testNoXattrEver() {
        let spy = ShellSpy()
        _ = run(makeInstaller(spy: spy))
        _ = run(makeInstaller(spy: spy, hex: String(repeating: "f", count: 64)))   // 失败路同样扫
        // 红线锁：升级全程 shell 调用参数序列永不可出现 xattr/quarantine。
        for c in spy.calls {
            XCTAssertFalse(c.contains { $0.contains("xattr") || $0.contains("quarantine") },
                           "绝不自动清隔离：\(c)")
        }
    }

    func testGatekeeperCommandIsDisplayOnly() {
        let spy = ShellSpy()
        let inst = makeInstaller(spy: spy)
        _ = run(inst)
        XCTAssertTrue(inst.gatekeeperCommand.hasPrefix("xattr -dr com.apple.quarantine"))
        XCTAssertTrue(inst.gatekeeperCommand.contains("/fake/FlyCommander.app"), "命令含真实 App 路径供用户执行")
        for c in spy.calls { XCTAssertFalse(c[0].contains("xattr")) }   // 但永不执行
    }

    func testMountFailureReportsAndSkipsReplace() {
        let spy = ShellSpy(); spy.failAll = true
        let rec = run(makeInstaller(spy: spy))
        guard case .failure(.mountFailed(1, "boom"))? = rec.result else { XCTFail("应 mountFailed"); return }
        XCTAssertEqual(spy.calls.count, 1, "挂载失败不得再跑 mv/cp/detach")
    }

    func testCopyFailureRollsBackOldBundle() {
        // cp 失败：第 4 个调用（索引 3）必须是 mv 回滚，随后仍 detach。
        let spy = ShellSpy(); spy.failCp = true
        let rec = run(makeInstaller(spy: spy))
        guard case .failure(.copyFailed(1, "disk full"))? = rec.result else { XCTFail("应 copyFailed"); return }
        XCTAssertEqual(spy.calls.count, 5)
        guard spy.calls.count == 5 else { return }   // 索引前置守卫：变异红时报错而非 SIGSEGV
        XCTAssertEqual(spy.calls[3][0], "/bin/mv")
        XCTAssertEqual(spy.calls[3][1], spy.calls[1][2], "回滚=mv 让位物")
        XCTAssertEqual(spy.calls[3][2], "/fake/FlyCommander.app", "回到原位")
        XCTAssertEqual(spy.calls[4][1], "detach", "回滚后仍卸载 dmg")
        // 变异证伪：删 cp 失败分支里的回滚 mv → calls[3] 变 detach，此断言红。
    }

    func testDownloadFailureStopsBeforeVerify() {
        let spy = ShellSpy()
        var digestCalls = 0
        let inst = UpdateInstaller(
            runShell: { spy.call($0) },
            download: { _ in throw URLError(.notConnectedToInternet) },
            digest: { _ in digestCalls += 1; return self.manifest.sha256 },
            currentBundleURL: URL(fileURLWithPath: "/fake/a.app"),
            tempDir: FileManager.default.temporaryDirectory)
        let rec = run(inst)
        XCTAssertEqual(rec.phases, [.download], "下载失败即止，不进校验阶段")
        XCTAssertEqual(digestCalls, 0)
        XCTAssertEqual(spy.calls.count, 0)
        guard case .failure(.downloadFailed)? = rec.result else {
            XCTFail("应 downloadFailed，实为 \(String(describing: rec.result))"); return
        }
    }

    func testSha256HexRealDigest() throws {
        // 真函数上真字节：与已知 sha256("abc") 公开向量对拍。
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertEqual(try UpdateInstaller.sha256Hex(f),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
