import XCTest
import AppKit
@testable import FlyCommander
import TCCore

private func item(_ name: String) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: false,
             size: 1, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

/// 视觉 polish 一期：行底色四态（焦点双态 / 标记 / 斑马 / 普通）。
/// 用户报「哪个窗格活动全靠 1pt 边框」→ 焦点行改活动/非活动双态为主信号。
/// 断言走 layer.backgroundColor 解算值（FileCellViewThemeTests 同法，
/// NSColor(cgColor:) 本 SDK 为可失败初始化器）。
final class FileCellViewStateTests: XCTestCase {
    override func tearDown() {
        ThemeStore.shared.update(Theme.default)   // 复原共享单例
        super.tearDown()
    }

    private func bg(_ cell: FileCellView) -> NSColor {
        guard let cg = cell.layer?.backgroundColor, let c = NSColor(cgColor: cg) else {
            XCTFail("行底色缺失/不可解析"); return .clear
        }
        return c.usingColorSpace(.sRGB) ?? c
    }

    /// 焦点行·活动窗格 = accent 实底（红色 accent 探针）。
    func testFocusInActivePaneUsesSolidAccent() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 0,
                       paneActive: true)
        let c = bg(cell)
        XCTAssertEqual(c.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(c.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(c.alphaComponent, 1, accuracy: 0.01, "活动焦点行=实底")
    }

    /// 焦点行·非活动窗格 = 非强调选中灰底：必须与 accent 实底**不同**（红 accent 下
    /// 不得偏红），且非透明。
    func testFocusInInactivePaneIsGrayNotAccent() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 0,
                       paneActive: false)
        let c = bg(cell)
        XCTAssertLessThan(c.redComponent - c.greenComponent, 0.2,
                          "非活动焦点底不得带 accent 色相（应灰调）")
    }

    /// 斑马纹行 = 半透明微染（alpha 介于 0.01~0.1），与纯 controlBackgroundColor（alpha=1）区分。
    func testZebraRowIsTranslucentTint() {
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: false, marked: false, column: 0,
                       paneActive: true, zebra: true)
        let c = bg(cell)
        XCTAssertGreaterThan(c.alphaComponent, 0, "斑马微染是半透明合成色")
        XCTAssertLessThan(c.alphaComponent, 0.5)
    }

    /// 优先级：斑马不得盖过标记/焦点（focus 与 marked 行即使 zebra=true 也不是微染底）。
    func testZebraDoesNotOverrideFocusOrMarked() {
        let solid = FileCellView(frame: .zero)
        solid.configure(item: item("a.txt"), focus: true, marked: false, column: 0,
                        paneActive: true, zebra: true)
        XCTAssertEqual(bg(solid).alphaComponent, 1, accuracy: 0.01, "焦点行仍是实底")
        let marked = FileCellView(frame: .zero)
        marked.configure(item: item("a.txt"), focus: false, marked: true, column: 0,
                         paneActive: true, zebra: true)
        XCTAssertGreaterThan(bg(marked).alphaComponent, 0.1, "标记行仍是 accent 淡底")
    }

    /// 普通行 = 不透明 controlBackgroundColor（alpha=1，无微染）。
    func testPlainRowIsOpaque() {
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: false, marked: false, column: 0,
                       paneActive: true, zebra: false)
        XCTAssertEqual(bg(cell).alphaComponent, 1, accuracy: 0.01)
    }

    // MARK: - 大小/日期标签随选中态反色（用户报「选中只反色文件名」）

    /// 活动窗格焦点行 = accent 实底 → 三列标签全反白。旧 bug = 只 nameLabel 变白，
    /// size/date 停 secondaryLabelColor 压实底上不可读。断言走各列 configure。
    func testFocusedActiveRowInvertsSizeAndDateLabels() {
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 1,
                       paneActive: true)
        XCTAssertEqual(cell.sizeLabel.textColor, Style.rowFocusedText,
                       "大小列焦点行应随名字反白")
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 2,
                       paneActive: true)
        XCTAssertEqual(cell.dateLabel.textColor, Style.rowFocusedText,
                       "日期列焦点行应随名字反白")
    }

    /// 非活动窗格焦点行 = 灰底正文色 → meta 保持 secondary 灰（底不深，无需反白）。
    func testFocusedInactiveRowKeepsMetaSecondary() {
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 1,
                       paneActive: false)
        XCTAssertEqual(cell.sizeLabel.textColor, NSColor.secondaryLabelColor)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 2,
                       paneActive: false)
        XCTAssertEqual(cell.dateLabel.textColor, NSColor.secondaryLabelColor)
    }

    /// cell 复用串色守卫：先当过活动焦点行（meta 反白），再复用为普通/标记行 →
    /// meta 必须显式复位 secondary 灰。configure 三分支任一漏设 meta 色即红。
    func testMetaLabelsResetAfterReuseFromFocusedRow() {
        let cell = FileCellView(frame: .zero)
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 1,
                       paneActive: true)
        XCTAssertEqual(cell.sizeLabel.textColor, Style.rowFocusedText, "前提：焦点行反白")
        cell.configure(item: item("a.txt"), focus: false, marked: false, column: 1,
                       paneActive: true)
        XCTAssertEqual(cell.sizeLabel.textColor, NSColor.secondaryLabelColor,
                       "复用为普通行必须复位")
        cell.configure(item: item("a.txt"), focus: true, marked: false, column: 2,
                       paneActive: true)
        cell.configure(item: item("a.txt"), focus: false, marked: true, column: 2,
                       paneActive: true)
        XCTAssertEqual(cell.dateLabel.textColor, NSColor.secondaryLabelColor,
                       "复用为标记行必须复位（标记底是淡色，灰字可读）")
    }
}
