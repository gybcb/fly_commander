import Foundation

public enum OperationState: Equatable {
    case idle
    case running(label: String, progress: Double)
    case done(String)
    case failed(String)
}

public final class Workspace {
    public let left: FilePane
    public let right: FilePane
    public private(set) var active: PaneID

    public var onActiveChange: ((Workspace) -> Void)?
    public var onOperationState: ((OperationState) -> Void)?
    /// 命令栏 copy/move（等价 F5/F6）：app 层接 CommandRouter 的传输路径（远端走后台）。
    public var onCommandTransfer: ((CommandID) -> Void)?
    /// 命令栏需要状态栏提示时的文本落点（不经过 OperationState 通道）。
    public var onCommandStatus: ((String) -> Void)?
    /// 命令栏 view/edit 的 app 层入口（复用菜单同款行为）。
    public var onCommandView: ((FileItem) -> Void)?
    public var onCommandEdit: ((FileItem) -> Void)?

    public init(left: FilePane, right: FilePane, active: PaneID = .left) {
        self.left = left
        self.right = right
        self.active = active
    }

    public var activePane: FilePane { active == .left ? left : right }
    public var inactivePane: FilePane { active == .left ? right : left }

    public func activate(_ id: PaneID) {
        guard active != id else { return }
        active = id
        onActiveChange?(self)
    }

    public func switchActive() { activate(active == .left ? .right : .left) }

    public func operationState(_ s: OperationState) { onOperationState?(s) }
}
