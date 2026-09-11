import XCTest
import AppKit
import PDFKit
import AVKit
@testable import FlyCommander
import TCCore

// MARK: - 「预览窗按 Esc 直接关闭」回归锁（用户 issue）
//
// 既有机制「响应链 cancelOperation → PreviewViewController.cancelOperation」只在
// firstResponder 位于内容子树时可达；诊断（3 agent workflow + /tmp 探针）实证大量路 FR
// 停在 NSWindow 自身 → 普通窗把 cancelOperation 就地终结，Esc 静默消失：图片/降级页
// （无可当选 key view）、PDF/富文本异步 placeholder 窗口期、swapContent 后 FR 悬空、
// 单例窗第二次预览（AppKit FR 自动当选只在新窗首 key 一次=症状主体）。
// 修法=PreviewWindow: NSWindow 覆写 sendEvent 拦裸 Esc → performClose（FlyWindow 先例）。
// 本类必须经**生产单例窗**（previewWindowForTest）——夹具自建裸窗（PreviewFixture）不经
// 生产窗类、测不到窗层拦截，故另立夹具。

/// 生产单例窗夹具：离屏 makeKeyAndOrderFront（FilterBarWiringTests 真窗 sendEvent 先例）；
/// animationBehavior=.none + tearDown orderOut（SIGSEGV 记忆坑）；禁 window.close()。
private final class EscFixture {
    let dir: URL
    let window: NSWindow
    let vc: PreviewViewController

    init() throws {
        _ = NSApplication.shared
        PreviewWindowController.resetSharedForTest()
        guard let w = PreviewWindowController.previewWindowForTest(),
              let vc = PreviewWindowController.previewVCForTest() else {
            throw NSError(domain: "fixture", code: 1)
        }
        window = w
        self.vc = vc
        window.animationBehavior = .none
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-esc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 建文件并返回 FileItem（不 show；C-2 级联锁要经生产 present 路）。
    func makeItem(_ name: String, write: (URL) throws -> Void) throws -> FileItem {
        let url = dir.appendingPathComponent(name)
        try write(url)
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init) ?? 0
        return FileItem(id: url.path, path: TCPath(url: url), name: name, isDirectory: false,
                        size: size, modificationDate: Date(timeIntervalSince1970: 0),
                        isHidden: false, isReadOnly: false, isExecutable: false)
    }

    /// 建文件 + 交生产 VC show（内容装进生产单例窗的 contentViewController）。
    func showFile(_ name: String, write: (URL) throws -> Void) throws {
        vc.show(item: try makeItem(name, write: write))
    }

    /// 上屏（离屏坐标）——isVisible 断言的前提。
    func presentOnscreen() {
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.makeKeyAndOrderFront(nil)
    }

    func spin(_ seconds: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// 合成 Esc（FilterBarWiringTests keyEvent 同款）；windowNumber 须对窗。
    /// isARepeat=true 模拟「按住不放」的自动 repeat（评审 C-1 合同：主窗格须吞掉）。
    func esc(_ modifiers: NSEvent.ModifierFlags = [], in w: NSWindow? = nil,
             repeat: Bool = false) -> NSEvent {
        let win = w ?? window
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                isARepeat: `repeat`, keyCode: 53)!   // kVK_Escape
    }

    func tearDown() {
        window.orderOut(nil)
        PreviewWindowController.resetSharedForTest()
        try? FileManager.default.removeItem(at: dir)
    }
}

final class PreviewEscCloseSmokeTests: XCTestCase {
    private var fx: EscFixture!

    override func setUpWithError() throws { fx = try EscFixture() }
    override func tearDownWithError() throws { fx.tearDown(); fx = nil }

    /// 最小合法 PDF（与 PreviewRenderingSmokeTests 同款）。
    private static let minimalPDF = """
    %PDF-1.4
    1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
    2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
    3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj
    trailer<</Root 1 0 R/Size 4>>
    %%EOF
    """

    /// 独立本地窗格 + 真 PaneTableView + 一个临时主窗（主窗 Esc 连带关预览用例复用）。
    private func makeMainPaneWindow() throws -> (NSWindow, PaneTableView, FilePane) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("esc-main-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("a.txt"))
        let pane = FilePane(id: .left, source: LocalFileSource(), startPath: TCPath(url: dir))
        pane.load()
        let ws = Workspace(left: pane, right: pane, active: .left)
        let router = CommandRouter(workspace: ws, engine: OperationEngine())
        let paneView = PaneTableView(pane: pane, workspace: ws, router: router, id: .left)
        paneView.reload()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.animationBehavior = .none
        win.contentView = paneView
        paneView.frame = win.contentView!.bounds
        win.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        win.makeKeyAndOrderFront(nil)
        XCTAssertTrue(win.makeFirstResponder(paneView), "前置：窗格须是第一响应者")
        return (win, paneView, pane)
    }

    // MARK: - 断链主路（修法增量：响应链救不动的形态）

    /// 头号新锁：PDF 异步加载 placeholder 窗口期按 Esc——内容树只有非接收首响应的纯色
    /// NSView，FR=NSWindow，响应链必断（探针 fired=0）。夹具=8MB 尾巴 PDF 拖慢后台读；
    /// **不许在 Esc 前加 spin 等 swap**（等完=PDFView 路能关=假绿，故时机本身是证伪点）。
    /// 变异=删 PreviewWindow.sendEvent 拦截 → 本条红（placeholder 路除窗层拦截外必断）。
    func testEscapeClosesWhilePlaceholderStillShowing() throws {
        try fx.showFile("slow.pdf") { url in
            var data = Self.minimalPDF.data(using: .ascii)!
            data.append(Data(repeating: 0x20, count: 8 * 1024 * 1024))
            try data.write(to: url)
        }
        fx.presentOnscreen()
        XCTAssertTrue(fx.window.isVisible, "前置：预览窗已上屏")
        fx.window.sendEvent(fx.esc())   // 不 spin：内容仍是 placeholder
        XCTAssertFalse(fx.window.isVisible, "placeholder 窗口期 Esc 必须关窗（窗层拦截被删即此红）")
    }

    /// 图片路：NSImageView 不接第一响应 → FR=window（探针 fired=0）→ 靠窗层拦截。
    /// 变异=删拦截 → 红（图片路响应链必断）。
    func testEscapeClosesImagePreview() throws {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try fx.showFile("pixel.png") { try png.write(to: $0) }
        fx.presentOnscreen()
        XCTAssertTrue(fx.window.isVisible, "前置：预览窗已上屏")
        fx.window.sendEvent(fx.esc())
        XCTAssertFalse(fx.window.isVisible, "图片预览 Esc 必须关窗")
    }

    /// 症状主体：单例窗**第二次预览**后 Esc 仍须关窗（FR 自动当选只在首 key 一次；
    /// 第二次起 FR 停窗口，响应链全灭——「修焦点」类修法救不动）。
    /// 变异=删拦截：第一次若侥幸经响应链关绿，第二次必红。
    func testSecondPreviewStillClosesByEscape() throws {
        try fx.showFile("one.txt") { try "one".write(to: $0, atomically: true, encoding: .utf8) }
        fx.presentOnscreen()
        fx.window.sendEvent(fx.esc())
        XCTAssertFalse(fx.window.isVisible, "第一次预览：Esc 关窗")
        try fx.showFile("two.txt") { try "two".write(to: $0, atomically: true, encoding: .utf8) }
        fx.presentOnscreen()
        XCTAssertTrue(fx.window.isVisible, "前置：第二次预览已重新上屏")
        fx.window.sendEvent(fx.esc())
        XCTAssertFalse(fx.window.isVisible, "第二次预览（FR 不再自动当选）Esc 仍必须关窗")
    }

    // MARK: - 修饰键防误伤 + Esc→关窗→停播复合合同

    /// ⌘/⌃/⌥/⇧-Esc **四个修饰逐个**不关（评审 C-4：只锁 ⌘ 则漏判任一修饰的变异存活——
    /// 实测删 .shift 判定 6/6 全绿）；随后裸 Esc 关窗**且**媒体停播（performClose→
    /// willCloseNotification→pauseForWindowClose 全链）。
    /// 变异=拦截漏判任一修饰 → 对应修饰断言红；拦截若绕开 performClose（orderOut/close）
    /// → willClose 不来 → 停播断言红；删 pauseForWindowClose → 停播断言红。
    func testModifiedEscapesNeverCloseAndBareEscapePausesMedia() throws {
        try fx.showFile("clip.mp4") { try Data(repeating: 0, count: 64).write(to: $0) }
        fx.presentOnscreen()
        fx.spin(0.3)
        let player = try XCTUnwrap(fx.vc.currentPlayerForTest, "media 路 player 必须在场")
        player.play()
        XCTAssertGreaterThan(player.rate, 0, "前置：play 后 rate>0")
        for m: NSEvent.ModifierFlags in [.command, .control, .option, .shift] {
            fx.window.sendEvent(fx.esc(m))
            XCTAssertTrue(fx.window.isVisible, "\(m) Esc 不得关窗（四个修饰逐个锁死）")
        }
        fx.window.sendEvent(fx.esc())
        XCTAssertFalse(fx.window.isVisible, "裸 Esc 必须关窗")
        XCTAssertEqual(player.rate, 0, "关窗后必须停播（performClose→willClose→pause 合同）")
    }

    // MARK: - 主窗 Esc 连带关预览（用户拍板）

    /// 焦点在主窗文件列表、预览开着 → Esc 先关预览**且不清标记**（消费该键）；
    /// 预览关掉后下一次 Esc 恢复原 clearMarks 语义。
    /// 变异=删 keyDown 的 bare/closeIfVisible 早退 → 第一次 Esc 后预览仍 visible 红；
    ///      closeIfVisible 恒返 true（吞掉 clearMarks）→ 第三次「恢复清标记」断言红。
    func testMainPaneEscapeClosesPreviewThenRestoresClearMarks() throws {
        try fx.showFile("view.txt") { try "v".write(to: $0, atomically: true, encoding: .utf8) }
        fx.presentOnscreen()

        let (win, _, pane) = try makeMainPaneWindow()
        defer { win.orderOut(nil); try? FileManager.default.removeItem(at: pane.path.url) }
        pane.toggleMark(at: 0)
        XCTAssertFalse(pane.selection.marked.isEmpty, "前置：已标记 1 项")

        win.sendEvent(fx.esc(in: win))   // 预览开着 → 关预览，不清标记
        XCTAssertFalse(fx.window.isVisible, "主窗 Esc 必须连带关预览（closeIfVisible 被删即此红）")
        XCTAssertFalse(pane.selection.marked.isEmpty, "关预览那次 Esc 不得清标记（消费语义）")

        win.sendEvent(fx.esc(in: win))   // 预览已关 → 恢复原 .clearMarks 语义
        XCTAssertTrue(pane.selection.marked.isEmpty,
                      "无预览后 Esc 恢复原语义=清标记（closeIfVisible 恒 true 化即此红）")
    }

    /// 预览从未创建时主窗 Esc=原 clearMarks 零回归（TC 清标记不变），且绝不平空建出预览窗。
    /// 变异=closeIfVisible 去掉 isVisible/存在性守卫或恒返 true → 本条红（清标记被吞或凭空建窗）。
    func testMainPaneEscapeClearsMarksWhenNoPreview() throws {
        PreviewWindowController.resetSharedForTest()   // 前置：单例不存在
        let (win, _, pane) = try makeMainPaneWindow()
        defer {
            win.orderOut(nil)
            try? FileManager.default.removeItem(at: pane.path.url)
            PreviewWindowController.resetSharedForTest()
        }
        pane.toggleMark(at: 0)
        XCTAssertFalse(pane.selection.marked.isEmpty, "前置：已标记")
        XCTAssertFalse(PreviewWindowController.hasCreatedWindowForTest, "前置：预览单例未创建")
        win.sendEvent(fx.esc(in: win))
        XCTAssertTrue(pane.selection.marked.isEmpty, "无预览时 Esc 必须走原清标记语义（零回归）")
        XCTAssertFalse(PreviewWindowController.hasCreatedWindowForTest,
                       "无预览场景不得凭空建出预览窗")
    }

    // MARK: - 评审轮补锁（wf_52002fb5-560 C-1/C-3/C-5/C-2）

    /// C-1 主修（major）：按住 Esc 的自动 repeat 不得漏回 .clearMarks——首次按下关掉预览
    /// 后，performClose 同步把 key window 转交主窗，同一次按住产生的 repeat keyDown
    /// （~30/秒）会落进刚成为 key 的主窗格；若被当普通 Esc 处理=刚标记的全部被静默清空，
    /// 正是「关预览那次消费该键」承诺的反面。合同=窗层与主窗格一致：repeat 吞掉。
    /// 变异=删 keyDown 的 isARepeat 守卫 → 第二次 sendEvent 后 marked 空红；
    ///      守卫改成「repeat 直接 return 前连 type-ahead 都清不了」不在本锁面。
    func testHeldEscapeRepeatDoesNotLeakIntoClearMarks() throws {
        try fx.showFile("view.txt") { try "v".write(to: $0, atomically: true, encoding: .utf8) }
        fx.presentOnscreen()
        let (win, _, pane) = try makeMainPaneWindow()
        defer { win.orderOut(nil); try? FileManager.default.removeItem(at: pane.path.url) }
        pane.toggleMark(at: 0)
        // 首次按下：关预览、不清标记。
        win.sendEvent(fx.esc(in: win))
        XCTAssertFalse(fx.window.isVisible, "前置：首次 Esc 已关预览")
        // 同一次按住的 repeat 键（真实事件流里它会被投递给新 key window=主窗）：
        win.sendEvent(fx.esc(in: win, repeat: true))
        XCTAssertFalse(pane.selection.marked.isEmpty,
                       "repeat Esc 不得漏回 clearMarks（C-1：删 isARepeat 守卫即此红）")
    }

    /// C-3（minor）：主窗侧带修饰 Esc **不得**抢关预览（与预览窗内「带修饰一律吞」同合同），
    /// 但维持既有 .clearMarks 历史语义（本改动不裁掉旧行为）。
    /// 变异=删 keyDown 的 bare 修饰守卫 → 第一条断言红（⌥Esc 把预览关了）。
    func testMainPaneModifiedEscapeKeepsClearMarksSemantics() throws {
        try fx.showFile("view.txt") { try "v".write(to: $0, atomically: true, encoding: .utf8) }
        fx.presentOnscreen()
        let (win, _, pane) = try makeMainPaneWindow()
        defer { win.orderOut(nil); try? FileManager.default.removeItem(at: pane.path.url) }
        pane.toggleMark(at: 0)
        win.sendEvent(fx.esc([.option], in: win))
        XCTAssertTrue(fx.window.isVisible, "⌥Esc 在文件列表不得抢关预览（修饰合同两侧一致）")
        XCTAssertTrue(pane.selection.marked.isEmpty,
                      "⌥Esc 维持既有 .clearMarks 语义（KeyDispatcher case 53 不判修饰=历史行为）")
    }

    /// C-5（minor）：closeIfVisible 路（主窗 Esc→performClose）的媒体停播合同——姊妹锁
    /// testModifiedEscapes… 只经窗层 sendEvent 内 performClose，closeIfVisible 自己那半段
    /// 被「顺手改成 orderOut 只隐藏」重构击穿时全测试曾全绿（评审实测变异存活）。
    /// 变异=closeIfVisible 的 performClose→orderOut → rate 断言红（隐藏但音频永播）。
    func testMainPaneEscapeClosesPreviewStopsMedia() throws {
        try fx.showFile("clip.mp4") { try Data(repeating: 0, count: 64).write(to: $0) }
        fx.presentOnscreen()
        fx.spin(0.3)
        let player = try XCTUnwrap(fx.vc.currentPlayerForTest, "前置：media player 在场")
        player.play()
        XCTAssertGreaterThan(player.rate, 0, "前置：play 后 rate>0")
        let (win, _, pane) = try makeMainPaneWindow()
        defer { win.orderOut(nil); try? FileManager.default.removeItem(at: pane.path.url) }
        _ = pane
        win.sendEvent(fx.esc(in: win))   // 主窗路 closeIfVisible → performClose
        XCTAssertFalse(fx.window.isVisible, "前置：主窗 Esc 已关预览")
        XCTAssertEqual(player.rate, 0, "closeIfVisible 路必须同样停播（performClose→willClose→pause）")
    }

    /// C-2（minor）：重开级联有界——连续「生产 present→Esc 关」循环，旧「无条件 +48」
    /// 约 8~24 轮后 origin 被 constrainFrameRect 夹到贴边**逐字钉死**（探针实证合法贴角位
    /// 不拉回），此后永不归位；Esc 关窗可达后该循环从罕见变键盘主路径。鉴别签名=**连续
    /// 两轮重开 origin 相等（夹死态）**——有界版每轮要么 +48 要么回 center，origin 恒变；
    /// （教训：无界版贴边后 origin 也"变小/不变"，别拿"是否回中"当判据——本锁首版
    /// 用 sawRecenter 就是这么被 MUT-G 假绿的，夹死态才是变异面。）
    /// 变异=present 恢复无条件 +48（删越界回中块）→ 循环后期出现钉死对 → 本条红。
    func testReopenCascadeIsBounded() throws {
        let item = try fx.makeItem("c.txt") { try "c".write(to: $0, atomically: true, encoding: .utf8) }
        let w = fx.window
        var lastOrigin: NSPoint?
        var pinnedPair = false
        let vf = (w.screen ?? NSScreen.main)!.visibleFrame
        for i in 0..<40 {
            PreviewWindowController.show(item: item)
            XCTAssertTrue(vf.intersects(w.frame), "第 \(i) 轮重开窗体越出可见区（C-2）")
            if let prev = lastOrigin, w.frame.origin == prev { pinnedPair = true }
            lastOrigin = w.frame.origin
            w.sendEvent(fx.esc())   // 关（performClose→isVisible=false→下轮走重开分支）
        }
        XCTAssertFalse(pinnedPair,
                       "重开 origin 出现逐轮不变的夹死态=级联无界（C-2：无条件 +48 变异即此红）")
    }
}
