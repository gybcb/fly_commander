import AppKit
import TCCore

final class SMBConnectionWindowController: NSWindowController {
    private let connectionVC = SMBConnectionViewController()
    /// 窗口标题静态 key（init 冻结一次，语言切换重刷）。
    private let titleKey: L10nKey = .smbWindowTitle
    private var pendingServer: String?
    private var pendingShare: String?
    private var pendingUser: String?

    var onConnected: ((SMBSource, TCPath) -> Void)? {
        didSet { connectionVC.onConnected = onConnected }
    }
    func setPending(server: String?, share: String? = nil, user: String? = nil) {
        pendingServer = server; pendingShare = share; pendingUser = user
    }
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.t(.smbWindowTitle)
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
        if let s = pendingServer { connectionVC.prefill(server: s, share: pendingShare, username: pendingUser) }
        pendingServer = nil; pendingShare = nil; pendingUser = nil
        // center() 前必须先排版：bottom 钉使窗高在首排版时才 autogrow（292→317），
        // center 若先跑则按旧高居中、显示时向下生长 → 首次落位比之后每次低 ~6pt
        // （评审 wf_12a5bbb0-534 confirmed，位置台阶锁 testFirstPresentPositionMatchesSecond）。
        window?.layoutIfNeeded()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        connectionVC.focusServerField()
    }
}
