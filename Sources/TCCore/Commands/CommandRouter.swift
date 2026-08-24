import Foundation

public final class CommandRouter {
    public let workspace: Workspace
    public let engine: OperationEngine
    public var conflictPrompt: ConflictPrompt?
    public var onDelete: ((FilePane, [FileItem]) -> Void)?
    public var onView: ((FileItem) -> Void)?
    public var onEdit: ((FileItem) -> Void)?
    public var onSearch: ((TCPath) -> Void)?
    /// 远端传输委托（app 层注入）：复制/移动任一端是远端源且注入了此钩子时，
    /// 交给它后台执行（主线程不阻塞）。未注入或双端皆本地 → 走本地快路径（同步）。
    /// 参数：(isCopy, 活动窗格=源, 另一窗格=目标)。
    public var onRemoteTransfer: ((_ isCopy: Bool, _ srcPane: FilePane, _ dstPane: FilePane) -> Void)?

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
        case .home: a.moveFocus(to: 0, mode: moveMode)
        case .end: a.moveFocus(to: a.itemCount - 1, mode: moveMode)
        case .enter: a.enterFocusedDirectory()
        case .parent: a.gotoParent()
        case .switchPane: workspace.switchActive()
        case .toggleMark: a.toggleMark()
        case .selectAll: a.selectAll()
        case .clearMarks, .cancel: a.clearMarks()
        case .copy: handleTransfer(isCopy: true)
        case .move: handleTransfer(isCopy: false)
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
            try engine.performRename(item, to: newName, source: workspace.activePane.source)
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
            _ = try engine.performMakeDirectory(name, in: a.path, source: a.source)
            a.load()
            workspace.operationState(.done("已新建目录"))
        } catch {
            a.load()
            workspace.operationState(.failed(asTCError(error).message))
        }
    }

    /// 复制/移动入口：远端参与且注入了委托 → 交给 app 层后台执行；
    /// 否则走本地快路径（runTransfer，同步，core 测试语义不变）。
    private func handleTransfer(isCopy: Bool) {
        let a = workspace.activePane
        let t = workspace.inactivePane
        if let remote = onRemoteTransfer, a.source.isRemote || t.source.isRemote {
            remote(isCopy, a, t)
        } else {
            runTransfer(isCopy: isCopy)
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
        let src = a.source
        let dst = t.source
        var warnings: [String] = []
        ws.operationState(.running(label: label, progress: 0))
        do {
            if isCopy {
                try eng.performCopy(targets, to: t.path, srcSource: src, dstSource: dst,
                                    prompt: conflictPrompt) { d, c in
                    ws.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            } else {
                try eng.performMove(targets, to: t.path, srcSource: src, dstSource: dst,
                                    prompt: conflictPrompt,
                                    progress: { d, c in
                    ws.operationState(.running(label: label, progress: c == 0 ? 0 : Double(d) / Double(c)))
                },
                                    onWarning: { warnings.append($0) })
            }
            a.load()
            t.load()
            let note = warnings.isEmpty ? "" : "　⚠ \(warnings.joined(separator: "；"))"
            workspace.operationState(.done("\(label) 完成\(note)"))
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
