import Foundation

public enum CommandID: Hashable {
    case up, down, pageUp, pageDown, home, end
    case enter, parent
    case switchPane
    case toggleMark, selectAll, clearMarks
    case copy, move, delete, rename, makeDirectory
    case cancel
}
