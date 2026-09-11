import XCTest
import AppKit
@testable import FlyCommander
import TCCore

// MARK: - 激活 tab 三态视觉回归锁（用户「激活的 tab 要不一样」）
//
// 旧版激活/非激活全部差异=recessed state=.on 的极浅系统底（肉眼难辨），且
// rebuild(isActiveSide:) 是死参数——另一侧 pane 的活动 tab 也画亮态。
// 新三态（TabBarView.tabVisual 纯函数出参，底色+字重+文字色三通道）：
//   当前侧活动=accent 实底+medium+白字；另一侧活动=accent 25%+medium；非活动=无底+regular。
// rebuild 里 state 恒 .off（recessed 自绘底与 layer 底色打架）。
//
// 为什么主锁走纯函数：attributedTitle 读回无法区分「被刷过 vs 未设」（AppKit 由 title
// 派生 length==4 的非空串，探针实测）——属性锁不住画法的 issue #2 同族坑；tabVisual
// 纯函数（truncate/toolbarLabels 先例）让三态判定逐属性可变异。
//
// 变异证伪（红面映射）：
// ① tabVisual 软底三元忽略 isActiveSide → 锁A+offside 接线红；
// ② foreground 三元任一支改恒值（.white 恒/labelColor 恒）→ 锁A/锁B/offside 前景实例红
//    （评审实测：恒 .white 曾全绿逃逸 → 补 soft.foreground 锁闭合）；
// ③ medium 换回 regular → 锁A 字重红；
// ④ 非活动分支给上 accent 底 → 非活动否定锁红；
// ⑤ 删 rebuild 的 layer.backgroundColor 写入 → 锁B 红；
// ⑥ state 恢复三元 → 锁B state==.off 红；
// ⑦ rebuild 硬编码 isActiveSide: true（死参数回潮，接线层）→ offside 接线红（锁A 看不见）；
// ⑧ tabVisual 缓存旧 accent → 主题跟色两锁红；
// ⑨ 删 didChange 回调的 applyActiveState() → 主界面跟色锁红（评审 C-1 本体）。
//
// 前景色为何走实例 === ：本 SDK 下 recessed 按钮对**目录语义色**做 cell 级重映射——
// selectedControlTextColor=labelColor 别名（解析黑 0.847），controlTextColor 家族被吞，
// 唯字面色可绘（红/字面白像素探针背书）→ 生产用字面 .white。字面白与 labelColor 黑虽
// 可分量区分，但 attributedTitle 读回保留原实例（探针 === true），实例锁更严。
private func cgColorEqual(_ a: CGColor?, _ expect: NSColor) -> Bool {
    guard let a, let ca = NSColor(cgColor: a) else { return false }
    guard let ea = expect.usingColorSpace(.genericRGB),
          let ba = ca.usingColorSpace(.genericRGB) else { return false }
    let ac = [ba.redComponent, ba.greenComponent, ba.blueComponent, ba.alphaComponent]
    let ec = [ea.redComponent, ea.greenComponent, ea.blueComponent, ea.alphaComponent]
    return zip(ac, ec).allSatisfy { abs($0 - $1) < 1e-4 }
}

final class TabActiveVisualTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        // 显式蓝 accent（≠未来可能漂移的 default 观感），tearDown 复原共享单例
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 0, green: 0.478, blue: 1.0),
                                       fileColorRules: []))
    }
    override func tearDown() {
        ThemeStore.shared.update(Theme.default)
        super.tearDown()
    }

    // MARK: - 锁A：纯函数三态判定

    func testTabVisualThreeStates() {
        let accent = ThemeStore.shared.accentColor
        let solid = TabBarView.tabVisual(isActiveTab: true, isActiveSide: true)
        XCTAssertTrue(cgColorEqual(solid.background?.cgColor, accent), "当前侧活动=accent 实底")
        XCTAssertEqual(solid.font, NSFont.systemFont(ofSize: 11, weight: .medium), "活动=medium")
        XCTAssertTrue(solid.foreground === NSColor.white, "当前侧活动=白字（实例身份）")

        let soft = TabBarView.tabVisual(isActiveTab: true, isActiveSide: false)
        XCTAssertTrue(cgColorEqual(soft.background?.cgColor, accent.withAlphaComponent(0.25)),
                      "另一侧活动=accent 25% 软底")
        XCTAssertEqual(soft.font, NSFont.systemFont(ofSize: 11, weight: .medium))
        // soft 前景须 labelColor 实例：变异恒 .white（评审 wf_855e5db8 实测全绿逃逸）
        // → 本断言红。软底上白字近不可读且不跟暗色模式（生产注释同款论证）。
        XCTAssertTrue(soft.foreground === NSColor.labelColor, "另一侧活动=系统标签色")

        let plain = TabBarView.tabVisual(isActiveTab: false, isActiveSide: true)
        XCTAssertNil(plain.background, "非活动不覆盖系统底")
        XCTAssertNil(plain.foreground, "非活动跟随系统 labelColor")
        XCTAssertEqual(plain.font, NSFont.systemFont(ofSize: 11), "非活动=regular")
    }

    /// 主题改色后 tabVisual 现取 accent（不缓存旧色）。
    func testTabVisualFollowsThemeChange() {
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let v = TabBarView.tabVisual(isActiveTab: true, isActiveSide: true)
        XCTAssertTrue(cgColorEqual(v.background?.cgColor, ThemeStore.shared.accentColor))
        guard let c = v.background?.usingColorSpace(.genericRGB) else { return XCTFail("色不可解析") }
        XCTAssertGreaterThan(c.redComponent, c.blueComponent, "新 accent=红，蓝残留即红")
    }

    // MARK: - 锁B：rebuild 接线（消费 tabVisual 的落点）

    /// 当前侧活动 tab 的按钮：layer 实底=accent、attributedTitle medium+白字、state 恒 off。
    func testRebuildAppliesVisualToActiveButton() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: TabBarView.barHeight))
        bar.rebuild(titles: ["alpha", "beta"], activeIndex: 0, isActiveSide: true)
        let btns = bar.titleButtonsForTest()
        XCTAssertEqual(btns.count, 2)
        let act = btns[0]
        XCTAssertTrue(cgColorEqual(act.layer?.backgroundColor, ThemeStore.shared.accentColor),
                      "rebuild 须把 tabVisual 底色写进按钮 layer")
        let font = act.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font, NSFont.systemFont(ofSize: 11, weight: .medium))
        let fg = act.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(fg === NSColor.white,
                      "前景须是字面白实例（语义白在本 SDK 不可绘，见头部注释）")
        XCTAssertEqual(act.state, .off, "state 恒 .off（recessed 自绘底让位 layer 底色）")
    }

    /// 非活动按钮：无 accent 底（否定式，变异=给非活动也刷色即红）；plain 标题不验
    /// attributedTitle 读回（未设时 AppKit 由 title 派生非空串，读回无鉴别力，见头部注释）。
    func testRebuildLeavesNonActiveButtonPlain() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: TabBarView.barHeight))
        bar.rebuild(titles: ["alpha", "beta"], activeIndex: 0, isActiveSide: true)
        let plain = bar.titleButtonsForTest()[1]
        XCTAssertFalse(cgColorEqual(plain.layer?.backgroundColor, ThemeStore.shared.accentColor),
                       "非活动按钮不得吃 accent")
        XCTAssertFalse(cgColorEqual(plain.layer?.backgroundColor,
                                    ThemeStore.shared.accentColor.withAlphaComponent(0.25)),
                       "非活动按钮不得吃 accent 25%")
        XCTAssertEqual(plain.font, NSFont.systemFont(ofSize: 11))
        XCTAssertEqual(plain.state, .off)
    }

    /// 另一侧（isActiveSide:false）rebuild 接线：活动按钮须吃 25% 软底而非实底。
    /// 变异（评审 wf_855e5db8 实测逃逸）：rebuild 里硬编码 isActiveSide: true（死参数回潮）
    /// → 本用例红（实底 accent ≠ 25% 软底）。锁A 不经 rebuild，看不见此接线层变异。
    func testRebuildAppliesSoftTintOnInactiveSide() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: TabBarView.barHeight))
        bar.rebuild(titles: ["alpha", "beta"], activeIndex: 0, isActiveSide: false)
        let act = bar.titleButtonsForTest()[0]
        XCTAssertTrue(cgColorEqual(act.layer?.backgroundColor,
                                   ThemeStore.shared.accentColor.withAlphaComponent(0.25)),
                      "另一侧活动按钮=accent 25%（硬编码 true 变异=实底即红）")
        let fg = act.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertTrue(fg === NSColor.labelColor, "软底上前景=labelColor 实例（恒 .white 变异红）")
    }

    /// 主题改色后 rebuild 接线跟色：接线锁的 staleness 面（纯函数锁只读 store 现值，
    /// 遮住了「已画按钮不重画」的接线缺口——评审 wf_855e5db8 两 lens 独立 confirmed）。
    /// 本环境无 MainViewController 级真窗，直接证「rebuild 现取 store 新 accent」：
    /// 建蓝色 bar 后切红主题再 rebuild，按钮底色须变红。
    /// 变异：tabVisual 缓存旧 accent（static let 快照）→ 本用例红。
    func testRebuildFollowsThemeColorChange() {
        let bar = TabBarView(frame: NSRect(x: 0, y: 0, width: 400, height: TabBarView.barHeight))
        bar.rebuild(titles: ["alpha"], activeIndex: 0, isActiveSide: true)
        let act = bar.titleButtonsForTest()[0]
        XCTAssertTrue(cgColorEqual(act.layer?.backgroundColor, ThemeStore.shared.accentColor),
                      "前置：蓝 accent 已画上")
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        bar.rebuild(titles: ["alpha"], activeIndex: 0, isActiveSide: true)
        let act2 = bar.titleButtonsForTest()[0]
        XCTAssertTrue(cgColorEqual(act2.layer?.backgroundColor, ThemeStore.shared.accentColor),
                      "rebuild 须现取新 accent（红）")
        guard let bg = act2.layer?.backgroundColor,
              let c = NSColor(cgColor: bg)?.usingColorSpace(.genericRGB) else {
            return XCTFail("色不可解析")
        }
        XCTAssertGreaterThan(c.redComponent, c.blueComponent, "新 accent=红，蓝残留即红")
    }

    /// didChange→applyActiveState 接线（MainViewController，major 缺陷 C-1 的回归锁）：
    /// 改主题后不导航不切侧，仅触发 ThemeStore.update，两侧标签条须已重画为新 accent。
    /// 变异（评审实测缺陷本体）：删 didChange 回调尾部的 applyActiveState() 调用 →
    /// 按钮留旧色 → 本用例红。夹具=MainViewController+隔离 SessionStore（wiring 先例）。
    func testThemeChangeRedrawsTabBarsWithoutNavigation() throws {
        let suiteName = "fly.test.tabtheme.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dir.path,
                                            rightPath: dir.path, active: "left"))
        let vc = MainViewController(sessionStore: store)
        _ = vc.view   // loadView：didChange 回调在此接线
        vc.leftContainer.show(tabGroup: vc.workspace.leftTabs, isActiveSide: true)
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 0, green: 0.478, blue: 1.0),
                                       fileColorRules: []))
        guard let btn = vc.leftContainer.tabBar.titleButtonsForTest().first,
              btn.layer?.backgroundColor != nil else {
            return XCTFail("前置：活动 tab 须已画 accent 底")
        }
        XCTAssertTrue(cgColorEqual(btn.layer?.backgroundColor, ThemeStore.shared.accentColor))
        // 改主题（无任何导航/切侧），didChange 处理器须自行重画
        ThemeStore.shared.update(Theme(appearance: .system,
                                       accent: ThemeColor(red: 1, green: 0, blue: 0),
                                       fileColorRules: []))
        let btn2 = vc.leftContainer.tabBar.titleButtonsForTest().first
        guard let bg = btn2?.layer?.backgroundColor,
              let c = NSColor(cgColor: bg)?.usingColorSpace(.genericRGB) else {
            return XCTFail("改主题后按钮无底色（未重画？）")
        }
        XCTAssertGreaterThan(c.redComponent, c.blueComponent,
                             "didChange 后活动 tab 须已跟新 accent（红），蓝残留=未重画")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fc-tabtheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.appendingPathComponent("f.txt").path,
                                       contents: Data())
        return url
    }
}
