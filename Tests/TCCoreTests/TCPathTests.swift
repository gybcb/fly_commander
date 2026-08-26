import XCTest
import Foundation
@testable import TCCore

final class TCPathTests: XCTestCase {
    func testParentOfNested() {
        let p = TCPath("/a/b/c")
        XCTAssertEqual(p.parent?.pathString, "/a/b")
    }
    func testRootHasNoParent() {
        XCTAssertEqual(TCPath("/").parent, nil)
    }
    func testJoining() {
        XCTAssertEqual(TCPath("/a/b").joining("c").pathString, "/a/b/c")
    }
    func testIsHiddenDotfile() {
        XCTAssertTrue(TCPath("/a/.zshrc").isHidden)
        XCTAssertFalse(TCPath("/a/file").isHidden)
    }
    func testTildeExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let p = TCPath("~/dev")
        XCTAssertEqual(p.pathString, home.appendingPathComponent("dev").path)
    }
    func testDisplayStringUsesTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(TCPath(home + "/dev").displayString(), "~/dev")
        XCTAssertEqual(TCPath(home).displayString(), "~")
    }

    // MARK: - sftp scheme

    private let sftpURL = URL(string: "sftp://example.com:2222/a/b")!

    func testSftpURLKeepsSchemeHostPort() {
        let p = TCPath(url: sftpURL)
        XCTAssertEqual(p.url.scheme, "sftp")
        XCTAssertEqual(p.url.host, "example.com")
        XCTAssertEqual(p.url.port, 2222)
        XCTAssertEqual(p.pathString, "/a/b")
    }

    func testSftpDefaultPortURL() {
        let p = TCPath(url: URL(string: "sftp://example.com/a")!)
        XCTAssertEqual(p.url.scheme, "sftp")
        XCTAssertEqual(p.url.host, "example.com")
        XCTAssertNil(p.url.port)
        XCTAssertEqual(p.pathString, "/a")
    }

    func testSftpStringInitKeepsScheme() {
        let p = TCPath("sftp://example.com:2222/a/b")
        XCTAssertEqual(p.url.scheme, "sftp")
        XCTAssertEqual(p.url.host, "example.com")
        XCTAssertEqual(p.url.port, 2222)
        XCTAssertEqual(p.pathString, "/a/b")
    }

    func testSftpIsRemote() {
        XCTAssertTrue(TCPath(url: sftpURL).isRemote)
        XCTAssertFalse(TCPath("/a/b").isRemote)
    }

    func testSftpTildeNotExpanded() {
        // 远端家目录语义由 SFTPSource 负责（realPath/~ 解析），TCPath 不做本地展开。
        let p = TCPath("sftp://example.com/~")
        XCTAssertEqual(p.pathString, "/~")
        XCTAssertEqual(p.fileName, "~")
    }

    func testSftpParentAndJoining() {
        let p = TCPath(url: sftpURL)
        XCTAssertEqual(p.parent?.pathString, "/a")
        XCTAssertTrue(p.parent!.url.absoluteString.hasPrefix("sftp://example.com:2222"))
        XCTAssertEqual(p.joining("c").pathString, "/a/b/c")
    }

    func testSftpRoot() {
        let p = TCPath(url: URL(string: "sftp://example.com")!)
        XCTAssertTrue(p.isRoot)
        XCTAssertNil(p.parent)
    }

    func testSftpDisplayStringShowsHost() {
        XCTAssertEqual(TCPath(url: sftpURL).displayString(), "sftp://example.com:2222/a/b")
        // 默认端口不显示。
        XCTAssertEqual(TCPath(url: URL(string: "sftp://example.com/a")!).displayString(),
                       "sftp://example.com/a")
    }

    // MARK: - smb scheme

    func testSMBPathIsRemote() {
        let p = TCPath("smb://truenas/downloads/docs/a.txt")
        XCTAssertTrue(p.isRemote, "smb:// 应判为远端")
        XCTAssertEqual(p.pathString, "/downloads/docs/a.txt", "pathString 丢 host、保留 /share/rel")
        XCTAssertEqual(p.fileName, "a.txt")
    }
    func testSMBDisplayStringUsesActualScheme() {
        // displayString 现写死 sftp://——smb 路径须渲染为 smb://
        XCTAssertEqual(TCPath("smb://truenas/downloads/x").displayString(),
                       "smb://truenas/downloads/x", "displayString 用实际 scheme")
    }
    func testSFTPDisplayStringUnchanged() {
        // sftp 分支回归：port 缺省省略、有 port 带 port
        XCTAssertEqual(TCPath("sftp://h:22/a").displayString(), "sftp://h:22/a")
        XCTAssertEqual(TCPath("sftp://h/a").displayString(), "sftp://h/a", "无 port 不追加 :port")
    }
    func testSMBPathStringDropsHost() {
        // 关键不变式：id 将取 pathString，须与 SFTP 的 fullPath 语义一致（无 host）
        XCTAssertEqual(TCPath("smb://truenas/downloads/x").pathString, "/downloads/x")
    }

    func testLocalPathUnaffected() {
        let p = TCPath("/a/b/../c")
        XCTAssertEqual(p.pathString, "/a/c")
        XCTAssertFalse(p.isRemote)
    }

    // MARK: - 远端 URL 解析失败回落本地（防强解包崩溃）

    func testRemoteSchemeWithUnencodableCharDoesNotCrash() {
        // 服务器名（host 部分）含空格是非法 URL 字符——本机 SDK 实测 URL(string:) 返回 nil，
        // 旧实现 `URL(string:)!` 强解包直接 trap 崩 app。修复后回落本地路径分支：不崩、
        // isRemote == false、按本地路径语义保留原串（会被 LocalFileSource 当不存在路径处理）。
        let smb = TCPath("smb://bad host/x")
        XCTAssertFalse(smb.isRemote, "smb:// 解析失败应回落本地，不崩")
        XCTAssertTrue(smb.pathString.contains("bad host"), "回落本地后保留原串")
        let sftp = TCPath("sftp://bad host:22/x")
        XCTAssertFalse(sftp.isRemote, "sftp:// 解析失败应回落本地，不崩")
        XCTAssertTrue(sftp.pathString.contains("bad host"), "回落本地后保留原串")
    }

    func testValidRemotePathsStillRemote() {
        // 回归锚：合法远端路径不得被误降级。
        let smb = TCPath("smb://truenas._smb._tcp.local/downloads")
        XCTAssertTrue(smb.isRemote, "合法 smb:// 仍是远端")
        XCTAssertEqual(smb.pathString, "/downloads")
        // 实测结论（本机 SDK，swift 探针跑过）：URL(string:) 只拒绝 host 部分含空格
        // （→ nil）；path 部分含空格会被**自动百分号编码**，解析成功——
        // "sftp://h:22/a b" -> absoluteString "sftp://h:22/a%20b"，path 解码回 "/a b"。
        // 故此处不回落，仍为远端（与 host 含空格的行为形成对照）。
        let sftp = TCPath("sftp://h:22/a b")
        XCTAssertTrue(sftp.isRemote, "path 含空格实测自动编码，解析成功，仍为远端")
        XCTAssertEqual(sftp.pathString, "/a b")
        XCTAssertEqual(sftp.url.host, "h")
        XCTAssertEqual(sftp.url.port, 22)
        XCTAssertEqual(sftp.url.absoluteString, "sftp://h:22/a%20b")
    }
}
