import AppKit
import TCCore

/// SFTP 连接窗控制器（仿 SearchWindowController：非模态、可多开）。
final class ConnectionWindowController: NSWindowController {
    private let connectionVC = ConnectionViewController()
    /// 窗口标题静态 key（init 冻结一次，语言切换重刷）。
    private let titleKey: L10nKey = .sftpWindowTitle
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

    /// 语言变更后重刷：窗口标题 + 内容 VC 静态标签。仅在内容已加载时刷新，绝不强行 loadView。
    func refreshLocalizedText() {
        window?.title = L10n.t(titleKey)
        if connectionVC.isViewLoaded { connectionVC.refreshLocalizedText() }
    }

    func present() {
        connectionVC.prepare()
        // 命令栏 sftp host[:port] 预填：覆盖 prepare 的最近连接回填
        if let host = pendingHost, !host.isEmpty { connectionVC.prefillHost(host) }
        if let port = pendingPort { connectionVC.prefillPort(port) }
        pendingHost = nil
        pendingPort = nil
        window?.layoutIfNeeded()
        // center() 前必须先排版：bottom 钉使窗高在首排版时才 autogrow（332→427），
        // center 若先跑则按旧高居中、显示时向下生长 → 首开比再次打开低 ~23pt
        // （SMBConnectionWindowController 同款先例）。
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        connectionVC.focusHostField()
    }
}
