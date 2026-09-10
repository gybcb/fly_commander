import XCTest
import AppKit
@testable import FlyCommander
import TCCore

// MARK: - issue #1「上下移动卡顿不顺滑」回归锁
//
// 根因（真窗 spike 实测 2026-09-10，5000 行 + 复刻接线 + 50 次 Down）：本 SDK 无
// registerClass → makeView 恒 nil，上一代 refreshSelection 的可见行
// reloadData(forRowIndexes:) 每次把 ~90 个活 cell 全丢弃重建（4479 init/50 键），
// 实测 223ms/键。修法 = 就地 configure 现存 cell（view(atColumn:row:
// makeIfNecessary:false) 找回）。本类以**对象同一性**证明零重建——不依赖任何
// 生产侧计数钩子。

/// CGColor 比较：回桥 NSColor 再比空间无关分量（两常量色空间可能不同，直接 == 不可靠）。
private func cgColorEqual(_ a: CGColor?, _ expect: NSColor) -> Bool {
    guard let a, let ca = NSColor(cgColor: a) else { return false }
    guard let ea = expect.usingColorSpace(.genericRGB),
          let ba = ca.usingColorSpace(.genericRGB) else { return false }
    let ac = [ba.redComponent, ba.greenComponent, ba.blueComponent, ba.alphaComponent]
    let ec = [ea.redComponent, ea.greenComponent, ea.blueComponent, ea.alphaComponent]
    return zip(ac, ec).allSatisfy { abs($0 - $1) < 1e-4 }
}

/// 真窗夹具：tmp 造 rows 个文件 + 复刻 MainViewController 的 onReload/onSelectionChange
/// 接线（spike 实证：不接线 tableView 保持空行，223ms 病灶不显形）。
private final class NavFixture {
    let dir: URL
    let pane: FilePane
    let pv: PaneTableView
    let window: FlyWindow

    init(rows: Int) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fly-nav-perf-\(getpid())-\(rows)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<rows {
            FileManager.default.createFile(atPath: dir.appendingPathComponent("file_\(i).bin").path,
                                           contents: Data([0x78]), attributes: nil)
        }
        let src = LocalFileSource()
        let start = TCPath(url: dir)
        let left = FilePane(id: .left, source: src, startPath: start)
        let right = FilePane(id: .right, source: src, startPath: start)
        let ws = Workspace(left: left, right: right, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        pane = left
        let v = PaneTableView(pane: left, workspace: ws, router: router, id: .left)
        pv = v
        left.onReload = { [weak v] _ in v?.reload() }                        // 复刻接线
        left.onSelectionChange = { [weak v] _ in v?.refreshSelection() }     // 快路
        left.load()
        let w = FlyWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        w.animationBehavior = .none   // 禁 order 动画（同 teardown 注释：动画 dealloc 悬垂）
        window = w
        w.contentView = v
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        v.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    func cell(_ row: Int, _ col: Int = 0) -> FileCellView? {
        pv.tableView!.view(atColumn: col, row: row, makeIfNecessary: false) as? FileCellView
    }

    func tearDown() {
        // orderOut 而非 close：本缩减 SDK 里 NSWindow.close() 的
        // _NSWindowTransformAnimation dealloc 在后续 fixture 的 RunLoop 自旋中
        // 释放悬垂指针 → SIGSEGV（实测 crash 栈 _NSWindowTransformAnimation dealloc →
        // objc_release）。既有真窗测试（FilterBar/PaneTableView）一律 orderOut，随全量稳。
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class KeyboardNavPerfTests: XCTestCase {
    /// 锁 1（零重建）：方向键快路后，仍可见的格必须是**同一批实例**。
    /// 变异=refreshSelection 回退旧可见行 reloadData 半句 → 格被丢弃重建 → 红。
    func testSelectionFastPathReusesCellInstances() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        guard let before = fx.cell(0) else {
            return XCTFail("前置：row0 名称格应存在（可见区未渲染？）")
        }
        fx.pane.moveFocusBy(delta: 1, mode: .simple)   // 触发 onSelectionChange 快路
        fx.pv.layoutSubtreeIfNeeded()
        XCTAssertTrue(before === fx.cell(0), "快路不得重建仍可见的格（reloadData 回潮 → 红）")
    }

    /// 锁 2（就地态更新）：焦点 0→1 后，旧格（同实例）须落回普通态、新格进高亮态，
    /// 且**只动焦点列无关列也对**（三列全刷）。变异=删就地 configure 调用 →
    /// 旧格残留选中背景/粗体 → 红。
    func testSelectionFastPathUpdatesStatesInPlace() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        guard let old = fx.cell(0), let new = fx.cell(1) else {
            return XCTFail("前置：row0/row1 格应存在")
        }
        XCTAssertTrue(cgColorEqual(old.layer?.backgroundColor, .selectedContentBackgroundColor),
                      "前置：初始焦点在 row0")
        fx.pane.moveFocusBy(delta: 1, mode: .simple)
        fx.pv.layoutSubtreeIfNeeded()
        XCTAssertTrue(cgColorEqual(old.layer?.backgroundColor, .controlBackgroundColor),
                      "旧焦点格须落回普通底色（configure 就地刷被删 → 残留高亮 → 红）")
        XCTAssertTrue(cgColorEqual(new.layer?.backgroundColor, .selectedContentBackgroundColor),
                      "新焦点格须进选中底色")
        XCTAssertEqual(new.nameLabel.font, NSFont.systemFont(ofSize: 12, weight: .medium),
                       "焦点行名称须升 medium 字重（视觉合同）")
        XCTAssertEqual(old.nameLabel.font, NSFont.systemFont(ofSize: 12),
                       "旧焦点格字重须落回 regular")
    }

    /// 锁 3（标记路）：toggleMark 走同一快路，同实例刷进 accent 半透明底色。
    /// 变异=删 configure → 底色不出现 → 红。
    func testMarkFastPathUpdatesInPlace() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        guard let c = fx.cell(1) else { return XCTFail("前置：row1 格应存在") }
        fx.pane.toggleMark(at: 1)
        fx.pv.layoutSubtreeIfNeeded()
        let expect = ThemeStore.shared.accentColor.withAlphaComponent(0.25)
        XCTAssertTrue(cgColorEqual(c.layer?.backgroundColor, expect),
                      "标记行格须同实例刷进 accent 底色")
    }

    /// 锁 4（预算哨兵）：50 次方向键平均成本设 50ms/键上界——实测修复前 223ms、
    /// 修复后 3.3ms，余量 >10 倍防 CI 抖动误报。红面=重建路径回潮。
    func testArrowKeyBudget() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        for _ in 0..<5 { fx.pane.moveFocusBy(delta: 1, mode: .simple) }   // 预热
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<50 {
            fx.pane.moveFocusBy(delta: 1, mode: .simple)
            fx.pv.layoutSubtreeIfNeeded()
        }
        let avgMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 50.0 / 1_000_000.0
        XCTAssertLessThan(avgMs, 50.0, "方向键平均 \(avgMs)ms/键（修复前基线 223ms，修复后实测 3.3ms）")
    }

    /// 锁 5（滚动跟随）：连按越过可见区后，焦点行必须落在 visibleRect 行区间内、
    /// 且其名称格实例可找回（格不存在=没滚到）。评审变异实证：删掉 refreshSelection
    /// 末尾的 scrollRowToVisible 半句 → 四测原全绿（零锁）→ 本锁补上后该变异红
    /// （焦点行滚出屏外，firstIndex 找不到/取不到格）。
    func testFocusRowStaysVisibleDuringScroll() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        for _ in 0..<55 { fx.pane.moveFocusBy(delta: 1, mode: .simple) }
        fx.pv.layoutSubtreeIfNeeded()
        guard let focusID = fx.pane.selection.focusID else { return XCTFail("前置：有焦点") }
        // displayIDs 与 tableView 行号 1:1（displayIDs.count == numberOfRows，见 :189 reload 路）。
        guard let row = fx.pv.displayIDs.firstIndex(of: focusID) else {
            return XCTFail("焦点项应在 display 序列中")
        }
        let visible = fx.pv.tableView.rows(in: fx.pv.tableView.visibleRect)
        XCTAssertTrue(visible.contains(row),
                      "焦点行 \(row) 应随按键滚入可见区 \(visible.location)..<\(visible.location + visible.length)（scrollRowToVisible 被删 → 红）")
        XCTAssertNotNil(fx.cell(row), "焦点行名称格应存在")
    }

    /// 锁 6（保留边距陈旧态，评审 confirmed-1）：NSTableView 有 retention margin——
    /// 探针实测（2000 行真窗，连按 40 次后可视区 11..<41）：**上方 2 行**格实例存活
    /// （row9/row10），滚回**不重问 viewFor**；下方全是新建区不存活。refreshSelection
    /// 的覆盖窗必须含上方边距（±4 行裕量），否则边距行的选择态变化既刷不到、滚回
    /// 来也不重建 = 双向陈旧。场景：把某行滚出可视区（落在上边距存活）→ 标记
    /// 该行 → 同实例须进 accent 底色。变异=覆盖窗退回纯 visibleRect → 存活格无人刷
    /// → 底色停留普通态 → 本锁红。
    func testMarginRowMarkUpdatesInPlace() throws {
        let fx = try NavFixture(rows: 2000)
        defer { fx.tearDown() }
        for _ in 0..<40 { fx.pane.moveFocusBy(delta: 1, mode: .simple) }
        fx.pv.layoutSubtreeIfNeeded()
        let vis = fx.pv.tableView.rows(in: fx.pv.tableView.visibleRect)
        let target = vis.location - 2   // 上边距存活行（探针实测边距≈2 行）
        guard vis.location >= 5, target >= 0, fx.cell(target) != nil else {
            return XCTFail("前置失败：须存在「滚出可视区但在保留边内存活」的行（vis=\(vis.location)..<\(vis.location + vis.length), target=\(target), alive=\(fx.cell(target) != nil)）——边距语义变了须重设计本锁")
        }
        guard let before = fx.cell(target) else { return XCTFail("前置：target 格存在") }
        XCTAssertTrue(cgColorEqual(before.layer?.backgroundColor, .controlBackgroundColor),
                      "前置：target 未标记未聚焦")
        // toggleMark(at:) 收 **selection 索引**，target 是 display 行号——按 id 反查
        // （生产方向键路经 navigate 做同样映射；本夹具默认序下两者重合，不赌巧合）。
        let selIndex = fx.pane.selection.items.firstIndex(of: fx.pv.displayIDs[target]) ?? target
        fx.pane.toggleMark(at: selIndex)
        fx.pv.layoutSubtreeIfNeeded()
        XCTAssertTrue(before === fx.cell(target), "边距行不得触发重建（重建=本锁失去鉴别对象）")
        let expect = ThemeStore.shared.accentColor.withAlphaComponent(0.25)
        XCTAssertTrue(cgColorEqual(before.layer?.backgroundColor, expect),
                      "上边距存活格须被覆盖窗就地刷进标记底色（纯 visibleRect 覆盖窗 → 陈旧 → 红）")
    }
}
