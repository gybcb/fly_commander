import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// MainMenu 语言入口的可单测断言：build(target:) 为纯静态函数（不依赖 NSApp），
/// 语言切换后重建即得对应语言的标题——覆盖 View ▸ Language 子菜单与勾选态。
final class MainMenuTests: XCTestCase {
    override func setUp() { super.setUp(); L10n.current = .en }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    /// 纯函数：从已构建的 mainMenu 里按标题取子菜单（供测试遍历断言）。
    private func submenu(in menu: NSMenu, titled title: String) -> NSMenu? {
        menu.items.first { $0.submenu?.title == title }?.submenu
    }

    func testViewMenuHasLanguageSubmenuEnglish() {
        L10n.current = .en
        let main = MainMenu.build(target: NSObject())
        guard let view = submenu(in: main, titled: L10n.t(.menuView)) else {
            return XCTFail("查看菜单缺失")
        }
        let lang = view.items.first { $0.submenu?.title == L10n.t(.menuLanguage) }?.submenu
        XCTAssertNotNil(lang, "View 菜单应含 Language 子菜单")
        let titles = lang?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains("English"), "got: \(titles)")
        XCTAssertTrue(titles.contains(L10n.t(.langChineseName)), "got: \(titles)")
    }

    func testViewMenuHasLanguageSubmenuChinese() {
        L10n.current = .zh
        let main = MainMenu.build(target: NSObject())
        guard let view = submenu(in: main, titled: L10n.t(.menuView)) else {
            return XCTFail("查看菜单缺失")
        }
        XCTAssertEqual(L10n.t(.menuLanguage), "语言")
        let lang = view.items.first { $0.submenu?.title == "语言" }?.submenu
        XCTAssertNotNil(lang, "查看菜单应含 语言 子菜单")
        let titles = lang?.items.map(\.title) ?? []
        XCTAssertTrue(titles.contains(L10n.t(.langEnglishName)), "got: \(titles)")
        XCTAssertTrue(titles.contains("简体中文"), "got: \(titles)")
    }

    func testLanguageSubmenuChecksCurrentLanguage() {
        L10n.current = .en
        let main = MainMenu.build(target: NSObject())
        let lang = submenu(in: main, titled: L10n.t(.menuView))!
            .items.first { $0.submenu?.title == L10n.t(.menuLanguage) }?.submenu
        XCTAssertEqual(lang?.items.count, 2)
        // English（en 当前）应勾选，中文不应勾选。
        let en = lang?.items.first { $0.title == "English" }
        let zh = lang?.items.first { $0.title == L10n.t(.langChineseName) }
        XCTAssertEqual(en?.state, .on)
        XCTAssertEqual(zh?.state, .off)
    }
}
