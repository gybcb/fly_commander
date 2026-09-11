import AppKit
import TCCore

final class PreviewWindowController: NSWindowController {
    /// 单例（首次预览才建）。用可选 backing 而非 `static let`：语言重刷在"从未预览过任何文件"
    /// 时须能短路（`_shared == nil` → 什么都不做），绝不为重刷而凭空建出窗口。
    private static var _shared: PreviewWindowController?
    static var shared: PreviewWindowController {
        if let s = _shared { return s }
        let s = PreviewWindowController(); _shared = s; return s
    }
    #if DEBUG
    /// 测试用：窗口单例是否已创建（从未预览过则为 false）——断言重刷守卫不凭空建窗。
    static var hasCreatedWindowForTest: Bool { _shared != nil }
    /// 测试用：释放单例，使"未创建"守卫测与执行顺序无关（每个相关测开头调用）。
    static func resetSharedForTest() { _shared = nil }
    /// 测试用：创建但不显示窗口（不经 present，故不 orderFront），返回实例供标题断言。
    static func createWithoutPresentingForTest() -> PreviewWindowController { shared }
    /// 测试用：取内容 VC（冒烟测直接 show 到自建的离屏窗口，绕开单例上屏竞态）。
    static func previewVCForTest() -> PreviewViewController? {
        createWithoutPresentingForTest().window?.contentViewController as? PreviewViewController
    }
    #endif

    static func show(item: FileItem) {
        shared.present(item: item)
    }

    /// 语言变更后经主 VC 调用：仅当窗口已被创建（曾预览过）才重刷，绝不建窗/上屏。
    static func refreshLocalizedTextIfCreated() {
        _shared?.refreshLocalizedText()
    }

    private var hasBeenShown = false
    /// 最近一次预览的文件名（present 时记录）；nil=尚未预览任何文件 → 用纯标题。
    private var lastFileName: String?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentMinSize = NSSize(width: 360, height: 240)
        window.title = L10n.t(.previewWindowTitlePlain)
        window.contentViewController = PreviewViewController()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 语言变更后重刷：窗口标题（按 lastFileName 选键）+ 当前内容里的静态控件。
    /// 只在已创建的实例上调用（见 refreshLocalizedTextIfCreated），绝不 showWindow/orderFront。
    private func refreshLocalizedText() {
        window?.title = lastFileName.map { L10n.t(.previewWindowTitle, $0) }
            ?? L10n.t(.previewWindowTitlePlain)
        if let vc = window?.contentViewController as? PreviewViewController { vc.refreshLocalizedText() }
    }

    private func present(item: FileItem) {
        lastFileName = item.name
        window?.title = L10n.t(.previewWindowTitle, item.name)
        (window?.contentViewController as? PreviewViewController)?.show(item: item)
        if !hasBeenShown {
            hasBeenShown = true
            window?.center()
        } else if window?.isVisible == false {
            let frame = window!.frame
            window?.setFrameOrigin(NSPoint(x: frame.origin.x + 48, y: frame.origin.y + 48))
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
