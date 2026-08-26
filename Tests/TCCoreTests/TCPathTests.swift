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
}
