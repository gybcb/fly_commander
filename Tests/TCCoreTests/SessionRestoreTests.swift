import XCTest
import Foundation
@testable import TCCore

/// T1：会话恢复纯函数 + 快照容错解码。probe 全部注入闭包——测试不碰磁盘。
final class SessionRestoreTests: XCTestCase {
    private let fallback = "/fallback"

    /// 注入"哪些目录可用"，模拟磁盘而不访问磁盘。
    private func probe(_ available: Set<String>) -> (String) -> Bool {
        { available.contains($0) }
    }

    func testCandidateAvailableReturnsIt() {
        XCTAssertEqual(SessionRestore.resolve(candidate: "/a/b", fallback: fallback,
                                              probe: probe(["/a/b"])), "/a/b")
    }

    func testWalksUpToFirstAvailableAncestor() {
        XCTAssertEqual(SessionRestore.resolve(candidate: "/a/b/c", fallback: fallback,
                                              probe: probe(["/a/b"])), "/a/b")
        XCTAssertEqual(SessionRestore.resolve(candidate: "/a/b/c", fallback: fallback,
                                              probe: probe(["/a"])), "/a")
    }

    func testRootUnavailableFallsBack() {
        var probed: [String] = []
        let result = SessionRestore.resolve(candidate: "/a/b", fallback: fallback,
                                            probe: { probed.append($0); return false })
        XCTAssertEqual(result, fallback)
        XCTAssertEqual(probed, ["/a/b", "/a", "/"], "逐级上溯至根，根之后停止")
    }

    func testRemoteCandidateFallsBackWithoutProbing() {
        var probed = 0
        let result = SessionRestore.resolve(candidate: "sftp://h:22/a/b", fallback: fallback,
                                            probe: { _ in probed += 1; return true })
        XCTAssertEqual(result, fallback)
        XCTAssertEqual(probed, 0, "远端串不得触发本地 probe")
        XCTAssertEqual(SessionRestore.resolve(candidate: "smb://s/share/a", fallback: fallback,
                                              probe: probe([])), fallback)
    }

    func testNilEmptyWhitespaceAndRelativeFallBack() {
        XCTAssertEqual(SessionRestore.resolve(candidate: nil, fallback: fallback, probe: probe([])), fallback)
        XCTAssertEqual(SessionRestore.resolve(candidate: "", fallback: fallback, probe: probe([])), fallback)
        XCTAssertEqual(SessionRestore.resolve(candidate: "   ", fallback: fallback, probe: probe([])), fallback)
        XCTAssertEqual(SessionRestore.resolve(candidate: "relative/path", fallback: fallback,
                                              probe: probe([])), fallback)
    }

    /// 首尾空白必须 trim 后用 trimmed 值 probe **并返回 trimmed 值**（原串 " /a " 探不到）。
    func testTrimsWhitespaceBeforeResolving() {
        XCTAssertEqual(SessionRestore.resolve(candidate: " /a/b \n", fallback: fallback,
                                              probe: probe(["/a/b"])), "/a/b")
    }

    func testTildeExpandsToHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SessionRestore.resolve(candidate: "~/dev", fallback: fallback,
                                              probe: probe([home + "/dev"])), home + "/dev")
        XCTAssertEqual(SessionRestore.resolve(candidate: "~", fallback: fallback,
                                              probe: probe([home])), home)
    }

    /// `~foo`（非法家目录写法）必须直接 fallback 且**不 probe**：放行会被当相对路径解析，
    /// probe 失败后一路"上溯"到根，首启落根目录。
    func testTildeUserSyntaxRejectedWithoutProbing() {
        var probed = 0
        let result = SessionRestore.resolve(candidate: "~foo/bar", fallback: fallback,
                                            probe: { _ in probed += 1; return true })
        XCTAssertEqual(result, fallback)
        XCTAssertEqual(probed, 0, "非法家目录写法不得触发 probe")
        XCTAssertEqual(SessionRestore.resolve(candidate: "~foo", fallback: fallback,
                                              probe: { _ in probed += 1; return true }), fallback)
        XCTAssertEqual(probed, 0)
    }

    // MARK: - normalizedCandidate（写者与 resolve 共用的合法尺）

    /// 写者（SessionRecorder 回吐候选）必须与 resolve 用同一把尺：合法 → trim 后的串；非法 → nil。
    func testNormalizedCandidateAcceptsOnlyLocalAbsoluteOrTilde() {
        XCTAssertEqual(SessionRestore.normalizedCandidate("/a/b"), "/a/b")
        XCTAssertEqual(SessionRestore.normalizedCandidate(" /a/b \n"), "/a/b", "trim 后返回")
        XCTAssertEqual(SessionRestore.normalizedCandidate("~/dev"), "~/dev")
        XCTAssertEqual(SessionRestore.normalizedCandidate("~"), "~")
        for bad in [nil, "", "   ", "relative/path", "~foo", "sftp://h:22/a", "smb://s/share/a"] {
            XCTAssertNil(SessionRestore.normalizedCandidate(bad), "非法候选不得写回：\(bad ?? "nil")")
        }
    }

    // MARK: - SessionSnapshot 容错解码

    func testDecodesAllFields() throws {
        let json = #"{"version":2,"leftPath":"/l","rightPath":"/r","active":"right"}"#
        let s = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(s, SessionSnapshot(version: 2, leftPath: "/l", rightPath: "/r", active: "right"))
    }

    func testMissingFieldsTolerated() throws {
        let s = try JSONDecoder().decode(SessionSnapshot.self, from: Data("{}".utf8))
        XCTAssertEqual(s, SessionSnapshot(version: 1, leftPath: nil, rightPath: nil, active: "left"))
    }

    /// 单字段类型不符（手改垃圾）不得连累整份解码：另一侧与 active 仍须读回。
    func testCorruptSingleFieldDoesNotFailWholeDecode() throws {
        let json = #"{"version":1,"leftPath":123,"rightPath":"/r","active":"right"}"#
        let s = try JSONDecoder().decode(SessionSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.leftPath, "坏字段降级为 nil")
        XCTAssertEqual(s.rightPath, "/r", "好字段不受连累")
        XCTAssertEqual(s.active, "right")
    }

    func testInvalidActiveFallsBackToLeft() throws {
        let s = try JSONDecoder().decode(SessionSnapshot.self,
                                         from: Data(#"{"active":"sideways"}"#.utf8))
        XCTAssertEqual(s.active, "left")
    }

    func testRoundTrip() throws {
        let s = SessionSnapshot(version: 1, leftPath: "/l", rightPath: nil, active: "right")
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(SessionSnapshot.self, from: data), s)
    }
}
