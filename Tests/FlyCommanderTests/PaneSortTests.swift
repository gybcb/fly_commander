import XCTest
import AppKit
import TCCore
@testable import FlyCommander

final class PaneSortTests: XCTestCase {
    private func item(_ id: String, name: String, size: Int64, date: Date, isDir: Bool = false) -> FileItem {
        FileItem(id: id, path: TCPath("/tmp/\(name)"), name: name, isDirectory: isDir,
                 size: size, modificationDate: date, isHidden: false,
                 isReadOnly: false, isExecutable: false)
    }

    private func context() -> ([String], [String: FileItem]) {
        let d1 = Date(timeIntervalSince1970: 1000)
        let d2 = Date(timeIntervalSince1970: 2000)
        let items: [String: FileItem] = [
            "a": item("a", name: "beta.txt", size: 100, date: d2),
            "b": item("b", name: "alpha.bin", size: 2000, date: d1),
            "c": item("c", name: "gamma.dat", size: 5, date: d1),
        ]
        return (["a", "b", "c"], items)
    }

    func testNameAscending() {
        let (ids, items) = context()
        XCTAssertEqual(PaneTableView.sortedIDs(ids, items: items, key: .name, direction: .ascending),
                       ["b", "a", "c"])
    }

    func testNameDescending() {
        let (ids, items) = context()
        XCTAssertEqual(PaneTableView.sortedIDs(ids, items: items, key: .name, direction: .descending),
                       ["c", "a", "b"])
    }

    func testSizeAscendingDirsFirst() {
        let (_, baseItems) = context()
        var items = baseItems
        let dir = item("d", name: "alpha.bin", size: 0, date: Date(timeIntervalSince1970: 1), isDir: true)
        items["d"] = dir
        // 目录大小按 0 计：d(0) < c(5) < a(100) < b(2000)
        XCTAssertEqual(PaneTableView.sortedIDs(["a", "b", "c", "d"], items: items, key: .size, direction: .ascending),
                       ["d", "c", "a", "b"])
    }

    func testDateAscendingTiesByName() {
        let (ids, items) = context()
        // b 与 c 同日期 → 按名称 tie-break：alpha.bin < gamma.dat
        XCTAssertEqual(PaneTableView.sortedIDs(ids, items: items, key: .date, direction: .ascending),
                       ["b", "c", "a"])
    }

    func testEmptyInput() {
        XCTAssertEqual(PaneTableView.sortedIDs([], items: [:], key: .name, direction: .ascending), [])
    }

    /// items 字典缺 id（可见集与 items 短暂不同步的第二道防线）→ 跳过该 id 不崩。
    /// 变异：把 compactMap 改回 `items[id]!` → 本用例 trap。
    func testSortedIDsSkipsMissingItems() {
        let (ids, items) = context()
        XCTAssertEqual(PaneTableView.sortedIDs(ids + ["ghost"], items: items,
                                               key: .name, direction: .ascending),
                       ["b", "a", "c"])
        XCTAssertEqual(PaneTableView.sortedIDs(ids + ["ghost"], items: items,
                                               key: .size, direction: .ascending),
                       PaneTableView.sortedIDs(ids, items: items, key: .size, direction: .ascending))
        XCTAssertEqual(PaneTableView.sortedIDs(ids + ["ghost"], items: items,
                                               key: .date, direction: .ascending),
                       PaneTableView.sortedIDs(ids, items: items, key: .date, direction: .ascending))
    }

    /// 全部 id 都缺失 → 空数组（不 trap）。
    /// 变异：去掉 `guard !present.isEmpty` 前的 compactMap 过滤 → 本用例 trap。
    func testSortedIDsAllMissingReturnsEmpty() {
        XCTAssertEqual(PaneTableView.sortedIDs(["ghost"], items: [:], key: .name, direction: .ascending), [])
    }
}
