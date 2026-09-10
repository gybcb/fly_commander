import XCTest
import AppKit
@testable import FlyCommander
import TCCore

// MARK: - issue #2「大小栏宽度够、右边的字被遮挡」回归
//
// 根因（spike 实测 2026-09-10）：旧 FileCellView 四视图共用一条横向链跑所有列——
// 大小列里隐藏图标(16pt)+空名称标签仍占左缘 ~32pt、空日期标签占右缘，右对齐的
// 大小文本（"88.9 MB" 需 ~49pt）被挤到 70pt cell 右缘外 ~11pt。修法 = 每列独立
// 约束集（未用视图整套停用），大小标签铺满整格。
// 差分基线：HEAD 旧版上本类 4/4 红（testSizeColumnFitsDefaultWidth 实测
// maxX 79>70，与用户症状精确对应）；修复版全绿。

private func fileItem(_ name: String, size: Int64) -> FileItem {
    FileItem(id: "/\(name)", path: TCPath("/\(name)"), name: name, isDirectory: false,
             size: size, modificationDate: .distantPast, isHidden: false,
             isReadOnly: false, isExecutable: false)
}

/// 列宽常量与 PaneTableView 缺省值对钉（评审 minor：注释联动会漂）。
/// 变异：改 PaneTableView 的 width 常量不同步这里 → 本断言红，逼两处同步。
private let defaultSizeColWidth: CGFloat = 70
private let minSizeColWidth: CGFloat = 40
private let defaultDateColWidth: CGFloat = 150

final class FileCellLayoutTests: XCTestCase {
    /// 大小列在缺省列宽（=PaneTableView size.width）下文本完整落在 cell 内。
    /// 变异实测：① 删 configure 的 applyLayout 调用 → sizeLabel 无任何激活约束、
    /// frame 塌成 ~0 宽，fitting(47) > frame+0.5 红（maxX 断言在塌缩态反而平凡过，
    /// 溢出方向的真实红面 = HEAD 差分基线 maxX 79>70）；② 回退整文件到 HEAD 单链
    /// → 两条溢出断言皆红。
    func testSizeColumnFitsDefaultWidth() {
        let cell = FileCellView(frame: NSRect(x: 0, y: 0, width: defaultSizeColWidth, height: 20))
        cell.configure(item: fileItem("big.bin", size: 88_900_000), focus: false, marked: false, column: 1)
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(cell.sizeLabel.stringValue.isEmpty, "前置：大小文本已填充")
        let f = cell.sizeLabel.frame
        XCTAssertGreaterThanOrEqual(f.minX, 0, "大小文本左缘不得越出 cell（got \(f.minX)）")
        XCTAssertLessThanOrEqual(f.maxX, defaultSizeColWidth,
                                 "大小文本右缘不得越出 cell（got \(f.maxX)）")
        XCTAssertLessThanOrEqual(cell.sizeLabel.fittingSize.width, f.width + 0.5,
                                 "给定列宽内不得截断（fitting \(cell.sizeLabel.fittingSize.width) > frame \(f.width)）")
    }

    /// min 宽（size.minWidth）下允许截断省略，但**绝不溢出** cell 右缘。
    /// 变异实测：回退 HEAD 单链 → maxX 79>40 红；sizeLabel 缺 byTruncatingTail/
    /// 低压缩优先级 → 40pt 下 AutoLayout 弃 trailing 约束、frame 保持 51 宽溢出红
    /// （修复落地前此断言实测红过，非假锚）。
    func testSizeColumnNeverOverflowsEvenAtMinWidth() {
        let cell = FileCellView(frame: NSRect(x: 0, y: 0, width: minSizeColWidth, height: 20))
        cell.configure(item: fileItem("big.bin", size: 88_900_000), focus: false, marked: false, column: 1)
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cell.sizeLabel.frame.maxX, minSizeColWidth,
                                 "窄列下大小文本可截断但不得溢出（got \(cell.sizeLabel.frame.maxX)）")
    }

    /// 名称列双向锚：超长名称**截断在格内**（右缘不越界）且**不被压扁**（宽度下界）。
    /// 上界变异：删 byTruncatingTail/低压缩优先级 → HEAD 实测 fitting 2865、frame
    /// maxX 2891>120 红。下界变异（评审 critical 案例=名称 trailing 被误钉 icon 尾 →
    /// 名称塌成 ~4pt）→ width>60 红。两向都咬。
    func testLongNameTruncatesWithinCell() {
        let long = String(repeating: "很长很长的文件名", count: 30)
        let cell = FileCellView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        cell.configure(item: fileItem(long, size: 1), focus: false, marked: false, column: 0)
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(cell.nameLabel.frame.minX, 0, "名称左缘不得越出 cell")
        XCTAssertLessThanOrEqual(cell.nameLabel.frame.maxX, 120, "名称不得越出列右缘")
        XCTAssertGreaterThan(cell.nameLabel.frame.width, 60,
                             "名称列须拿到列宽的大头（塌缩/被误钉 → 红）")
        XCTAssertGreaterThan(cell.nameLabel.fittingSize.width, cell.nameLabel.frame.width,
                             "超长名称应处于被截断态（fitting > frame）而非撑爆列")
    }

    /// 列复用卫生（换列路防御锁）：同格先名称列后大小列，大小布局完整接管，且
    /// **旧列（名称套）约束必须停用**。鉴别法=换列后把 cell 拉宽 140 再排版：
    /// 正确态 name 套已 deactivate，nameLabel（空串+隐藏）塌到固有 ~0 宽；
    /// deactivate 半句被删（约束泄漏）→ nameLabel 被 leading28+trailing-6 随新宽
    /// 重排成 ~110 宽（变异实测 110>20 红）→ 上界红。两套约束钉的是不同标签、
    /// 互不冲突，「同时激活」对静态几何断言全盲（评审实证过该盲区）——必须用
    /// 尺寸扰动响应来锁。
    func testColumnSwitchReplacesLayout() {
        let cell = FileCellView(frame: NSRect(x: 0, y: 0, width: defaultSizeColWidth, height: 20))
        cell.configure(item: fileItem("a.bin", size: 88_900_000), focus: false, marked: false, column: 0)
        cell.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(cell.nameLabel.frame.width, 20, "前置：名称列布局已生效")
        cell.configure(item: fileItem("a.bin", size: 88_900_000), focus: false, marked: false, column: 1)
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cell.sizeLabel.frame.maxX, defaultSizeColWidth, "换列后大小布局须完整接管")
        XCTAssertTrue(cell.dateLabel.isHidden)
        cell.frame.size.width = 140
        cell.layoutSubtreeIfNeeded()
        XCTAssertLessThan(cell.nameLabel.frame.width, 20,
                          "换列后旧列约束必须停用（泄漏→nameLabel 随 cell 重排成 ~110 宽）")
    }

    /// 日期列布局合同（评审：三套约束里 date 套原本零覆盖）。钉三件事：
    /// ① 文本在缺省列宽内不溢出（与大小列同款 issue #2 症状防线——date 套换成
    ///    空数组/错 leading/错 trailing 都会红）；② **右对齐合同**（HEAD 单链里
    ///    dateLabel 只钉 trailing 靠固有宽贴右缘；铺满改造后必须显式 .right）——
    ///    只能锁 alignment 属性本身：frame 被约束钉死，文本在 frame 内左/右排
    ///    frame 不变，几何断言锁不住对齐（探针实测确认）；③ trailing 约束落位
    ///    （NSTextField(labelWithString:) 带 ~2pt 布局边距，frame.maxX=列宽-6+2，
    ///    探针实测 146 vs 144）。
    /// 变异：dateLabel.alignment 删行 → ② 红；date 套 trailing 常量错 → ③ 红。
    func testDateColumnLayoutAndRightAlignment() {
        let cell = FileCellView(frame: NSRect(x: 0, y: 0, width: defaultDateColWidth, height: 20))
        cell.configure(item: fileItem("a.bin", size: 1), focus: false, marked: false, column: 2)
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(cell.dateLabel.stringValue.isEmpty, "前置：日期文本已填充")
        XCTAssertEqual(cell.dateLabel.alignment, .right,
                       "日期须右对齐（HEAD 视觉合同；frame 被约束钉死，几何断言锁不住对齐）")
        let f = cell.dateLabel.frame
        XCTAssertGreaterThanOrEqual(f.minX, 0, "日期文本左缘不得越出 cell（got \(f.minX)）")
        XCTAssertLessThanOrEqual(f.maxX, defaultDateColWidth, "日期文本不得越出 cell（got \(f.maxX)）")
        XCTAssertEqual(f.maxX, defaultDateColWidth - 6 + 2, accuracy: 0.5,
                       "trailing-6 约束落位（+2 = NSTextField label 布局边距，探针实测）")
    }

    /// 常量漂移守卫（评审 minor：70/40/150 与 PaneTableView 只靠注释联动）。
    /// 真建一个 PaneTableView 读回列宽，与本类钉死值对账。
    /// 变异：改 PaneTableView 列宽常量不改本类 → 红。
    func testColumnWidthConstantsMatchPaneTableView() {
        let src = LocalFileSource()
        let start = TCPath(url: FileManager.default.temporaryDirectory)
        let left = FilePane(id: .left, source: src, startPath: start)
        let right = FilePane(id: .right, source: src, startPath: start)
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        let view = PaneTableView(pane: left, workspace: ws, router: router, id: .left)
        let cols = Dictionary(uniqueKeysWithValues: view.tableView.tableColumns.map { ($0.identifier.rawValue, $0) })
        XCTAssertEqual(cols["size"]?.width ?? -1, defaultSizeColWidth, "缺省大小列宽漂移")
        XCTAssertEqual(cols["size"]?.minWidth ?? -1, minSizeColWidth, "min 大小列宽漂移")
        XCTAssertEqual(cols["date"]?.width ?? -1, defaultDateColWidth, "缺省日期列宽漂移")
    }
}
