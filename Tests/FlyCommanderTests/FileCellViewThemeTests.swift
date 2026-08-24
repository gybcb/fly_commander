import XCTest
import AppKit
@testable import FlyCommander
import TCCore

private func makeItem(_ name: String) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: false,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

final class FileCellViewThemeTests: XCTestCase {
    override func tearDown() {
        // 复原共享单例，避免污染同进程其它测试
        ThemeStore.shared.update(Theme.default)
    }

    func testMarkedRowBackgroundUsesAccent() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: makeItem("a.txt"), focus: false, marked: true, column: 0)
        guard let bg = cell.layer?.backgroundColor else {
            return XCTFail("marked 行应有背景色")
        }
        // 本 SDK NSColor(cgColor:) 为可失败初始化器，需解包后再取分量
        guard let c = NSColor(cgColor: bg) else {
            return XCTFail("marked 背景色无法解析为 NSColor")
        }
        XCTAssertGreaterThan(c.redComponent, c.blueComponent, "marked 底色应偏 accent(红)")
    }

    func testNameLabelUsesRuleColor() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 0, green: 0, blue: 0),
                                       fileColorRules: [FileColorRule(extensions: ["png"],
                                                                      color: ThemeColor(red: 0, green: 1, blue: 0))]))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: makeItem("a.png"), focus: false, marked: false, column: 0)
        XCTAssertEqual(cell.nameLabel.textColor?.greenComponent ?? 0, 1, accuracy: 0.01)
    }
}
