import XCTest
import AppKit
@testable import FlyCommander
import TCCore

// MARK: - 删除确认框「键到底去了哪」归因探针 + 回归锁（用户 issue：F8 后 ⏎ 无反应 / Esc 时好时坏）
//
// 已排掉、勿回头的：
// - `setDefaultConfirmCancel()` 的静态接线不是病灶（`AlertButtonsTests` 锁的是这件事）。
// - 「面板建窗/排版会改写键等价」= 假：本探针 `AFTER_LAYOUT` 采样与写入值逐位相同。
//
// 本文件证明了的（有牙，见各条注释里的变异记录）：
// 1. `runModal()` **自身**会把第 1 按钮的 `keyEquivalent` 清成 ""，把 Return 改由
//    `window.defaultButtonCell` 承担；取消键的 `"\u{1b}"` 原样保留。——**事实锁**。
//    这解释了用户看到的不对称：Esc 走「按钮键等价匹配」、⏎ 走「key window 的默认按钮」，
//    两条路由条件不同；键事件一旦没落到面板，⏎ 与 Esc 会以不同方式失效。
// 2. 收口的重入守卫：去掉它 → 嵌套 modal 真的会叠起来（MUT-3 实测精确变红）。
//
// 本文件**没有**证明的（诚实标注，别当成功劳）：
// - 收口里 local monitor 的**必要性**。`swift test` 的非 bundle 进程拿不到 key window
//   （见下），也就没有"主窗与面板抢 key"的真实条件；⏎/Esc 那三条投递锁把 monitor 整个
//   换成不接管 ⏎（`case 35:`）照样全绿（MUT-2 实测）。**收口必要性的判据只能来自真机
//   F8 入口**（`UITests/DeleteConfirmF8UITests`，CGEvent 投 kVK_F8）。
//
// 环境事实（本机实证，务必别再踩）：`swift test` 的非 bundle xctest 进程**拿不到 key window**
// —— `NSApp.activate` + `.accessory` 也救不回来，`keyWindow` 恒 nil、面板 `isKeyWindow` 恒 false。
// 所以任何"需要 key window 才成立"的机制在本进程里都不复现，别在这里下"用户症状已复现"的结论。
//
// 夹具约定照抄 PreviewEscCloseSmokeTests：真窗、离屏、animationBehavior = .none、
// teardown orderOut(nil)（**禁 close()**：_NSWindowTransformAnimation 释放悬垂指针 SIGSEGV）。

private final class Rec {
    var log: [String] = []
    var response: NSApplication.ModalResponse?
    func note(_ s: String) { log.append(s) }
    var report: String { log.joined(separator: "\n") }
}

/// 承接「F8 形状」的第一响应者：在 keyDown 里**同步**启动 modal（与 PaneTableView 同形状）。
private final class KeyDownModalView: NSView {
    var onF8: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 100 { onF8?() } else { super.keyDown(with: event) }
    }
}

final class DeleteConfirmKeyRoutingProbeTests: XCTestCase {
    /// 本用例挂出的注入/看门狗定时器。**必须随用例作废**：用例常在 0.3-0.4s 就结束，
    /// 而 3.0s 的看门狗还挂在 RunLoop.main 上——不摘掉就会打到下一个用例的 modal 里，
    /// 表现为"上一条 0.2s 就 -1001 秒挂 + 下一条崩溃"的诡异 flaky（本轮实测踩过）。
    private var timers: [Timer] = []
    private var window: FlyWindow!
    private var view: KeyDownModalView!
    private var rec: Rec!

    override func setUpWithError() throws {
        continueAfterFailure = false
        _ = NSApplication.shared            // 必须先建 NSApp（NSApp 是隐式解包，未建即 nil）
        rec = Rec()
        window = FlyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        view = KeyDownModalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view), "前置：窗格位置须是第一响应者")
        rec.note("ENV mainIsKey=\(window.isKeyWindow) appKeyWindowNil=\(NSApp.keyWindow == nil) "
                 + "isActive=\(NSApplication.shared.isActive)")
    }

    override func tearDownWithError() throws {
        cancelTimers()
        window.orderOut(nil)     // 禁 close()（SIGSEGV 记忆坑）
        window = nil; view = nil; rec = nil
    }

    // MARK: - 与生产同款构造（`.warning` + 删除/取消两按钮 + 挂键等价）

    private func makeProductionShapedAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.trashConfirm, "1")
        alert.addButton(withTitle: L10n.t(.deleteWord))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        alert.setDefaultConfirmCancel()
        return alert
    }

    // MARK: - M2'：runModal 自身改写第 1 按钮键等价（本轮核心待证事实）

    func testRunModalMovesFirstButtonReturnKeyOntoDefaultButtonCell() throws {
        let alert = makeProductionShapedAlert()
        let b0 = alert.buttons[0], b1 = alert.buttons[1]

        let pre0 = b0.keyEquivalent, pre1 = b1.keyEquivalent
        let preMask0 = b0.keyEquivalentModifierMask
        rec.note("PRE b0=\(pre0.debugDescription) mask=\(preMask0.rawValue) b1=\(pre1.debugDescription)")

        // 建面板 + 强制排版：证「排版不改写」这一半（M2 的前半被证伪）
        let panel = alert.window
        panel.layoutIfNeeded()
        let postLayout0 = b0.keyEquivalent
        rec.note("AFTER_LAYOUT b0=\(postLayout0.debugDescription)")

        // modal 期间采样：此时才看得到 runModal 自己做了什么
        var during0 = "", during1 = ""
        var cellTitle: String?
        after(0.3, "DURING") {
            during0 = b0.keyEquivalent
            during1 = b1.keyEquivalent
            cellTitle = panel.defaultButtonCell?.title
            self.rec.note("DURING b0=\(during0.debugDescription) b1=\(during1.debugDescription) "
                          + "defaultButtonCell=\(cellTitle ?? "nil") "
                          + "modalIsPanel=\(NSApp.modalWindow === panel) panelIsKey=\(panel.isKeyWindow) "
                          + "panelFR=\(type(of: panel.firstResponder ?? NSResponder()))")
            NSApp.abortModal()
        }
        after(3.0, "AT_ABORT") { NSApp.abortModal() }   // 看门狗（随 cancelTimers 作废，勿改回 asyncAfter）
        rec.response = alert.runModal()
        cancelTimers()
        print("=== M2' resp=\(rec.response?.rawValue ?? -999)\n\(rec.report)")

        XCTAssertEqual(pre0, "\r", "前置：`setDefaultConfirmCancel()` 给第 1 按钮挂的是 \\r")
        XCTAssertEqual(pre1, "\u{1b}", "前置：取消键挂的是 Esc")
        XCTAssertEqual(postLayout0, "\r", "建面板+排版**不得**改写键等价（M2 前半证伪）")
        XCTAssertEqual(during0, "", "事实：runModal 期间第 1 按钮键等价被清空（Return 移交 defaultButtonCell）")
        XCTAssertEqual(during1, "\u{1b}", "事实：runModal 期间取消键的 Esc 原样保留 —— 这正是 ⏎/Esc 不对称的来源")
        XCTAssertEqual(cellTitle, b0.title, "事实：第 1 按钮改由 window.defaultButtonCell 承担")
    }

    // MARK: - 回归锁：⏎/Esc 在 F8 形状下落到正确的按钮（走生产收口）
    //
    // **这三条不构成"收口必要"的证据，别当成功劳**：本进程里没有 key window 竞争，面板一旦是
    // modalWindow，队列里的 ⏎ 就会被它的默认按钮 cell 吃掉——把收口里的 monitor 整个换成
    // `case 35:`（即完全不接管 ⏎）它们照样全绿（MUT-2 实测）。它们测的是"投递方式"而不是"修复"。
    // 价值在于：它们是走生产收口的端到端行为锁，将来谁改坏了 ⏎/Esc 的落点会被它们抓住。
    // 收口的必要性判据只能来自**真机 F8 入口**（`UITests/DeleteConfirmF8UITests`）——那里才有
    // 主窗与面板抢 key 的真实条件。
    //
    // 投递形态说明：事件带**主窗**的 windowNumber 投进队列（不是面板的）。带面板号的话默认按钮
    // cell 会自己吃掉，锁就退化成恒真（MUT-2 第一轮实测就是这么暴露的）。

    func testReturnConfirmsViaProductionFunnelWithoutKeyWindow() throws {
        let got = try runWithInjectedKey(code: 36, chars: "\r")
        XCTAssertEqual(got, .alertFirstButtonReturn,
                       "⏎ 必须确认第 1 按钮，且不依赖 key window。日志:\n\(rec.report)")
    }

    func testNumpadEnterConfirmsViaProductionFunnelWithoutKeyWindow() throws {
        let got = try runWithInjectedKey(code: 76, chars: "\r")
        XCTAssertEqual(got, .alertFirstButtonReturn,
                       "小键盘 ⌤ 必须与主键盘 ⏎ 等价。日志:\n\(rec.report)")
    }

    func testEscapeCancelsViaProductionFunnelWithoutKeyWindow() throws {
        let got = try runWithInjectedKey(code: 53, chars: "\u{1b}")
        XCTAssertEqual(got, .alertSecondButtonReturn,
                       "Esc 必须落到取消按钮。日志:\n\(rec.report)")
    }

    /// 回归锁：⏎ 必须确认，即使键事件是投给主窗的（走生产收口，headless 可判）。
    ///
    /// 投递形态是关键，别改错：事件必须带**主窗**的 windowNumber（`self.window`），而不是面板的。
    /// **注意**：曾有一版是投给面板自己（`panel.windowNumber`），默认按钮 cell 会自己吃掉 ⏎，
    /// 那条锁被 MUT-2 实测证出是空转（把 monitor 换成不接管 ⏎ 也照样绿）。改用主窗号后至少
    /// 反映的是"事件不是奔着面板去的"这一真实形态。
    /// （另注：早先 CONTROL/EXP 两臂用 `NSApp.sendEvent` 直投得到"主窗号的 ⏎ 恒不生效"，那是
    ///  **直投绕过 modal 会话路由**造成的假象，不是用户症状的复现——别拿它当证据。）
    private func runWithInjectedKey(code: UInt16, chars: String) throws -> NSApplication.ModalResponse {
        let alert = makeProductionShapedAlert()
        let panel = alert.window
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.after(0.3, "AT_KEY") {
                self.rec.note("DURING modalIsPanel=\(NSApp.modalWindow === panel) "
                              + "panelIsKey=\(panel.isKeyWindow) keyWindowNil=\(NSApp.keyWindow == nil) "
                              + "target=MAIN")
                NSApp.postEvent(self.key(code: code, chars: chars, window: self.window), atStart: true)
            }
            self.after(3.0, "AT_ABORT") { NSApp.abortModal() }   // 看门狗
            self.rec.response = alert.runConfirmModal()
        }
        sendF8()
        spin(until: { rec.response != nil }, timeout: 6)
        cancelTimers()
        return try XCTUnwrap(rec.response, "modal 未结束。日志:\n\(rec.report)")
    }

    func testSecondEntryWhileModalIsUpDoesNotStack() throws {
        let alert = makeProductionShapedAlert()
        let panel = alert.window
        var nested: NSApplication.ModalResponse?
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.after(0.3, "AT_NEST") {
                // 模拟重复入口（F8 长按 / 二重触发）：此时已有确认框在跑 → 必须按取消即刻返回，不叠框。
                nested = NSAlert().runConfirmModal()
                self.rec.note("NESTED returned=\(nested?.rawValue ?? -999) "
                              + "stillOuterPanel=\(NSApp.modalWindow === panel)")
                NSApp.postEvent(self.key(code: 53, chars: "\u{1b}", window: panel), atStart: true)
            }
            self.after(3.0, "AT_ABORT") { NSApp.abortModal() }
            self.rec.response = alert.runConfirmModal()
        }
        sendF8()
        spin(until: { rec.response != nil }, timeout: 6)
        cancelTimers()

        XCTAssertEqual(nested, .alertSecondButtonReturn, "重入必须按取消语义即刻返回。日志:\n\(rec.report)")
        XCTAssertEqual(rec.response, .alertSecondButtonReturn, "外层仍由 Esc 正常取消")
    }

    // MARK: - accessory 文本框（重命名 / 新建目录）焦点归属：收口**不得**改变裸 runModal 的行为

    /// 差分对照：同一构造分别走「裸 runModal」与「生产收口」，取样第一响应者。
    /// 只看两者是否**一致**（收口的正当性 = 不改变既有行为），不预设 SDK 该给哪个值。
    private func firstResponderOfAccessoryAlert(useFunnel: Bool) -> (NSResponder?, String) {
        let alert = NSAlert()
        alert.messageText = L10n.t(.renameTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = "abc.txt"
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.okBtn))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        alert.setDefaultConfirmCancel()
        let panel = alert.window

        var fr: NSResponder?
        var kind = "nil"
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.after(0.3, "AT_SAMPLE") {
                fr = panel.firstResponder
                kind = self.frKind(fr, panel: panel, field: field)
                self.rec.note("ACCESSORY funnel=\(useFunnel) fr=\(String(describing: fr)) kind=\(kind)")
                NSApp.abortModal()
            }
            self.after(3.0, "AT_ABORT") { NSApp.abortModal() }
            if useFunnel { self.rec.response = alert.runConfirmModal() }
            else { self.rec.response = alert.runModal() }
        }
        sendF8()
        spin(until: { rec.response != nil }, timeout: 5)
        cancelTimers()
        return (fr, kind)
    }

    /// 第一响应者的"落点"描述：面板自身 / 文本框的 field editor / 某个按钮 / 其它。
    /// 比对象同一性更有意义——两次取样本就是两个不同的 alert 实例。
    private func frKind(_ fr: NSResponder?, panel: NSWindow, field: NSTextField) -> String {
        guard let fr else { return "nil" }
        if fr === panel { return "panel" }
        if fr === field { return "accessoryField" }
        if fr is NSTextView { return "fieldEditor" }       // 文本框取得焦点时通常是 field editor
        if fr is NSButton { return "button" }
        return String(describing: type(of: fr))
    }

    func testFunnelDoesNotChangeAccessoryFocus() throws {
        let (before, beforeKind) = firstResponderOfAccessoryAlert(useFunnel: false)
        rec.response = nil
        let (after, afterKind) = firstResponderOfAccessoryAlert(useFunnel: true)
        print("=== ACCESSORY 裸=\(beforeKind) 收口=\(afterKind)\n\(rec.report)")

        // 收口的正当性是"不改变既有行为"：焦点落点必须与裸 runModal 一致。
        // （若哪天想把焦点主动给文本框，那是**行为变更**，得单独论证并改这条锁，不能顺手做。）
        XCTAssertEqual(beforeKind, afterKind,
                       "收口不得改变 accessory 框的第一响应者落点。日志:\n\(rec.report)")
        _ = (before, after)
    }

    // MARK: - 小工具

    /// 二分用：只跑收口、不注入任何键，靠看门狗收尾。用来把「收口本身阻塞」与「注入路径阻塞」劈开。
    func testBisectFunnelAloneReturns() throws {
        let alert = makeProductionShapedAlert()
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.after(2.0, "ABORT") { NSApp.abortModal() }
            self.rec.response = alert.runConfirmModal()
        }
        sendF8()
        spin(until: { rec.response != nil }, timeout: 5)
        cancelTimers()
        print("=== BISECT funnelAlone returned=\(rec.response?.rawValue ?? -999)\n\(rec.report)")
        XCTAssertNotNil(rec.response, "收口必须能被 abortModal 收尾（否则收口自身阻塞）")
    }

    /// modal 期间注入：必须用 Timer + RunLoop.main(.common)，**不要**用 DispatchQueue.main.asyncAfter
    /// ——后者在 `runModal` 的嵌套事件循环里不保证被排空（本轮实测：整条用例挂死、xctest 0% CPU）。
    private func after(_ dt: TimeInterval, _ tag: String, _ body: @escaping () -> Void) {
        let t = Timer(timeInterval: dt, repeats: false) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func cancelTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func key(code: UInt16, chars: String, window target: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                         timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: target.windowNumber, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    /// 走生产窗层的完整派发链（FlyWindow.sendEvent → NSWindow.sendEvent → FR.keyDown）。
    private func sendF8() {
        let f8 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  characters: "\u{F708}", charactersIgnoringModifiers: "\u{F708}",
                                  isARepeat: false, keyCode: 100)!
        DispatchQueue.main.async { self.window.sendEvent(f8) }
    }

    /// 跑主 run loop 直到条件成立或超时（modal 期间由定时器把键注入进去）。
    private func spin(until done: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
