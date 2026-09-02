import AppKit
import TCCore

/// SFTP 连接窗控制器（仿 SearchWindowController：非模态、可多开）。
final class ConnectionWindowController: NSWindowController {
    private let connectionVC = ConnectionViewController()
    /// `sftp host[:port]` 命令预填（present 的 prepare 之后应用）。
    private var pendingHost: String?
    private var pendingPort: UInt16?

    /// 连接成功回调：(远端数据源, 远端 home 绝对路径)。
    var onConnected: ((SFTPSource, String) -> Void)? {
        didSet { connectionVC.onConnected = onConnected }
    }

    /// 预填主机/端口（命令栏 `sftp host[:port]` 入口）；present 时生效并清空。
    func setPendingHost(_ host: String?, port: UInt16? = nil) {
        pendingHost = host
        pendingPort = port
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.t(.sftpWindowTitle)
        window.contentViewController = connectionVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        connectionVC.prepare()
        // 命令栏 sftp host[:port] 预填：覆盖 prepare 的最近连接回填
        if let host = pendingHost, !host.isEmpty { connectionVC.prefillHost(host) }
        if let port = pendingPort { connectionVC.prefillPort(port) }
        pendingHost = nil
        pendingPort = nil
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        connectionVC.focusHostField()
    }
}
