import Foundation

public final class CommandRouter {
    public let workspace: Workspace
    public let engine: OperationEngine
    public var conflictPrompt: ConflictPrompt?
    public var onDelete: ((FilePane, [FileItem]) -> Void)?
    public var onView: ((FileItem) -> Void)?
    public var onEdit: ((FileItem) -> Void)?
    /// 回车/双击落在**文件**上：交 AppKit 层用默认程序打开（内核不知 NSWorkspace）。
    /// 目录仍走内核 enterFocusedDirectory；文件才发此钩子。空焦点两者皆不发。
    public var onOpen: ((FileItem) -> Void)?
    public var onSearch: ((TCPath, FileSource) -> Void)?
    /// F2 弹收藏菜单（app 层注入）：内核不持收藏夹（零 UserDefaults），只上报活动窗格。
    public var onOpenFavoritesMenu: ((FilePane) -> Void)?
    /// 远端传输委托（app 层注入）：复制/移动任一端是远端源且注入了此钩子时，
    /// 交给它后台执行（主线程不阻塞）。未注入或双端皆本地 → 走本地快路径（同步）。
    /// 参数：(isCopy, 活动窗格=源, 另一窗格=目标)。
    public var onRemoteTransfer: ((_ isCopy: Bool, _ srcPane: FilePane, _ dstPane: FilePane) -> Void)?
    /// 警告成品串组装器（app 层注入，与 `conflictPrompt` 同款）：内核只产
    /// `(残留文件名, TCError)` 结构化原料，本地化在持 L10n 的装配处做。
    /// nil（纯内核测试环境）→ 兜底内部英文串 `"\(name) (\(err.message))"`。
    public var warnFormatter: ((String, TCError) -> String)?

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
        case .enter:
            // 目录→进入（TC 传统）；文件→交 AppKit 默认程序打开（回车/双击共用此路）。
            if let item = a.focusedItem, !item.isDirectory { onOpen?(item) }
            else { a.enterFocusedDirectory() }
        case .parent: a.gotoParent()
        case .switchPane: workspace.switchActive()
        case .nextTab: workspace.nextTab()
        case .prevTab: workspace.prevTab()
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
            onSearch?(a.path, a.source)
        case .openFavoritesMenu:
            onOpenFavoritesMenu?(a)
        case .activateCommandLine:
            // 焦点移到命令栏是视图层职责（router 无 UI）；PaneTableView 直接调
            // commandBar.activate()。此分支仅为穷举 CommandID，不应经 router 触发。
            break
        }
    }

    /// 操作后刷新：远端窗格走异步加载（同步 load 会把网络 RTT 卡进主线程）。
    private func reloadPane(_ pane: FilePane) {
        if pane.source.isRemote { pane.loadAsync() } else { pane.load() }
    }

    public func rename(to newName: String) {
        guard let item = workspace.activePane.focusedItem else { return }
        workspace.operationState(.running(label: .rename, args: [], progress: 0))
        do {
            try engine.performRename(item, to: newName, source: workspace.activePane.source)
            reloadPane(workspace.activePane)
            workspace.operationState(.done(label: .opRenameDone, args: [], warningLines: []))
        } catch {
            reloadPane(workspace.activePane)
            workspace.operationState(.failed(asTCError(error)))
        }
    }

    public func makeDirectory(named name: String) {
        let a = workspace.activePane
        workspace.operationState(.running(label: .newDirectory, args: [], progress: 0))
        do {
            _ = try engine.performMakeDirectory(name, in: a.path, source: a.source)
            reloadPane(a)
            workspace.operationState(.done(label: .opMkdirDone, args: [], warningLines: []))
        } catch {
            reloadPane(a)
            workspace.operationState(.failed(asTCError(error)))
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
        let label: L10nKey = isCopy ? .opCopying : .opMoving
        let args = ["\(targets.count)"]
        let ws = workspace
        let eng = engine
        let src = a.source
        let dst = t.source
        var warnings: [(String, TCError)] = []
        ws.operationState(.running(label: label, args: args, progress: 0))
        do {
            if isCopy {
                try eng.performCopy(targets, to: t.path, srcSource: src, dstSource: dst,
                                    prompt: conflictPrompt) { d, c in
                    ws.operationState(.running(label: label, args: args, progress: c == 0 ? 0 : Double(d) / Double(c)))
                }
            } else {
                try eng.performMove(targets, to: t.path, srcSource: src, dstSource: dst,
                                    prompt: conflictPrompt,
                                    progress: { d, c in
                    ws.operationState(.running(label: label, args: args, progress: c == 0 ? 0 : Double(d) / Double(c)))
                },
                                    onWarning: { warnings.append(($0, $1)) })
            }
            a.load()
            t.load()
            workspace.operationState(.done(label: label, args: args, warningLines: formatted(warnings)))
        } catch let e as TCError {
            a.load()
            t.load()
            workspace.operationState(e == .cancelled ? .idle : .failed(e))
        } catch {
            a.load()
            t.load()
            workspace.operationState(.failed(.unknown(error.localizedDescription)))
        }
    }

    /// 警告原料 → 成品串（注入的 `warnFormatter`；未注入落内部英文）。
    private func formatted(_ warnings: [(String, TCError)]) -> [String] {
        let fmt = warnFormatter
        return warnings.map { fmt?($0, $1) ?? "\($0) (\($1.message))" }
    }
}
