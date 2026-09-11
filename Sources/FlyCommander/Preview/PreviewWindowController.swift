import AppKit
import TCCore

/// Esc 关窗主修（用户报「预览窗要能按 Esc 直接关」）：既有机制「响应链 cancelOperation →
/// PreviewViewController.cancelOperation」只在 FR 位于内容子树时可达——探针实测大量场景够不到：
/// 图片/降级页（无可当选 key view，FR=NSWindow 自身而普通窗把 cancelOperation 就地终结）、
/// PDF/富文本异步 placeholder 窗口期、swapContent 换内容后 FR 悬空、单例窗第二次预览
/// （AppKit 的 FR 自动当选只在新窗首次 key 时发生一次）。窗层 sendEvent 拦截与 FR 落点无关，
/// 探针 7/7 全路命中（含响应链救不动的可编辑文本态）。裸 Esc → performClose；一切带修饰的
/// Esc（⌘/⌃/⌥/⇧）在窗层吞掉——放行进 interpretKeyEvents 会经响应链巧合关窗（冒烟测抓出），
/// 预览窗内无功能依赖带修饰 Esc，收紧成确定性合同。同 SDK 窗层拦截先例=FlyWindow.sendEvent
/// 拦 ⌃⇥（MainWindowController.swift）。PreviewViewController.cancelOperation 覆写保留
/// （菜单/其他 cancel 入口沿响应链仍可达；键盘 Esc 已在 sendEvent 消费，不双触发）。
final class PreviewWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 {   // kVK_Escape
            // 裸 Esc → 关窗。带 ⌘/⌃/⌥/⇧ 的 Esc **一律吞掉**：放行给 super 会走
            // interpretKeyEvents→cancelOperation→响应链，FR 在内容子树时照样关窗
            // （冒烟测抓出：⌘Esc 实测能关=历史巧合行为）；预览窗内没有任何功能
            // 依赖带修饰 Esc，统一收紧成确定性合同。
            if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                performClose(nil)   // 走红叉同一条码路：willCloseNotification 照发（.media 停播合同）
            }
            return
        }
        super.sendEvent(event)
    }
}

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
    /// 测试用：取**生产单例窗本身**（Esc 关窗冒烟锁必须经生产 PreviewWindow 类——夹具自建裸窗
    /// 测不到窗层 sendEvent 拦截。返回后由测试自行 orderFront 离屏驱动）。
    static func previewWindowForTest() -> NSWindow? {
        createWithoutPresentingForTest().window
    }
    #endif

    static func show(item: FileItem) {
        shared.present(item: item)
    }

    /// 主窗 Esc 连带关预览（用户拍板：预览开着 → Esc 先关预览；没开 → 维持原 clearMarks 语义）。
    /// performClose 走红叉同一条码路 → willCloseNotification 照发（.media 停播合同不破）。
    /// 返回 true=本调用关掉了预览窗，调用方须取消该键的原语义（不再清标记）。
    @discardableResult
    static func closeIfVisible() -> Bool {
        guard let w = _shared?.window, w.isVisible else { return false }
        w.performClose(nil)
        return true
    }

    /// 语言变更后经主 VC 调用：仅当窗口已被创建（曾预览过）才重刷，绝不建窗/上屏。
    static func refreshLocalizedTextIfCreated() {
        _shared?.refreshLocalizedText()
    }

    private var hasBeenShown = false
    /// 最近一次预览的文件名（present 时记录）；nil=尚未预览任何文件 → 用纯标题。
    private var lastFileName: String?

    private init() {
        let window = PreviewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentMinSize = NSSize(width: 360, height: 240)
        // 单例复用契约：performClose 只隐藏不释放（本 SDK 默认恰为 false——显式钉死，
        // 别把单例生死押在默认值上；冒烟夹具同款先例 PreviewRenderingSmokeTests）。
        window.isReleasedWhenClosed = false
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
        } else if window?.isVisible == false, let w = window {
            // 重开级联要**有界**（评审 wf_52002fb5-560 C-2）：Esc 关窗可达后，关→F3 重开
            // 成为键盘主路径，旧「无条件 +48」约 24 轮把窗夹死在屏幕右上角、永不归位
            // （探针实证 constrainFrameRect 不拉回贴角合法位）。越过可见区即重置回中，
            // 观感=有限次错落循环，且用户手拖的位置至少被记住一轮。
            let frame = w.frame
            var origin = NSPoint(x: frame.origin.x + 48, y: frame.origin.y + 48)
            if let vf = (w.screen ?? NSScreen.main)?.visibleFrame {
                if origin.x + frame.width > vf.maxX || origin.y + frame.height > vf.maxY
                    || origin.x < vf.minX || origin.y < vf.minY {
                    w.center()
                    origin = w.frame.origin
                }
            }
            w.setFrameOrigin(origin)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
