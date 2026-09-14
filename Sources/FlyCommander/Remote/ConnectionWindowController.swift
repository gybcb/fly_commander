import AppKit
import TCCore

/// 唯一的「连接到远端」窗控制器（仿 SearchWindowController：非模态、单例复用）。
///
/// 取代旧 ConnectionWindowController（SFTP）+ SMBConnectionWindowController（SMB）：
/// 标题随当前协议现取（切段即换题），present 支持预选协议 + 预填字段。
final class ConnectionWindowController: NSWindowController {
    private let connectionVC = RemoteConnectionViewController()

    /// 连接成功回调：(远端数据源, 起始路径)。
    var onConnected: ((any FileSource, TCPath) -> Void)? {
        didSet { connectionVC.onConnected = onConnected }
    }

    /// 连接执行表：透传给内容 VC（生产接线由 MainViewController 注入
    /// `RemoteConnectExecutors.defaults`；测试注入同步 fake）。
    var executors: [RemoteProto: RemoteConnectExecutor] = [:] {
        didSet { connectionVC.executors = executors }
    }

    /// present 时生效并清空的一组预选/预填。
    private var pendingProto: RemoteProto?
    private var pendingHost: String?
    private var pendingPort: Int?
    private var pendingServer: String?
    private var pendingShare: String?
    private var pendingUser: String?

    /// 预选协议 + 预填字段（菜单/工具栏/命令栏入口）；present 时生效并清空。
    func setPending(proto: RemoteProto?, host: String? = nil, port: Int? = nil,
                    server: String? = nil, share: String? = nil, user: String? = nil) {
        pendingProto = proto
        pendingHost = host
        pendingPort = port
        pendingServer = server
        pendingShare = share
        pendingUser = user
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

    /// 窗口标题按协议现取（未指定协议=表单当前协议）。
    private static func title(for proto: RemoteProto) -> String {
        switch proto {
        case .sftp: return L10n.t(.sftpWindowTitle)
        case .smb: return L10n.t(.smbWindowTitle)
        case .ftp: return L10n.t(.ftpWindowTitle)
        }
    }

    /// 语言变更后重刷：窗口标题 + 内容 VC 静态标签。仅在内容已加载时刷新，绝不强行 loadView。
    func refreshLocalizedText() {
        if connectionVC.isViewLoaded {
            window?.title = Self.title(for: connectionVC.proto)
            connectionVC.refreshLocalizedText()
        } else {
            window?.title = L10n.t(.sftpWindowTitle)
        }
    }

    func present() {
        connectionVC.prepare()
        // 预选协议先于预填：预填字段与协议字段组可见性对齐。
        if let proto = pendingProto { connectionVC.setProto(proto) }
        connectionVC.prefill(host: pendingHost, port: pendingPort, server: pendingServer,
                             share: pendingShare, username: pendingUser)
        pendingProto = nil
        pendingHost = nil
        pendingPort = nil
        pendingServer = nil
        pendingShare = nil
        pendingUser = nil
        window?.title = Self.title(for: connectionVC.proto)
        window?.layoutIfNeeded()
        // center() 前必须先排版：bottom 钉使窗高在首排版时才 autogrow，
        // center 若先跑则按旧高居中、显示时向下生长 → 首开比再次打开低 ~23pt
        // （旧 SMB 窗同款先例，台阶锁 ConnectionDialogButtonClipTests）。
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        connectionVC.focusPrimaryField()
    }
}
