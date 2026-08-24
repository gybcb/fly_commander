import AppKit
import TCCore

/// SFTP 连接窗控制器（仿 SearchWindowController：非模态、可多开）。
final class ConnectionWindowController: NSWindowController {
    private let connectionVC = ConnectionViewController()

    /// 连接成功回调：(远端数据源, 远端 home 绝对路径)。
    var onConnected: ((SFTPSource, String) -> Void)? {
        didSet { connectionVC.onConnected = onConnected }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "SFTP 连接"
        window.contentViewController = connectionVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        connectionVC.prepare()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        connectionVC.focusHostField()
    }
}
