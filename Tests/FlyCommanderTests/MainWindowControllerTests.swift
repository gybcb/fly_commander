import XCTest
import AppKit
@testable import FlyCommander
@testable import TCCore

/// 工具栏 label 重刷的可测核：纯映射函数 `toolbarLabels(lang:)`（不依赖窗口/NSApp），
/// 覆盖 identifier→键→各语言表值。真正的 `refreshLocalizedLabels()`（遍历真实 toolbar
/// items）在窗口层，留 Task 8 xcodebuild 冒烟。
final class MainWindowControllerTests: XCTestCase {
    // 下面两条 label 断言的变异面：删 toolbarLabelKeys 的 .smbConnect 映射，或删
    // L10nStrings 任一表的 .toolbarSMB 行 → key 缺失/查表 nil → 对应断言红
    // （双表同进另由 L10nTests.testEveryKeyTabledInEnglishAndChinese 双向兜底）。
    func testToolbarLabelsEnglish() {
        let en = MainWindowController.toolbarLabels(lang: .en)
        XCTAssertEqual(en[.copy], "Copy")
        XCTAssertEqual(en[.move], "Move")
        XCTAssertEqual(en[.makeDirectory], "New Directory")
        XCTAssertEqual(en[.delete], "Delete")
        XCTAssertEqual(en[.rename], "Rename")
        XCTAssertEqual(en[.search], "Find")
        XCTAssertEqual(en[.connect], "Connect")
        XCTAssertEqual(en[.smbConnect], "SMB")
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
        XCTAssertEqual(zh[.smbConnect], "SMB")
        XCTAssertEqual(zh[.theme], "主题")
    }
    func testSelectionStatusNotInLabelMap() {
        // selectionStatus 是状态文本 view（label 恒空），不参与语言重刷。
        XCTAssertNil(MainWindowController.toolbarLabels(lang: .en)[.selectionStatus])
        XCTAssertNil(MainWindowController.toolbarLabels(lang: .zh)[.selectionStatus])
    }

    /// SMB 工具栏入口端到端锁（issue #4）：真建 MainWindowController，断言 SMB 项
    /// ①出现在默认工具栏（default/allowed 列表 + delegate item 工厂都活着才可能过）、
    /// ②label 非空、③action 指向 menuSMBConnect（接线错到 SFTP 就红）。
    /// 上面两条纯映射测试**锁不住**这一段：删 delegate 的 .smbConnect case 或从
    /// default 列表删 .smbConnect → 两条语言测试仍绿（toolbarLabelKeys 映射未动），
    /// 唯本测试红（item 取不到/action 变 nil）。UITests 同款但只在 xcodebuild 层跑。
    /// 夹具纪律：不 orderFront（无入屏动画 → 无 _NSWindowTransformAnimation，
    /// 见记忆 reduced-sdk 的 close() SIGSEGV 条），测试结束置 nil 即回收。
    func testSMBToolbarItemWiredIntoDefaultToolbar() {
        let mc = MainWindowController()
        defer { mc.window = nil }
        guard let toolbar = mc.window?.toolbar else {
            return XCTFail("工具栏未装配（setupToolbar 断了）")
        }
        guard let item = toolbar.items.first(where: { $0.itemIdentifier == .smbConnect }) else {
            return XCTFail("默认工具栏无 SMB 项（identifier \"smbConnect\"）。红面含义：" +
                "①toolbarDefaultItemIdentifiers/Allowed 少了 .smbConnect，或 " +
                "②delegate 的 .smbConnect case 返回 nil——两种退化本测试都要红。")
        }
        XCTAssertEqual(item.label, "SMB", "SMB 项 label 须为 \"SMB\"（en/zh 同值）")
        XCTAssertEqual(item.action, #selector(MainViewController.menuSMBConnect(_:)),
                       "SMB 项 action 必须直达 menuSMBConnect（错接 SFTP 的 menuConnect 即红）")
        XCTAssertNotNil(item.image, "SMB 项须有图标（server.rack）")
    }

    /// default ⊆ allowed 结构不变量（issue #4 评审 major 零锁缺口）。工具栏自定义面板
    /// 只从 allowed 列表取可拖项；若 .smbConnect 漏进 default 却漏进 allowed，按钮仍显示
    /// （default 生效）但用户一旦移除就再也拖不回——全测试套件（含真窗 item 锁 + UITests
    /// 只验默认项）对此全绿。故显式钉 default ⊆ allowed 且 SMB 同时在两表。
    /// 变异：从 toolbarAllowedItemIdentifiers 删 .smbConnect → Set.isSubset 红。
    func testDefaultIdentifiersAreSubsetOfAllowed() {
        let mc = MainWindowController()
        defer { mc.window = nil }
        guard let toolbar = mc.window?.toolbar else { return XCTFail("工具栏未装配") }
        let d = Set(mc.toolbarDefaultItemIdentifiers(toolbar))
        let a = Set(mc.toolbarAllowedItemIdentifiers(toolbar))
        XCTAssertSubset(d, a, "default 项必须都在 allowed 内（否则移除后拖不回）")
        XCTAssertTrue(a.contains(.smbConnect), "allowed 缺 .smbConnect（移除后无法拖回）")
    }
}

private func XCTAssertSubset(_ x: Set<NSToolbarItem.Identifier>, _ y: Set<NSToolbarItem.Identifier>,
                             _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(x.isSubset(of: y), msg + "（差集：\(x.subtracting(y).map(\.rawValue).sorted())）",
                  file: file, line: line)
}
