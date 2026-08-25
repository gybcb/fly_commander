import Foundation

public enum CommandID: Hashable {
    case up, down, pageUp, pageDown, home, end
    case enter, parent
    case switchPane
    case nextTab, prevTab
    case toggleMark, selectAll, clearMarks
    case copy, move, delete, rename, makeDirectory
    case viewFile, editFile, search
    case cancel
    /// 激活底部命令栏（焦点移到输入框；右箭头触发）。
    case activateCommandLine
}
