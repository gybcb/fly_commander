import AppKit
import TCCore

/// 主题窗（非模态，仿 SearchWindowController）。改即生效——各控件 action 直接写 ThemeStore。
final class ThemeWindowController: NSWindowController {
    private let themeVC = ThemeViewController()
    /// 窗口标题静态 key（init 冻结一次，语言切换重刷）。
    private let titleKey: L10nKey = .themeWindowTitle

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = L10n.t(.themeWindowTitle)
        window.contentViewController = themeVC
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 语言变更后重刷：窗口标题 + 内容 VC 静态标签。仅在内容已加载时刷新（不 `_ = themeVC.view`
    /// 强开视图——那正是 present 里为 wire 控件才做的事）。
    func refreshLocalizedText() {
        window?.title = L10n.t(titleKey)
        if themeVC.isViewLoaded { themeVC.refreshLocalizedText() }
    }

    func present() {
        _ = themeVC.view   // 强制 loadView 执行（否则 appearanceSegment 等 var...! 尚未 wire，reload 会解引用 nil 崩溃）
        themeVC.reload()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
