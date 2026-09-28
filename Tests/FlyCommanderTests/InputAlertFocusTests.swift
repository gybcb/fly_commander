import XCTest
import AppKit
@testable import FlyCommander
import TCCore

// MARK: - 二期：文本输入框收口（InputAlert）的焦点自给回归锁
//
// 真机 issue：重命名/新建目录弹框要再点一下文本框才能输入（SDK 对带 accessory 的
// NSAlert 不保证焦点落文本框——DeleteConfirmKeyRoutingProbeTests 探针里
// fieldEditor/panel 两态都出现过）。收口双保险：panel.initialFirstResponder +
// 一次性 local monitor（首个无修饰非 Tab 键先落进文本框）。
//
// 判据走端到端：modal 期内注入「a + ⏎」，收口返回值必须就是 "a"——焦点没交接时
// 字符落不到字段 → 返回 nil（空串无效）→ 红。不断言 firstResponder 落点本身：
// 本环境无 key window（探针文件头部环境事实），落点两态本就合法，字符送达才是合同。
//
// 夹具纪律（探针文件同款）：真窗离屏、animationBehavior=.none、teardown orderOut
// （禁 close → SIGSEGV 记忆坑）、Timer 挂 RunLoop.main(.common)（asyncAfter 在
// runModal 嵌套循环不排空 → 挂死）、看门狗 abortModal 随用例作废。
final class InputAlertFocusTests: XCTestCase {
    private var timers: [Timer] = []
    private var window: FlyWindow!
    private var view: KeyDownModalView!

    override func setUpWithError() throws {
        continueAfterFailure = false
        L10n.current = .en
        _ = NSApplication.shared
        window = FlyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
        view = KeyDownModalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(view))
    }

    override func tearDown() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
        window?.orderOut(nil)
        window = nil; view = nil
        super.tearDown()
    }

    private func arm(_ dt: TimeInterval, _ body: @escaping () -> Void) {
        ModalProbe.after(dt, &timers, body)
    }

    private func inject(_ chars: String, code: UInt16) {
        guard let target = NSApp.modalWindow else { return }
        NSApp.postEvent(ModalProbe.key(code: code, chars: chars, window: target), atStart: true)
    }

    /// 主锁：弹框后直接打字再 ⏎ → 返回值就是打进去的文本（焦点自给端到端合同）。
    func testTypedCharacterConfirmsWithThatText() {
        var result: String?
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.arm(0.3) { self.inject("a", code: 0) }          // kVK_ANSI_A
            self.arm(0.6) { self.inject("\r", code: 36) }
            self.arm(3.0) { NSApp.abortModal() }                  // 看门狗
            result = InputAlert.run(message: "Rename", initial: "", confirmTitle: "OK")
        }
        sendF8()
        ModalProbe.spin(until: { result != nil }, timeout: 6)
        timers.forEach { $0.invalidate() }
        XCTAssertEqual(result, "a", "打字+⏎ 的提交值须是 'a'（焦点未交接 → 空 → nil → 红）")
    }

    /// 空串提交无效：只按 ⏎ → nil（调用方据此不执行 rename/mkdir）。
    func testEmptyConfirmReturnsNil() {
        var result: String? = "sentinel"
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.arm(0.3) { self.inject("\r", code: 36) }
            self.arm(3.0) { NSApp.abortModal() }
            result = InputAlert.run(message: "New Folder", initial: "", confirmTitle: "Create")
        }
        sendF8()
        ModalProbe.spin(until: { result != "sentinel" }, timeout: 6)
        timers.forEach { $0.invalidate() }
        XCTAssertNil(result, "初始空 + ⏎ = 无效提交 → nil")
    }

    /// Esc 取消 → nil 且不提交。
    func testEscapeReturnsNil() {
        var result: String? = "sentinel"
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.arm(0.3) { self.inject("\u{1b}", code: 53) }
            self.arm(3.0) { NSApp.abortModal() }
            result = InputAlert.run(message: "Rename", initial: "keep.txt", confirmTitle: "OK")
        }
        sendF8()
        ModalProbe.spin(until: { result != "sentinel" }, timeout: 6)
        timers.forEach { $0.invalidate() }
        XCTAssertNil(result, "Esc 取消 → nil（即使框里有 initial 文本）")
    }

    /// initial 回填合同：重命名框须预填现名（⏎ 直提=原名回传，非空非 nil）。
    func testInitialTextPrefillsAndConfirms() {
        var result: String?
        view.onF8 = { [weak self] in
            guard let self else { return }
            self.arm(0.3) { self.inject("\r", code: 36) }
            self.arm(3.0) { NSApp.abortModal() }
            result = InputAlert.run(message: "Rename", initial: "keep.txt", confirmTitle: "OK")
        }
        sendF8()
        ModalProbe.spin(until: { result != nil }, timeout: 6)
        timers.forEach { $0.invalidate() }
        XCTAssertEqual(result, "keep.txt", "⏎ 直提须回传回填的 initial")
    }

    private func sendF8() {
        let f8 = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil,
                                  characters: "\u{F708}", charactersIgnoringModifiers: "\u{F708}",
                                  isARepeat: false, keyCode: 100)!
        DispatchQueue.main.async { self.window.sendEvent(f8) }
    }
}
