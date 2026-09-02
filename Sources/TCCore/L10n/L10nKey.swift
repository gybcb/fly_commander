import Foundation
/// 用户可见串的稳定 key。rawValue = 持久/调试用标识，非展示文案。
/// 新增串=加 case + 在 en/zh 两表各补一行。内核零文案，仅枚举。
public enum L10nKey: String, Hashable, CaseIterable {
    // —— 通用/对话框按钮 ——
    case ok, cancel, create, `default`, close, browse, connect, forget
    // —— 菜单 ——
    case menuFile
    // —— 命令回显（AppKit 层 InternalCommandExecutor）——
    case entered, cannotEnterNotDirectory
    // —— 状态栏前缀 ——
    case statusErrorPrefix
    // —— 仅供 fallback 回归测试，故意只进 en 表 ——
    case testFallbackProbe
    // …（各任务按 key 清单增补本 enum）
}
