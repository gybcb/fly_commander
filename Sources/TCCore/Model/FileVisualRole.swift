import Foundation

public enum FileVisualRole: Equatable {
    case normal, directory, marked, focus, hidden, readOnly
}

public func visualRole(for item: FileItem, isMarked: Bool, isFocus: Bool) -> FileVisualRole {
    if isFocus { return .focus }
    if isMarked { return .marked }
    if item.isHidden { return .hidden }
    if item.isReadOnly { return .readOnly }
    if item.isDirectory { return .directory }
    return .normal
}
