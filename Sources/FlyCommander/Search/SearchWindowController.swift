import AppKit
import TCCore

final class SearchWindowController: NSWindowController {
    private let searchVC = SearchViewController()
    /// 窗口标题的静态 key（init 时冻结一次，语言切换时重刷）。
    private let titleKey: L10nKey = .searchWindowTitle

    var onOperation: ((OperationState) -> Void)? {
        didSet { searchVC.onOperation = onOperation }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = L10n.t(.searchWindowTitle)
        window.contentViewController = searchVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 语言变更后重刷：窗口标题 + 内容 VC 静态标签。标题为静态（init 冻结一次）；
    /// 内容仅在已加载时刷新（`isViewLoaded`），绝不强行 loadView 打开未用过的窗口。
    func refreshLocalizedText() {
        window?.title = L10n.t(titleKey)
        if searchVC.isViewLoaded { searchVC.refreshLocalizedText() }
    }

    func present(root: TCPath, source: FileSource, select: @escaping (SearchHit) -> Void) {
        searchVC.prepare(root: root, source: source, onSelect: select)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        searchVC.focusPatternField()
    }
}
