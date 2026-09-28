import Foundation

public enum CommandID: Hashable {
    case up, down, pageUp, pageDown, home, end
    case enter, parent
    case switchPane
    case nextTab, prevTab
    case toggleMark, selectAll, clearMarks
    case copy, move, delete, rename, makeDirectory
    case viewFile, editFile, search
    /// F2：弹出活动侧收藏下拉菜单（实现在 app 层的 onOpenFavoritesMenu 钩子；
    /// 收藏/取消收藏经菜单内建切换项，不再由 F2 直接切换）。
    case openFavoritesMenu
    case cancel
    /// 激活底部命令栏（焦点移到输入框；右箭头触发）。
    case activateCommandLine
    /// 重载活动窗格当前目录（手动刷新 ⌃R / 命令栏 `refresh`；自动刷新的手动兜底）。
    case refresh
    /// ⌃1/⌃2/⌃3（View 菜单 keyEquivalent）：活动窗格操作目标（标记多项→多行 / 无标记
    /// →焦点单项）拷贝到剪贴板的三种粒度（内核零 AppKit，经 onCopyPaths 钩子交 app 层落
    /// NSPasteboard；路径串=displayString，远端携 scheme://host:port）：
    /// copyPath=条目全路径；copyDirPath=所在目录路径；copyFileName=仅名称。
    case copyPath, copyDirPath, copyFileName
}
