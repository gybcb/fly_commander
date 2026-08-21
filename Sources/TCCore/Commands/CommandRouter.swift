import Foundation

public final class CommandRouter {
    public let workspace: Workspace
    public let engine: OperationEngine
    public var conflictPrompt: ConflictPrompt?
    public var onDelete: ((FilePane, [FileItem]) -> Void)?
    public var onView: ((FileItem) -> Void)?
    public var onEdit: ((FileItem) -> Void)?
    public var onSearch: ((TCPath) -> Void)?

    public init(workspace: Workspace, engine: OperationEngine = OperationEngine()) {
        self.workspace = workspace
        self.engine = engine
    }

    public func execute(_ id: CommandID, moveMode: SelectionModel.MoveMode = .simple) {
        let a = workspace.activePane
        switch id {
        case .up: a.moveFocusBy(delta: -1, mode: moveMode)
        case .down: a.moveFocusBy(delta: 1, mode: moveMode)
        case .pageUp: a.moveFocusBy(delta: -15, mode: moveMode)
        case .pageDown: a.moveFocusBy(delta: 15, mode: moveMode)
        case .home: a.moveFocus(to: 0, mode: .simple)
        case .end: a.moveFocus(to: a.itemCount - 1, mode: .simple)
        case .enter: a.enterFocusedDirectory()
        case .parent: a.gotoParent()
        case .switchPane: workspace.switchActive()
        case .toggleMark: a.toggleMark()
        case .selectAll: a.selectAll()
        case .clearMarks, .cancel: a.clearMarks()
        case .copy: runTransfer(isCopy: true)
        case .move: runTransfer(isCopy: false)
        case .delete:
            let targets = a.operationTargets
            if !targets.isEmpty { onDelete?(a, targets) }
        case .rename: break
        case .makeDirectory: break
        case .viewFile:
            if let item = a.focusedItem, !item.isDirectory { onView?(item) }
        case .editFile:
            if let item = a.focusedItem, !item.isDirectory { onEdit?(item) }
        case .search:
            onSearch?(a.path)
        }
    }

    public func rename(to newName: String) {
        guard let item = workspace.activePane.focusedItem else { return }
        workspace.operationState(.running(label: "重命名", progress: 0))
        do {
            try engine.performRename(item, to: newName)
            workspace.activePane.load()
            workspace.operationState(.done("已重命名"))
        } catch {
            workspace.activePane.load()
            workspace.operationState(.failed(asTCError(error).message))
        }
    }

    public func makeDirectory(named name: String) {
        let a = workspace.activePane
        workspace.operationState(.running(label: "新建目录", progress: 0))
        do {
            _ = try engine.performMakeDirectory(name, in: a.path)
            a.load()
            workspace.operationState(.done("已新建目录"))
        } catch {
            a.load()
            workspace.operationState(.failed(asTCError(error).message))
        }
    }

    private func runTransfer(isCopy: Bool) {
        let a = workspace.activePane
        let t = workspace.inactivePane
        let targets = a.operationTargets
        guard !targets.isEmpty else { return }
        let label = (isCopy ? "复制" : "移动") + " \(targets.count) 个文件"
        let ws = workspace
        let eng = engine
        ws.operationState(.running(label: label, progress: 0))
        do {
            if isCopy {
                try eng.performCopy(targets, to: t.path, prompt: conflictPrompt) { d, c in
                    ws.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            } else {
                try eng.performMove(targets, to: t.path, prompt: conflictPrompt) { d, c in
                    ws.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            }
            a.load()
            t.load()
            workspace.operationState(.done("\(label) 完成"))
        } catch let e as TCError {
            a.load()
            t.load()
            workspace.operationState(e == .cancelled ? .idle : .failed(e.message))
        } catch {
            a.load()
            t.load()
            workspace.operationState(.failed(error.localizedDescription))
        }
    }
}
