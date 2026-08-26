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
            XCTAssertEqual(error as? TCError, .invalidPath("路径不在共享内：/downloadsother"))
        }
    }

    func testToLocalRejectsDotDotEscape() {
        // standardizedFileURL 词法折叠 .. → 逃逸挂载点 → 抛错
        XCTAssertThrowsError(
            try SMBSource.toLocal(TCPath("smb://\(server)/\(share)/../../etc"),
                                  mountPoint: mount, share: share)) { error in
            XCTAssertTrue(error is TCError)
        }
    }

    func testToLocalRejectsOutsideSharePrefix() {
        // 不在 /<share>/ 前缀下的路径（另一共享/异常输入）一律抛错，不再兜底转发
        XCTAssertThrowsError(
            try SMBSource.toLocal(TCPath("smb://\(server)/other/x"),
                                  mountPoint: mount, share: share)) { error in
            XCTAssertEqual(error as? TCError, .invalidPath("路径不在共享内：/other/x"))
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
