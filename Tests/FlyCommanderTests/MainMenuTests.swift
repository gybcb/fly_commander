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

    func testLanguageSubmenuChecksCurrentLanguageChinese() {
        L10n.current = .zh
        let main = MainMenu.build(target: NSObject())
        let lang = submenu(in: main, titled: L10n.t(.menuView))!
            .items.first { $0.submenu?.title == L10n.t(.menuLanguage) }?.submenu
        XCTAssertEqual(lang?.items.count, 2)
        // zh 当前：中文项应勾选，English 不应勾选。
        let en = lang?.items.first { $0.title == L10n.t(.langEnglishName) }
        let zh = lang?.items.first { $0.title == "简体中文" }
        XCTAssertEqual(zh?.state, .on)
        XCTAssertEqual(en?.state, .off)
    }

    /// View ▸ Refresh 键位锁：keyEquivalent=="r" 且 **mask 显式 .control**（⌃R）。
    /// 双负锁：① 键位是 ⌃R 不是 ⌘R（⌘R 已被文件菜单的重命名占用，撞键=重命名劫持刷新）；
    /// ② 文件菜单的重命名仍是 ⌘R（刷新没把它挤掉）。
    /// 变异：MainMenu 里 refresh 项忘传 mask 参数 → 落 add() 缺省 .command → mask 断言红；
    /// 改成 ⌃⇧R 之类 → mask 含 .shift 红；把 viewMenu 的键位误设 "r"+.command → 与重命名
    /// 双 ⌘R 撞键，此用例不红（同串），但 UI 实测（S2）+重命名回归会抓。
    func testRefreshItemIsControlRNotCommandR() throws {
        L10n.current = .en
        let main = MainMenu.build(target: NSObject())
        let view = try XCTUnwrap(submenu(in: main, titled: L10n.t(.menuView)))
        let refresh = try XCTUnwrap(view.items.first { $0.title == L10n.t(.refresh) }, "View 菜单缺刷新项")
        XCTAssertEqual(refresh.keyEquivalent, "r")
        XCTAssertEqual(refresh.keyEquivalentModifierMask, [.control], "刷新须是 ⌃R（防落缺省 ⌘）")
        XCTAssertEqual(refresh.action, #selector(MainViewController.menuRefresh(_:)))

        // 重命名（文件菜单）保持 ⌘R——刷新用 ⌃R 正是为避开它。
        let file = try XCTUnwrap(submenu(in: main, titled: L10n.t(.menuFile)))
        let rename = try XCTUnwrap(file.items.first { $0.title == L10n.t(.rename) })
        XCTAssertEqual(rename.keyEquivalent, "r")
        XCTAssertEqual(rename.keyEquivalentModifierMask, [.command])
    }
}
