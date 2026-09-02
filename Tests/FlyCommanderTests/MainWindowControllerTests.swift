import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// 工具栏 label 重刷的可测核：纯映射函数 `toolbarLabels(lang:)`（不依赖窗口/NSApp），
/// 覆盖 identifier→键→各语言表值。真正的 `refreshLocalizedLabels()`（遍历真实 toolbar
/// items）在窗口层，留 Task 8 xcodebuild 冒烟。
final class MainWindowControllerTests: XCTestCase {
    func testToolbarLabelsEnglish() {
        let en = MainWindowController.toolbarLabels(lang: .en)
        XCTAssertEqual(en[.copy], "Copy")
        XCTAssertEqual(en[.move], "Move")
        XCTAssertEqual(en[.makeDirectory], "New Directory")
        XCTAssertEqual(en[.delete], "Delete")
        XCTAssertEqual(en[.rename], "Rename")
        XCTAssertEqual(en[.search], "Find")
        XCTAssertEqual(en[.connect], "Connect")
        XCTAssertEqual(en[.theme], "Theme")
    }
    func testToolbarLabelsChinese() {
        let zh = MainWindowController.toolbarLabels(lang: .zh)
        XCTAssertEqual(zh[.copy], "复制")
        XCTAssertEqual(zh[.move], "移动")
        XCTAssertEqual(zh[.makeDirectory], "新建目录")
        XCTAssertEqual(zh[.delete], "删除")
        XCTAssertEqual(zh[.rename], "重命名")
        XCTAssertEqual(zh[.search], "查找")
        XCTAssertEqual(zh[.connect], "连接")
        XCTAssertEqual(zh[.theme], "主题")
    }
    func testSelectionStatusNotInLabelMap() {
        // selectionStatus 是状态文本 view（label 恒空），不参与语言重刷。
        XCTAssertNil(MainWindowController.toolbarLabels(lang: .en)[.selectionStatus])
        XCTAssertNil(MainWindowController.toolbarLabels(lang: .zh)[.selectionStatus])
    }
}
