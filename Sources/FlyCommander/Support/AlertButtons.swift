import AppKit

extension NSAlert {
    /// 统一默认按钮：第 1 按钮挂 ⏎（回车即确认），标题为「取消」文案的按钮挂 Esc。
    /// 不改变 runModal 返回值映射，只改变回车/Esc 触发哪个按钮。
    /// 写法对齐 SearchViewController 先例（keyEquivalentModifierMask 必须清空，
    /// 否则 NSAlert 默认给取消键带 ⌘ 掩码，裸 Esc 不生效）。
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
}
