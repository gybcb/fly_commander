import XCTest
import AppKit
@testable import FlyCommander

// MARK: - 「SMB 连接对话框底部 Connect/Cancel 按钮被裁」回归锁（用户实测 issue）
//
// 根因：窗口内容 stack 只钉 top/leading/trailing，**无 bottom 约束** → 窗口高恒等于
// contentRect 初值（280），SMB 8 恒可见行需求高 > 可用高时按钮行溢出窗口底缘被裁
// （修前差分实测按钮底缘 -5pt，与用户「遮掉一部分」症状精确对应）。
// 修法=stack.bottom 钉 container.bottom（SearchViewController 先例），窗口经
// contentViewController 建窗时按内容 autogrow（实测修后 content 高 285 > 260）。
//
// 为什么只有 SPM 几何锁、无 UITest isHittable：本 bug 溢出量 ~5pt，按钮中心仍在
// 窗内，XCUITest 命中测试（中心点）下 isHittable 恒真=无牙假锁；几何断言精确到
// 帧底缘才有鉴别力（修前红 -5pt / 修后绿实证）。SFTP 窗实测密钥态内容 277 < 300
// 不裁（隐藏行塌缩后恒低于固定高）——差分证伪后不修不锁，防无牙测试。
//
// 变异证伪（红面映射）：删 SMBConnectionViewController.loadView 的 stack.bottomAnchor
// 那行 → 窗高退回固定 280、按钮行溢出 → 第一断言红（修前差分即此形态）。
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

    func testSMBDialogConnectButtonNotClipped() {
        let wc = SMBConnectionWindowController()
        _ = wc.window?.contentViewController?.view   // 强制 loadView
        wc.window?.animationBehavior = .none         // SIGSEGV 记忆坑：多窗前后动画
        wc.window?.layoutIfNeeded()
        guard let window = wc.window, let content = window.contentView else {
            XCTFail("无窗口/内容视图"); return
        }
        guard let connect = button(in: content, identifier: "smbConnectButton") else {
            XCTFail("找不到 smbConnectButton（AX 标识缺失）"); return
        }
        // 按钮整帧换算到 window 坐标（convert(_:to: nil)=window 坐标），须完整落在内容区内。
        // 被裁形态=底缘越过内容区底缘（minY 更小，非翻转坐标下的数值巧合）。
        let inWindow = connect.convert(connect.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minY, content.frame.minY,
                                    "Connect 按钮底缘须完整落在窗口内容区内（被裁=越过底缘）：win=\(inWindow) content=\(content.frame)")
        XCTAssertLessThanOrEqual(inWindow.maxY, content.frame.maxY,
                                "按钮顶缘不得超出内容区：win=\(inWindow) content=\(content.frame)")
        wc.window?.orderOut(nil)   // tearDown 禁 close()（SIGSEGV 记忆坑）
    }

    // MARK: - SFTP 窗补 bottom 钉（保存列表使内容远超 300 初高，前轮「不裁」前提被推翻）

    // 变异证伪（红面映射）：删 ConnectionViewController.loadView 的 stack.bottomAnchor
    // 那行 → 窗高退回固定 300、含 110 高列表区的内容溢出 → 底缘断言红。
    // （历史：SMB 修前差分 -5pt；SFTP 当时实测密钥态 277<300 恒不裁故不锁——
    //  本功能给两窗各加名称行+列表区，内容确定 >300，同型锁这次真有牙。）
    func testSFTPDialogConnectButtonNotClipped() {
        let wc = ConnectionWindowController()
        _ = wc.window?.contentViewController?.view   // 强制 loadView
        wc.window?.animationBehavior = .none         // SIGSEGV 记忆坑：多窗前后动画
        wc.window?.layoutIfNeeded()
        guard let window = wc.window, let content = window.contentView else {
            XCTFail("无窗口/内容视图"); return
        }
        guard let connect = button(in: content, identifier: "connectButton") else {
            XCTFail("找不到 connectButton（AX 标识缺失）"); return
        }
        let inWindow = connect.convert(connect.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(inWindow.minY, content.frame.minY,
                                    "Connect 按钮底缘须完整落在窗口内容区内（被裁=越过底缘）：win=\(inWindow) content=\(content.frame)")
        XCTAssertLessThanOrEqual(inWindow.maxY, content.frame.maxY,
                                "按钮顶缘不得超出内容区：win=\(inWindow) content=\(content.frame)")
        wc.window?.orderOut(nil)
    }

    // MARK: - 首次 present 与再次 present 落位一致（评审 wf_12a5bbb0-534 confirmed 的台阶锁）

    // 评审实证：bottom 钉使窗高在**首排版**时才 autogrow（292→317 顶缘不动向下长）；
    // present() 的 center() 若跑在排版前 → 首次按旧高居中、显示时向下长 25pt →
    // 首次落位比之后每次低 ~6pt（静止终态差非动画瞬态）。修=center 前 layoutIfNeeded。
    // 变异证伪（红面映射）：删 SMBConnectionWindowController.present 的 window?.layoutIfNeeded()
    // → 本条测试体内 init→present 同 runloop 无空转（与评审探针同型），首帧 center 踩 292
    // 旧高、showWindow 才生长 → |first.y − second.y| ≈ 6 > 1 红；余断言不受影响。
    func testFirstPresentPositionMatchesSecond() {
        let wc = SMBConnectionWindowController()
        wc.window?.animationBehavior = .none
        wc.present()
        let first = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        wc.present()   // 第二次：窗已 autogrow 完成，center 必踩真实高
        let second = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        XCTAssertLessThan(abs(first.y - second.y), 1,
                          "首次 present 不得比再次打开低/高（autogrow 时序台阶）：first=\(first) second=\(second)")
        XCTAssertLessThan(abs(first.x - second.x), 1, "x 向同理：first=\(first) second=\(second)")
    }

    // MARK: - SFTP 窗同款台阶锁（评审探针差分实证 deltaY=23 后修法=中心同上）

    // 探针实测（修前形态）：SFTP 首开 y=925、再次 948，deltaY=23（SMB 对照组 0）——
    // 本窗加了名称行+110 列表区后内容 427 > init 332，center 踩未排版旧高居中，
    // 显示时才 autogrow 向下生长 → 首开低 23pt。修法=SMB present 同款：
    // center 前 window?.layoutIfNeeded()（SMBConnectionWindowController:40 先例）。
    // 差分证牙：修前跑本条即红（deltaY=23 > 1），修后绿——修前红形态先于修法落地。
    func testSFTPFirstPresentPositionMatchesSecond() {
        let wc = ConnectionWindowController()
        wc.window?.animationBehavior = .none
        wc.present()
        let first = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        wc.present()
        let second = wc.window!.frame.origin
        wc.window?.orderOut(nil)
        XCTAssertLessThan(abs(first.y - second.y), 1,
                          "SFTP 首次 present 不得比再次打开低/高（autogrow 时序台阶）：first=\(first) second=\(second)")
        XCTAssertLessThan(abs(first.x - second.x), 1, "x 向同理：first=\(first) second=\(second)")
    }
}
