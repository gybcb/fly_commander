import AppKit
import TCCore

final class SMBConnectionWindowController: NSWindowController {
    private let connectionVC = SMBConnectionViewController()
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
    func present() {
        connectionVC.prepare()
        if let s = pendingServer { connectionVC.prefill(server: s, share: pendingShare, username: pendingUser) }
        pendingServer = nil; pendingShare = nil; pendingUser = nil
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        connectionVC.focusServerField()
    }
}
