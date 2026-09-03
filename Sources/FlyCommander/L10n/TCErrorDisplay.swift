import Foundation
import TCCore

/// TCError → 当前语言成品串（唯一 UI 显示入口）。
/// 内核 `message` 是稳定英文内部契约（日志/测试/跨模块），不进 UI 显示路径；
/// 显示一律经此函数按 `l10nKey`+`l10nArgs` 查 L10n 表。
func tcErrorDisplay(_ e: TCError) -> String {
    L10n.t(e.l10nKey, args: e.l10nArgs)
}
