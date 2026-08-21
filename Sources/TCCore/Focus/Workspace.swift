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
