import XCTest
import AppKit
@testable import FlyCommander

// MARK: - 「连接对话框底部 Connect/Cancel 按钮被裁」回归锁（统一窗，历史为用户实测 issue）
//
// 根因：窗口内容 stack 只钉 top/leading/trailing，**无 bottom 约束** → 窗口高恒等于
// contentRect 初值，内容需求高 > 可用高时按钮行溢出窗口底缘被裁（修前差分实测按钮
// 底缘 -5pt，与用户「遮掉一部分」症状精确对应）。
// 修法=stack.bottom 钉 container.bottom（SearchViewController 先例），窗口经
// contentViewController 建窗时按内容 autogrow。
//
// 历史：本锁原为 SFTP/SMB 两窗各一对（4 条）。统一为一窗一 VC 后，两协议走同一份
// loadView 与同一个 ConnectionWindowController → 折叠为两条（按钮不裁 / present 台阶），
// 差异只在测试体内先 setProto 到哪个协议——SMB 行多、SFTP 密钥行多，几何上仍各自受检。
//
// 变异证伪（红面映射）：删 RemoteConnectionViewController.loadView 的 stack.bottomAnchor
// 那行 → 两协议断言同时红（窗高退回固定初值、按钮行溢出）。
final class ConnectionDialogButtonClipTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        L10n.current = .en
    }
    override func tearDown() { L10n.current = .en; super.tearDown() }

    private func button(in root: NSView, identifier: String) -> NSButton? {
        if let b = root as? NSButton, b.accessibilityIdentifier() == identifier { return b }
        for s in root.subviews { if let b = button(in: s, identifier: identifier) { return b } }
        return nil
    }

    private func assertConnectButtonInsideContent(_ wc: ConnectionWindowController,
                                                  _ message: String,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) {
        _ = wc.window?.contentViewController?.view   // 强制 loadView
        wc.window?.animationBehavior = .none         // SIGSEGV 记忆坑：多窗前后动画
        wc.window?.layoutIfNeeded()
        guard let window = wc.window, let content = window.contentView else {
            XCTFail("无窗口/内容视图", file: file, line: line); return
        }
        guard let connect = button(in: content, identifier: "connectButton") else {
            XCTFail("找不到 connectButton（AX 标识缺失）", file: file, line: line); return
        }
        // 按钮整帧换算到 window 坐标（convert(_:to: nil)=window 坐标），须完整落在内容区内。
        // 被裁形态=底缘越过内容区底缘（minY 更小，非翻转坐标下的数值巧合）。
        let inWindow = connect.convert(connect.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minY, content.frame.minY,
                                    "\(message)：win=\(inWindow) content=\(content.frame)", file: file, line: line)
        XCTAssertLessThanOrEqual(inWindow.maxY, content.frame.maxY,
                                 "按钮顶缘不得超出内容区：win=\(inWindow) content=\(content.frame)", file: file, line: line)
        wc.window?.orderOut(nil)   // tearDown 禁 close()（SIGSEGV 记忆坑）
    }

    // SMB 分支：行最多的协议（服务器/共享/域 + 保存列表区）。
    func testSMBProtoConnectButtonNotClipped() {
        let wc = ConnectionWindowController()
        _ = wc.window?.contentViewController?.view
        (wc.window?.contentViewController as? RemoteConnectionViewController)?.setProto(.smb)
        assertConnectButtonInsideContent(wc, "SMB 协议下 Connect 按钮底缘须完整落在窗口内容区内（被裁=越过底缘）")
    }

    // SFTP 分支：含密钥行/口令行 + 保存列表区（内容 > 初高）。
    func testSFTPProtoConnectButtonNotClipped() {
        let wc = ConnectionWindowController()
        assertConnectButtonInsideContent(wc, "SFTP 协议下 Connect 按钮底缘须完整落在窗口内容区内（被裁=越过底缘）")
    }

    // MARK: - 首次 present 与再次 present 落位一致（评审 wf_12a5bbb0-534 confirmed 的台阶锁）

    // 评审实证：bottom 钉使窗高在**首排版**时才 autogrow（顶缘不动向下长）；
    // present() 的 center() 若跑在排版前 → 首次按旧高居中、显示时向下长 →
    // 首次落位比之后每次低 ~6pt（静止终态差非动画瞬态）。修=center 前 layoutIfNeeded。
    // 变异证伪（红面映射）：删 ConnectionWindowController.present 的 window?.layoutIfNeeded()
    // → 本条测试体内 init→present 同 runloop 无空转（与评审探针同型），首帧 center 踩
    // 旧高、showWindow 才生长 → |first.y − second.y| > 1 红；余断言不受影响。
    private func assertFirstPresentMatchesSecond(_ message: String,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        let wc = ConnectionWindowController()
        wc.window?.animationBehavior = .none
        wc.present()
        let first = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        wc.present()   // 第二次：窗已 autogrow 完成，center 必踩真实高
        let second = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        XCTAssertLessThan(abs(first.y - second.y), 1,
                          "\(message)（autogrow 时序台阶）：first=\(first) second=\(second)", file: file, line: line)
        XCTAssertLessThan(abs(first.x - second.x), 1, "x 向同理：first=\(first) second=\(second)", file: file, line: line)
    }

    func testFirstPresentPositionMatchesSecond() {
        assertFirstPresentMatchesSecond("首次 present 不得比再次打开低/高")
    }

    // SFTP 窗同款台阶锁（评审探针差分实证 deltaY=23 后修法=中心同上）：
    // 统一窗默认协议即 sftp → 本条即默认路；上一条经 setProto 的 SMB 路已由
    // assertConnectButtonInsideContent 覆盖几何，台阶与协议无关（同一 loadView）。
    func testSFTPFirstPresentPositionMatchesSecond() {
        assertFirstPresentMatchesSecond("SFTP 首次 present 不得比再次打开低/高")
    }
}
