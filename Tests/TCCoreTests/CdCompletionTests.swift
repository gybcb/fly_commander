import XCTest
@testable import TCCore

final class CdCompletionTests: XCTestCase {
    private func item(_ name: String, dir: Bool = false) -> FileItem {
        FileItem(id: "/x/\(name)", path: TCPath(url: URL(fileURLWithPath: "/x/\(name)")),
                 name: name, isDirectory: dir, size: 0, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }

    // 夹具：Down/ 与 Down2/（目录），downFile.txt（文件）——小写前缀"down"三者都命中。
    private var items: [FileItem] {
        [item("Down", dir: true), item("downFile.txt"), item("Down2", dir: true)]
    }

    func testMatchFiltersByPrefixCaseInsensitive() {
        let r = CdCompletion.matches(prefix: "down", items: items)
        XCTAssertEqual(Set(r.map { $0.name }), ["Down", "downFile.txt", "Down2"])
    }

    func testMatchDirsFirst() {
        // 目录优先：Down, Down2（两个目录）先于 downFile.txt
        let r = CdCompletion.matches(prefix: "down", items: items)
        XCTAssertEqual(r.map { $0.name }, ["Down", "Down2", "downFile.txt"])
    }

    func testMatchEmptyPrefixListsAllDirsFirst() {
        // 空 prefix → 整个目录，目录优先
        let r = CdCompletion.matches(prefix: "", items: items)
        XCTAssertEqual(r.map { $0.name }, ["Down", "Down2", "downFile.txt"])
    }

    func testMatchNoHitEmpty() {
        XCTAssertEqual(CdCompletion.matches(prefix: "zzz", items: items).count, 0)
    }

    func testMatchCapTruncates() {
        let many = (0..<10).map { item("a\($0).txt") }
        XCTAssertEqual(CdCompletion.matches(prefix: "a", items: many, cap: 3).count, 3)
    }

    func testLcpCommon() {
        XCTAssertEqual(CdCompletion.longestCommonPrefix(["Down", "Down2"]), "Down")
    }
    func testLcpCaseInsensitiveKeepsFirstCase() {
        // 大小写不敏感：Down/downFile 共享 "down"，保留首项大小写 "Down"
        XCTAssertEqual(CdCompletion.longestCommonPrefix(["Down", "downFile.txt"]), "Down")
    }
    func testLcpNoCommon() {
        XCTAssertEqual(CdCompletion.longestCommonPrefix(["Down", "blue"]), "")
    }
    func testLcpSingle() {
        XCTAssertEqual(CdCompletion.longestCommonPrefix(["OnlyOne"]), "OnlyOne")
    }
    func testLcpEmpty() {
        XCTAssertEqual(CdCompletion.longestCommonPrefix([]), "")
        XCTAssertEqual(CdCompletion.longestCommonPrefix([""]), "")
    }

    func testTabUniqueResolves() {
        let r = CdCompletion.tabComplete(matches: [item("Down", dir: true)], cycleIndex: 0)!
        XCTAssertEqual(r.text, "Down")
        XCTAssertTrue(r.resolved)
    }

    func testTabMultipleFirstGivesCommonPrefix() {
        let r = CdCompletion.tabComplete(matches: [item("Down", dir: true), item("Down2", dir: true)],
                                         cycleIndex: 0)!
        XCTAssertEqual(r.text, "Down")
        XCTAssertFalse(r.resolved, "首次 Tab 多命中给公共前缀，供再次 Tab 循环")
    }

    func testTabMultipleCycleSecondGivesFirstItem() {
        let m = [item("Down", dir: true), item("Down2", dir: true)]
        let r = CdCompletion.tabComplete(matches: m, cycleIndex: 1)!
        XCTAssertEqual(r.text, "Down")
        XCTAssertTrue(r.resolved)
    }

    func testTabMultipleCycleThirdGivesSecondItem() {
        let m = [item("Down", dir: true), item("Down2", dir: true)]
        let r = CdCompletion.tabComplete(matches: m, cycleIndex: 2)!
        XCTAssertEqual(r.text, "Down2")
        XCTAssertTrue(r.resolved)
    }

    func testTabMultipleCycleWraps() {
        let m = [item("Down", dir: true), item("Down2", dir: true), item("Down3", dir: true)]
        // cycleIndex 4 → (4-1)%3 = 0 → 第一项
        let r = CdCompletion.tabComplete(matches: m, cycleIndex: 4)!
        XCTAssertEqual(r.text, "Down")
    }

    func testTabNoHitNil() {
        XCTAssertNil(CdCompletion.tabComplete(matches: [], cycleIndex: 0))
    }
}
