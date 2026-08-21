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
}
