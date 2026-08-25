import XCTest
import TCCore
@testable import FlyCommander

/// type-ahead 纯函数（PaneTableView.typeAheadSelectionIndex）：从焦点下一行环形找
/// 第一个 name 前缀匹配的项。覆盖"再按当前项首字母跳到下一同名项 / 忽略大小写 /
/// 无匹配返回 nil / 环绕 / 空输入不动"。
final class TypeAheadTests: XCTestCase {
    private func item(_ id: String, _ name: String) -> FileItem {
        FileItem(id: id, path: TCPath(url: URL(fileURLWithPath: "/x/\(name)")),
                 name: name, isDirectory: false, size: 0, modificationDate: .distantPast,
                 isHidden: false, isReadOnly: false, isExecutable: false)
    }
    // display 顺序 = selection 存储顺序（默认目录优先 + 名称；此处全文件）：
    // apple.txt, banana.txt, blue.txt, cherry.txt
    private let names = ["apple.txt", "banana.txt", "blue.txt", "cherry.txt"]
    private var itemByID: [String: FileItem] {
        names.reduce(into: [:]) { $0[$1] = item($1, $1) }
    }
    private var displayIDs: [String] { names }   // id == name（本夹具）
    private var selItems: [String] { names }

    private func focus(_ name: String?) -> String? { name }  // id == name

    func testFirstMatchAfterFocus() {
        // 焦点在 apple（行0），输入 "b" → 下一行起第一个 b* = banana（行1）
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("apple.txt"), prefix: "b"), 1)
    }

    func testSecondPressJumpsToNextSamePrefix() {
        // 焦点已在 banana（行1），再输入 "b" → 跳过 banana，找下一个 b* = blue（行2）
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("banana.txt"), prefix: "b"), 2)
    }

    func testWrapsAround() {
        // 焦点在 cherry（末行3），输入 "a" → 环形回绕到首行 apple（行0）
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("cherry.txt"), prefix: "a"), 0)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("apple.txt"), prefix: "CHERRY"), 3)
    }

    func testMultiCharPrefix() {
        // "bl" 在焦点 apple 之后 → blue（banana 不以 bl 开头）
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("apple.txt"), prefix: "bl"), 2)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("apple.txt"), prefix: "zzz"))
    }

    func testEmptyPrefixReturnsNil() {
        XCTAssertNil(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: focus("apple.txt"), prefix: ""))
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(PaneTableView.typeAheadSelectionIndex(
            displayIDs: [], itemByID: [:], selectionItems: [], focusID: nil, prefix: "a"))
    }

    func testNilFocusStartsFromFirst() {
        // 无焦点（空页/切换中）从首行找 → apple
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: selItems,
            focusID: nil, prefix: "c"), 3)
    }

    func testReturnsSelectionIndexNotDisplayRow() {
        // display 与 selection 顺序不同：把 selection 存储序打乱成 [cherry, apple, blue, banana]，
        // display 仍按名称 [apple, banana, blue, cherry]。焦点 apple（display 0），
        // 输入 "blue" 前缀 "bl" → display 行2 = blue，其在 selection 里是 index 2。
        let sel = ["cherry.txt", "apple.txt", "blue.txt", "banana.txt"]
        XCTAssertEqual(PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs, itemByID: itemByID, selectionItems: sel,
            focusID: focus("apple.txt"), prefix: "bl"), 2)
    }
}
