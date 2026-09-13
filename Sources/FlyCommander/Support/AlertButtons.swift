import AppKit

extension NSAlert {
    /// 统一默认按钮：第 1 按钮挂 ⏎（回车即确认），标题为「取消」文案的按钮挂 Esc。
    /// 不改变 runModal 返回值映射，只改变回车/Esc 触发哪个按钮。
    /// 写法对齐 SearchViewController 先例（keyEquivalentModifierMask 显式清空）。
    /// 本机 SDK 实测（见 `KeyEquivalentDefaultMaskTests`）：`NSAlert` 自动给第 1 按钮挂 `"\r"`，
    /// 并给**标题等于取消文案**的按钮自动挂 `"\u{1b}"`；赋 keyEquivalent **不会**顺带设修饰掩码
    /// （默认 0）。所以本方法对 Esc 是幂等的再确认，对没有取消标题按钮的框则什么也不做——
    /// 那类框的 Esc 交给 NSAlert 默认行为。历史上那句"NSAlert 默认给取消键带 ⌘ 掩码"的注释
    /// 与实测不符，已按实测改写；清空掩码保留为防御写法（挡住 SDK 行为变化）。
    ///
    /// **这不是键路由的保证**，只是静态/无障碍语义：`runModal()` 一进入就会把第 1 按钮的
    /// `keyEquivalent` 清成 `""`、把 Return 改由 `window.defaultButtonCell` 承担（本仓探针实证：
    /// `DeleteConfirmKeyRoutingProbeTests`，`PRE b0="\r"` → `DURING b0="" defaultButtonCell=Delete`），
    /// 而取消键的 `"\u{1b}"` 会被原样保留。于是 Return 变成"依赖 key window 的默认按钮"、
    /// Esc 变成"纯键等价匹配"——两者路由条件不同，这正是「⏎ 全哑 / Esc 时好时坏」的来源。
    /// 真正与 key window 落点无关的保证在 `runConfirmModal()`。
    func setDefaultConfirmCancel() {
        if let confirm = buttons.first {
            confirm.keyEquivalent = "\r"
            confirm.keyEquivalentModifierMask = []
        }
        if let cancel = buttons.first(where: { $0.title == L10n.t(.cancelBtn) }) {
            cancel.keyEquivalent = "\u{1b}"
            cancel.keyEquivalentModifierMask = []
        }
    }

    /// **确认框呈现的唯一收口**（同步）。所有"需要 ⏎ 确认 / Esc 取消"的 NSAlert 都该走这里，
    /// 而不是裸 `runModal()`：裸调用把 Return 的命运交给 key window，键事件一旦没落到面板
    /// （F8 把 `runModal` 开在 keyDown 派发栈内时就会这样），⏎ 就完全没反应。
    /// 返回值为 `runModal()` 原值，同步语义不变（`promptConflict` 被传输引擎同步消费，必须保持同步）。
    @discardableResult
    func runConfirmModal() -> NSApplication.ModalResponse {
        ConfirmModal.run(self)
    }
}

/// 确认框收口实现。收口理由同 `NSAlert.runConfirmModal()` 的注释。
enum ConfirmModal {
    /// 重入守卫：已有一个确认框在跑时，第二次进入按"取消"处理（第二按钮语义），
    /// 绝不叠出第二层 modal（叠框＝用户视角"Esc/⏎ 只作用一层，怎么按都不动"）。
    private static var isPresenting = false

    /// 与 key window 落点无关的键路由。用 local monitor 而不是窗层 `sendEvent` 拦截
    /// （本仓 `FlyWindow.sendEvent` 拦 ⌃⇥、`PreviewWindow.sendEvent` 拦 Esc 的先例）：
    /// 窗层拦截的前提是"事件先到达那个窗"，而本缺陷的失败模式恰好是**事件没到面板**——
    /// 面板的 `sendEvent` 根本不会被调用。local monitor 在事件被派发给任何窗**之前**回调，
    /// 这正是需要的那一层。作用域由 `NSApp.modalWindow === panel` 钉死，`defer` 摘除。
    @discardableResult
    static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        guard !isPresenting else { return .alertSecondButtonReturn }
        isPresenting = true
        defer { isPresenting = false }

        // 只做两件事：走一遍静态键等价、在事件派发之前接住 ⏎/⌤/Esc。
        // **刻意不做**（曾写过，实测冗余且有害）：
        // - `panel.layoutIfNeeded()`：实测排版不改写键等价（见本文件探针的 AFTER_LAYOUT 采样）。
        // - `makeKeyAndOrderFront` / `makeFirstResponder(按钮)`：`runModal()` 自身就会置前并接管
        //   键会话（菜单入口那条路一直正常就是证据）；而 headless 实测证明 ⏎ 并不要求面板是
        //   key。多这一手只会把**重命名/新建目录框的文本框焦点**抢到按钮上（差分测
        //   `testFunnelDoesNotChangeAccessoryFocus` 盯着这件事）。
        alert.setDefaultConfirmCancel()
        let panel = alert.window          // 触发建面板，并拿到 monitor 的作用域判据

        let confirm = alert.buttons.first
        let cancel = alert.buttons.first { $0.title == L10n.t(.cancelBtn) }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard NSApp.modalWindow === panel else { return event }   // 只管本框的 modal 会话
            let bare = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            guard bare else { return event }                          // 带修饰一律不抢（同窗层合同）
            // 主键盘 ⏎(36) 与小键盘 ⌤(76) 同等对待 —— 对齐 KeyDispatcher 把两者都当 .enter 的既有约定。
            switch event.keyCode {
            case 36, 76:
                guard !event.isARepeat else { return nil }
                confirm?.performClick(nil)
                return nil
            case 53 where cancel != nil:
                guard !event.isARepeat else { return nil }
                cancel?.performClick(nil)
                return nil
            default:
                return event
            }
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        return alert.runModal()
    }
}
