import XCTest
import Foundation
@testable import TCCore

final class FileSearcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("deep/nested"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        try "1".write(to: root.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        try "2".write(to: root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "3".write(to: root.appendingPathComponent("docs/report.txt"), atomically: true, encoding: .utf8)
        try "4".write(to: root.appendingPathComponent("deep/nested/report.txt"), atomically: true, encoding: .utf8)
        try "5".write(to: root.appendingPathComponent(".hidden/secret.txt"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - NamePattern

    func testWildcardSuffixMatches() {
        let p = NamePattern("*.txt")
        XCTAssertTrue(p.matches("report.txt"))
        XCTAssertFalse(p.matches("report.pdf"))
        XCTAssertFalse(p.matches("txt"))
    }

    func testQuestionMarkSingleChar() {
        let p = NamePattern("a?c")
        XCTAssertTrue(p.matches("abc"))
        XCTAssertTrue(p.matches("axc"))
        XCTAssertFalse(p.matches("ac"))
        XCTAssertFalse(p.matches("abbc"))
    }

    func testCaseSensitivity() {
        XCTAssertTrue(NamePattern("*.TXT", caseSensitive: false).matches("report.txt"))
        XCTAssertFalse(NamePattern("*.TXT").matches("report.txt"))
    }

    func testPlainNameExactMatch() {
        let p = NamePattern("report.txt")
        XCTAssertTrue(p.matches("report.txt"))
        XCTAssertFalse(p.matches("report.txt.bak"))
    }

    // MARK: - search

    private func hitNames(_ hits: [SearchHit]) -> Set<String> {
        Set(hits.map { $0.name })
    }

    func testRecursiveSearchFindsNestedMatches() {
        let hits = FileSearcher().search(root: TCPath(url: root), pattern: NamePattern("*.txt"))
        XCTAssertEqual(hits.count, 3)
        XCTAssertEqual(hitNames(hits), ["report.txt", "report.txt", "report.txt"])
        XCTAssertEqual(Set(hits.map { $0.path.pathString }),
                       Set([root.appendingPathComponent("report.txt").path,
                            root.appendingPathComponent("deep/nested/report.txt").path,
                            root.appendingPathComponent("docs/report.txt").path]))
    }

    func testHiddenFilesAreSkipped() {
        let hits = FileSearcher().search(root: TCPath(url: root), pattern: NamePattern("secret.txt"))
        XCTAssertTrue(hits.isEmpty)
    }

    func testDirectoryNamesCanMatch() {
        let hits = FileSearcher().search(root: TCPath(url: root), pattern: NamePattern("docs"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].name, "docs")
        XCTAssertTrue(hits[0].isDirectory)
    }

    func testCancelledReturnsEmpty() {
        let hits = FileSearcher().search(root: TCPath(url: root),
                                         pattern: NamePattern("*"),
                                         isCancelled: { true })
        XCTAssertTrue(hits.isEmpty)
    }

    func testLimitTruncates() {
        let hits = FileSearcher().search(root: TCPath(url: root),
                                         pattern: NamePattern("*.txt"),
                                         limit: 2)
        XCTAssertEqual(hits.count, 2)
    }

    func testProgressIsReported() {
        var reports: [Int] = []
        _ = FileSearcher().search(root: TCPath(url: root),
                                  pattern: NamePattern("*"),
                                  progress: { reports.append($0) })
        XCTAssertFalse(reports.isEmpty)
    }

    // MARK: - 通用过 FileSource（远端式源）

    func testSearchOverStubSourceRecursiveAndSkipsHidden() {
        let s = StubSource()
        let root = TCPath("sftp://h/")
        let hits = FileSearcher().search(root: root, pattern: NamePattern("*.txt"), source: s)
        XCTAssertEqual(Set(hits.map { $0.path.pathString }),
                       ["/a.txt", "/docs/a.txt"], "递归应找到两枚 a.txt 且跳过 .hidden/")
    }

    /// 目录环（symlink 指向祖先的真实场景）：搜索必须终止、已访问目录不得重复下潜。
    func testSearchTerminatesOnDirectoryCycle() {
        let s = CycleSource()
        let hits = FileSearcher().search(root: TCPath("sftp://c/"),
                                         pattern: NamePattern("*.txt"),
                                         source: s,
                                         isCancelled: { s.totalCalls() > 1000 })
        XCTAssertFalse(hits.isEmpty, "环不应阻止命中")
        XCTAssertEqual(s.calls["/"], 1)
        XCTAssertEqual(s.calls["/a"], 1, "已访问目录不得重复下潜；实际 calls=\(s.calls) hits=\(hits.map(\.path.pathString))")
        XCTAssertLessThan(s.totalCalls(), 1000, "搜索应在取消阈值前自然终止")
    }
}

/// 虚拟目录环：/a/loop 的内容 = 根的内容（含 /a）→ 无环防护时 DFS 永动。
private final class CycleSource: FileSource {
    var calls: [String: Int] = [:]
    func totalCalls() -> Int { calls.values.reduce(0, +) }
    var sourceID: String { "cycle-test" }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        calls[path.pathString, default: 0] += 1
        switch path.pathString {
        case "/": return [CycleSource.dir("/a"), CycleSource.file("/x.txt")]
        case "/a": return [CycleSource.dir("/a/loop")]
        case "/a/loop": return [CycleSource.dir("/a"), CycleSource.file("/x.txt")]
        default: return []
        }
    }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in Data() } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}

    private static func dir(_ p: String) -> FileItem {
        FileItem(id: p, path: TCPath("sftp://c\(p)"), name: p.split(separator: "/").last.map(String.init) ?? p,
                 isDirectory: true, size: 0, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: true)
    }
    private static func file(_ p: String) -> FileItem {
        FileItem(id: p, path: TCPath("sftp://c\(p)"), name: p.split(separator: "/").last.map(String.init) ?? p,
                 isDirectory: false, size: 10, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }
}

/// 内存式远端源：`listDirectory` 按 pathString 字典返回，其余方法最小占位。
/// 用于验证 `FileSearcher.search` 已通用过 `FileSource`（不绑死本地 FileManager）。
private final class StubSource: FileSource {
    // 键 = TCPath.pathString（stub://h/x 的 pathString 即 "/x"）。
    var dirs: [String: [FileItem]] = [
        "/": [
            StubSource.item("/docs", dir: true),
            StubSource.item("/.hidden", dir: true, hidden: true),
            StubSource.item("/a.txt"),
            StubSource.item("/b"),           // 无扩展名，不匹配 *.txt
            StubSource.item("/c.md"),
        ],
        "/docs": [
            StubSource.item("/docs/a.txt"),
        ],
        // .hidden 不下潜（hidden 目录不进栈），故无需其内容。
    ]

    var sourceID: String { "sftp://h" }
    var isRemote: Bool { true }
    var supportsTransfer: Bool { false }

    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        dirs[path.pathString] ?? []
    }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at: TCPath) throws {}
    func removeItem(at: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle {
        return { _ in Data() }
    }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}

    private static func item(_ p: String, dir: Bool = false, hidden: Bool = false) -> FileItem {
        let name = p.split(separator: "/").last.map { String($0) } ?? p
        return FileItem(id: p, path: TCPath("sftp://h\(p)"), name: name,
                        isDirectory: dir, size: dir ? 0 : 10, modificationDate: .distantPast,
                        isHidden: hidden, isReadOnly: false, isExecutable: dir)
    }
}
