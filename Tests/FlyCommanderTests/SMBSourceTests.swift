import XCTest
import Foundation
@testable import FlyCommander
import TCCore

final class SMBSourceTests: XCTestCase {
    private let server = "truenas", share = "downloads"
    private var mount: URL!

    override func setUpWithError() throws {
        mount = FileManager.default.temporaryDirectory
            .appendingPathComponent("smbmount_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount.appendingPathComponent("docs"),
                                                withIntermediateDirectories: true)
        try "hello".write(to: mount.appendingPathComponent("a.txt"),
                          atomically: true, encoding: .utf8)
        try "nested".write(to: mount.appendingPathComponent("docs/n.txt"),
                           atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: mount)
        mount = nil
    }

    private func source() -> SMBSource {
        SMBSource(config: SMBConnectionConfig(server: server, share: share,
                                              domain: nil, username: "u"),
                  mountPoint: mount)
    }
    private func anyLocal() -> FileItem {
        FileItem(id: "whatever", path: TCPath("/tmp/x"), name: "n.txt",
                 isDirectory: false, size: 6, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    /// 行为钉子：含空格的 share，homePath 必须保持远端且与 toLocal 语义一致。
    /// 审查曾怀疑裸拼 TCPath 会回落本地分支——实测 macOS 14+ 的 URL 解析器对
    /// path 里的空格自动 percent-encode（host 含空格才返回 nil），并不成立。
    /// 留此测试防止未来 TCPath/URL 行为变化悄悄破坏该前提。
    func testHomePathWithSpaceShareStaysRemote() throws {
        let src = SMBSource(config: SMBConnectionConfig(server: "srv", share: "My Files",
                                                        domain: nil, username: "u"),
                            mountPoint: mount)
        XCTAssertTrue(src.homePath.isRemote, "含空格 share 不得回落本地分支")
        XCTAssertEqual(src.homePath.pathString, "/My Files")
        // share 根经 toLocal 应映射回挂载点（与无空格 share 同语义）
        XCTAssertEqual(try SMBSource.toLocal(src.homePath, mountPoint: mount,
                                             share: "My Files").url.path,
                       mount.path)
    }

    func testRemapSatisfiesIDEqualsPathString() {
        // 核心不变式：id == path.pathString（app revealItem 依赖）——由构造保证
        let smb = TCPath("smb://\(server)/\(share)/docs/n.txt")
        let r = SMBSource.remap(anyLocal(), to: smb)
        XCTAssertEqual(r.id, "/downloads/docs/n.txt")
        XCTAssertEqual(r.path.pathString, "/downloads/docs/n.txt")
        XCTAssertEqual(r.id, r.path.pathString, "不变式 id == path.pathString")
        XCTAssertTrue(r.path.isRemote)
    }

    func testToLocalMapsRootAndNested() throws {
        // 正常嵌套映射（回归——不得抛错）
        let p = TCPath("smb://\(server)/\(share)/docs/n.txt")
        XCTAssertEqual(try SMBSource.toLocal(p, mountPoint: mount, share: share).url.path,
                       mount.appendingPathComponent("docs/n.txt").path)
        // share 根 → 挂载点本身（不重复拼 share 名）
        XCTAssertEqual(try SMBSource.toLocal(TCPath("smb://\(server)/\(share)"),
                                             mountPoint: mount, share: share).url.path,
                       mount.path)
    }

    func testToLocalRejectsSiblingShareBoundary() {
        // 段边界：/downloadsother 与 /downloads 是不同共享，不得误路由到挂载点内
        XCTAssertThrowsError(
            try SMBSource.toLocal(TCPath("smb://\(server)/downloadsother"),
                                  mountPoint: mount, share: share)) { error in
            // Plan B T3：语义 case + 边界中英双断（翻转≠弱化，payload=smb 路径原文）。
            let tc = error as? TCError
            XCTAssertEqual(tc, .pathOutsideShare("/downloadsother"))
            XCTAssertEqual(tc.map(tcErrorDisplay), "Path outside share: /downloadsother")
            L10n.current = .zh
            defer { L10n.current = .en }
            XCTAssertEqual(tc.map(tcErrorDisplay), "路径不在共享内：/downloadsother")
        }
    }

    func testToLocalRejectsDotDotEscape() {
        // standardizedFileURL 词法折叠 .. → 逃逸挂载点 → 抛错
        XCTAssertThrowsError(
            try SMBSource.toLocal(TCPath("smb://\(server)/\(share)/../../etc"),
                                  mountPoint: mount, share: share)) { error in
            // Plan B T3：精确语义 case（此前只断 error is TCError）+ 中英双断。
            let tc = error as? TCError
            XCTAssertEqual(tc, .pathEscaped("/downloads/../../etc"))
            XCTAssertEqual(tc.map(tcErrorDisplay),
                           "Path escaped the mount point: /downloads/../../etc")
            L10n.current = .zh
            defer { L10n.current = .en }
            XCTAssertEqual(tc.map(tcErrorDisplay), "路径逃逸挂载点：/downloads/../../etc")
        }
    }

    func testToLocalRejectsOutsideSharePrefix() {
        // 不在 /<share>/ 前缀下的路径（另一共享/异常输入）一律抛错，不再兜底转发
        XCTAssertThrowsError(
            try SMBSource.toLocal(TCPath("smb://\(server)/other/x"),
                                  mountPoint: mount, share: share)) { error in
            XCTAssertEqual(error as? TCError, .pathOutsideShare("/other/x"))
        }
    }

    func testListDirectoryRemapsAndRecursiveRead() throws {
        let s = source()
        let root = try s.listDirectory(TCPath("smb://\(server)/\(share)"))
        XCTAssertEqual(Set(root.map(\.name)), ["docs", "a.txt"])
        XCTAssertEqual(Set(root.map(\.id)), ["/downloads/docs", "/downloads/a.txt"])
        // 递归进 docs：item.path 可直接再 list（pathString 即相对远端绝对路径）
        let docs = try XCTUnwrap(root.first { $0.name == "docs" })
        let sub = try s.listDirectory(docs.path)
        XCTAssertEqual(sub.map(\.name), ["n.txt"])
        XCTAssertEqual(sub[0].id, "/downloads/docs/n.txt")
    }

    func testCopyAndDeleteWithinMount() throws {
        let s = source()
        let root = TCPath("smb://\(server)/\(share)")
        let a = try XCTUnwrap(try s.listDirectory(root).first { $0.name == "a.txt" })
        try s.copyItem(from: a.path, to: TCPath("smb://\(server)/\(share)/a2.txt"))
        XCTAssertTrue(try s.listDirectory(root).map(\.name).contains("a2.txt"))
        try s.removeItem(at: TCPath("smb://\(server)/\(share)/a2.txt"))
        XCTAssertFalse(try s.listDirectory(root).map(\.name).contains("a2.txt"))
    }

    func testMakeDirectoryAndStat() throws {
        let s = source()
        let newDir = TCPath("smb://\(server)/\(share)/newdir")
        try s.makeDirectory(at: newDir)
        let item = try s.stat(newDir)
        XCTAssertEqual(item?.isDirectory, true)
        XCTAssertEqual(item?.id, "/downloads/newdir")
        XCTAssertEqual(item?.id, item?.path.pathString)
    }
}
