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
}
