import AppKit
import TCCore

final class SearchWindowController: NSWindowController {
    private let searchVC = SearchViewController()

    var onOperation: ((OperationState) -> Void)? {
        didSet { searchVC.onOperation = onOperation }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "搜索文件"
        window.contentViewController = searchVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(root: TCPath, select: @escaping (SearchHit) -> Void) {
        searchVC.prepare(root: root, onSelect: select)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // 聚焦须等窗口就位（prepare 里 view.window 尚为 nil，makeFirstResponder 无效）
        searchVC.focusPatternField()
    }
}
