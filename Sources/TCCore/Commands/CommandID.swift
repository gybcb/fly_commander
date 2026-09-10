import Foundation

public enum CommandID: Hashable {
    case up, down, pageUp, pageDown, home, end
    case enter, parent
    case switchPane
    case nextTab, prevTab
    case toggleMark, selectAll, clearMarks
    case copy, move, delete, rename, makeDirectory
    case viewFile, editFile, search
    /// F2：收藏/取消收藏活动窗格当前目录（切换语义，实现在 app 层的 onFavorite 钩子）。
    case favoriteDirectory
    case cancel
    /// 激活底部命令栏（焦点移到输入框；右箭头触发）。
    case activateCommandLine
}
