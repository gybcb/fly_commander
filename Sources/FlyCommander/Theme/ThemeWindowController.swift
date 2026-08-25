import AppKit

/// 主题窗（非模态，仿 SearchWindowController）。改即生效——各控件 action 直接写 ThemeStore。
final class ThemeWindowController: NSWindowController {
    private let themeVC = ThemeViewController()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "主题"
        window.contentViewController = themeVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        _ = themeVC.view   // 强制 loadView 执行（否则 appearanceSegment 等 var...! 尚未 wire，reload 会解引用 nil 崩溃）
        themeVC.reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
