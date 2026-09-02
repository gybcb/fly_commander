import AppKit
import TCCore

final class MainViewController: NSViewController, NSSplitViewDelegate {
    // 隐式解包：本工具链禁止在 loadView 里直接给 `let` 存储属性赋值
    private var workspace: Workspace!
    private var router: CommandRouter!
    private var leftContainer: SidePaneContainer!
    private var rightContainer: SidePaneContainer!
    private var split: NSSplitView!
    private let searchWindow = SearchWindowController()
    private let connectionWindow = ConnectionWindowController()
    private let smbConnectionWindow = SMBConnectionWindowController()
    private let themeWindow = ThemeWindowController()
    private var transferEngine: TransferEngine!
    private var commandBar: CommandLineBar!
    private var commandExecutor: InternalCommandExecutor!
    /// router（本地快路径/元操作）与 transferEngine（远端传输）共用同一引擎，保证语义一致。
    private let engine = OperationEngine()
    /// L10n 观察者 token（单例生命周期，永久保留；切换时重刷常驻 UI）。
    private var l10nToken: Int?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    /// 启动目录：`--start-dir <路径>` 参数或 FLY_START_DIR 环境变量优先（供 UI 测试
    /// 指向已知夹具目录），缺省为用户主目录。
    static var startPath: TCPath {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--start-dir"), i + 1 < args.count {
            return TCPath(args[i + 1])
        }
        if let dir = ProcessInfo.processInfo.environment["FLY_START_DIR"] {
            return TCPath(dir)
        }
        return TCPath("~")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let home = Self.startPath
        let source = LocalFileSource()
        let leftPane = FilePane(id: .left, source: source, startPath: home)
        let rightPane = FilePane(id: .right, source: source, startPath: home)
        workspace = Workspace(left: TabGroup(side: .left, panes: [leftPane]),
                              right: TabGroup(side: .right, panes: [rightPane]),
                              active: .left)

        router = CommandRouter(workspace: workspace, engine: engine)
        router.conflictPrompt = { [weak self] src, dst in self?.promptConflict(src, dst) ?? .overwrite }
        router.onDelete = { [weak self] pane, targets in self?.doTrashDelete(pane: pane, targets: targets) }
        router.onView = { [weak self] item in self?.showPreview(item) }
        router.onEdit = { [weak self] item in self?.openForEdit(item) }
        router.onSearch = { [weak self] root, source in self?.beginSearch(in: root, source: source) }

        // 远端传输：router 检测到任一端 isRemote 时委托后台执行器（主线程不冻结）。
        transferEngine = TransferEngine(engine: engine)
        transferEngine.state = { [weak self] s in self?.workspace.operationState(s) }
        transferEngine.onFinished = { [weak self] srcPane, dstPane in
            guard let self else { return }
            self.reloadPane(srcPane)
            self.reloadPane(dstPane)
            self.updateBars()
        }
        router.onRemoteTransfer = { [weak self] isCopy, src, dst in
            // promptOnMain：runModal 只允许主线程（引擎在后台线程逐文件询问）。
            self?.transferEngine.prompt = TransferEngine.promptOnMain { s, d in
                self?.promptConflict(s, d) ?? .overwrite
            }
            self?.transferEngine.run(isCopy, src, dst)
        }

        // 底部命令栏先建（PaneTableView/SidePaneContainer 需要 commandBar 引用）。
        commandBar = CommandLineBar()

        // 命令栏执行器（T7）：copy/move 复用 router 的传输路径（远端自动走后台）。
        commandExecutor = InternalCommandExecutor(workspace: workspace, engine: engine)
        commandExecutor.onDelete = { [weak self] req in self?.doTrashDelete(pane: req.pane, targets: req.targets) }
        commandExecutor.onConnectSFTP = { [weak self] host, port in
            self?.connectionWindow.setPendingHost(host, port: port)
            self?.beginConnection()
        }
        commandExecutor.onConnectSMB = { [weak self] server, share, user in
            self?.smbConnectionWindow.setPending(server: server, share: share, user: user)
            self?.beginSMBConnection()
        }
        commandExecutor.onOpenTheme = { [weak self] in self?.themeWindow.present() }
        commandExecutor.onNewTab = { [weak self] in self?.newTab() }
        commandExecutor.onCloseTab = { [weak self] in
            guard let self else { return false }
            return closeActiveTab()
        }
        ThemeStore.shared.didChange = { [weak self] in
            guard let self else { return }
            self.leftContainer.allPaneViews.forEach { $0.reload() }
            self.rightContainer.allPaneViews.forEach { $0.reload() }
        }
        workspace.onCommandTransfer = { [weak self] id in self?.router.execute(id) }
        workspace.onCommandStatus = { [weak self] s in self?.setStatus(s) }
        workspace.onCommandView = { [weak self] item in self?.showPreview(item) }
        workspace.onCommandEdit = { [weak self] item in self?.openForEdit(item) }
        workspace.onActiveChange = { [weak self] _ in self?.applyActiveState() }
        workspace.onOperationState = { [weak self] s in self?.operationStateChanged(s) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))

        leftContainer = SidePaneContainer(side: .left)
        rightContainer = SidePaneContainer(side: .right)
        leftContainer.commandBar = commandBar
        rightContainer.commandBar = commandBar
        leftPane.onReload = { [weak self] p in self?.refresh(p) }
        rightPane.onReload = { [weak self] p in self?.refresh(p) }
        leftContainer.addTab(pane: leftPane, workspace: workspace, router: router)
        rightContainer.addTab(pane: rightPane, workspace: workspace, router: router)
        wireTabBar(leftContainer)
        wireTabBar(rightContainer)

        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(leftContainer!)
        splitView.addArrangedSubview(rightContainer!)

        commandBar.onExecute = { [weak self] line in
            guard let self else { return }
            self.commandBar.showOutput(self.commandExecutor.execute(line: line))
        }
        // 命令栏 Enter（执行后）/ Esc（清空后）：焦点交回活动窗格（TC 行为）。
        commandBar.onReturnToPane = { [weak self] in
            guard let self else { return }
            if let av = self.viewOfPane(self.workspace.activePane) {
                self.view.window?.makeFirstResponder(av)
            }
        }
        // cd 下拉补全数据源 = 活动窗格当前目录条目（目录优先由 CdCompletion 排序）。
        commandBar.suggestionProvider = { [weak self] in
            self?.workspace.activePane.itemByID.values.map { $0 } ?? []
        }

        root.addSubview(splitView)
        root.addSubview(commandBar!)
        NSLayoutConstraint.activate([
            commandBar!.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar!.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar!.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: commandBar!.topAnchor),
        ])

        self.view = root
        split = splitView
        split.delegate = self
        // loadView 时机 setPosition 会折叠，延迟到布局后设 50/50（reduced-SDK）。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.split.bounds.width > 0 else { return }
            self.split.setPosition(self.split.bounds.width / 2, ofDividerAt: 0)
        }

        leftPane.load()
        rightPane.load()
        applyActiveState()
        updateBars()

        // 语言切换 → 重刷所有"建一次即常驻"的 UI（整份菜单/列头/命令栏/状态栏）。
        // 回调在 L10n.current 的 setter 内同步触发（菜单动作在主线程 → 重建亦在主线程）。
        l10nToken = L10n.observe { [weak self] in self?.rebuildForLanguage() }
    }

    /// 语言变更后的全量重刷：重建整份主菜单（MainMenu 为纯静态、可重入），
    /// 重设两窗格列头标题，刷新命令栏常驻文案与状态栏。对话框/告警在调用时现取
    /// t()，本就随语言更新，无需在此重绘。Theme/Connection/SMB 窗控制器缓存其 VC，
    /// 未在此重绘（见 task-7 报告后续项）。
    private func rebuildForLanguage() {
        NSApp.mainMenu = MainMenu.build(target: self)
        leftContainer.allPaneViews.forEach { $0.retitileColumns() }
        rightContainer.allPaneViews.forEach { $0.retitileColumns() }
        commandBar!.refreshLocalizedText()
        updateBars()
    }

    private func wireTabBar(_ container: SidePaneContainer) {
        let side = container.side
        container.tabBar.onSwitchTab = { [weak self] i in self?.switchTab(in: side, to: i) }
        container.tabBar.onNewTab = { [weak self] in self?.newTab(in: side) }
        container.tabBar.onCloseTab = { [weak self] i in _ = self?.closeTab(in: side, at: i) }
    }

    /// 窗口的初始第一响应者：左窗格（键盘事件落点），供 window.initialFirstResponder 使用。
    var initialKeyView: NSView {
        leftContainer.activePaneView ?? leftContainer.allPaneViews.first!
    }

    // MARK: - Core callbacks

    /// 操作后刷新窗格：远端源走异步加载（同步 load 会把网络 RTT 卡进主线程）。
    private func reloadPane(_ pane: FilePane) {
        if pane.source.isRemote { pane.loadAsync() } else { pane.load() }
    }

    private func refresh(_ pane: FilePane) {
        guard let pv = viewOfPane(pane) else { return }
        pv.reload()
        // 导航改了 pane.path → 该侧标签条标题须同步（show 依 pane.path 重建标签按钮）；
        // 切侧/切标签/增删走 applyActiveState 时也会 show，此处补上"原地导航"这条路径。
        if pane.id == .left {
            leftContainer.show(tabGroup: workspace.leftTabs, isActiveSide: workspace.active == .left)
        } else {
            rightContainer.show(tabGroup: workspace.rightTabs, isActiveSide: workspace.active == .right)
        }
        updateBars()
    }

    private func viewOfPane(_ pane: FilePane) -> PaneTableView? {
        leftContainer.paneView(pane) ?? rightContainer.paneView(pane)
    }

    private func applyActiveState() {
        let activeSide = workspace.active
        leftContainer.show(tabGroup: workspace.leftTabs, isActiveSide: activeSide == .left)
        rightContainer.show(tabGroup: workspace.rightTabs, isActiveSide: activeSide == .right)
        // 活动窗格 = 键盘目标：core active 变化须同步 AppKit 第一响应者。
        if let av = viewOfPane(workspace.activePane) {
            view.window?.makeFirstResponder(av)
        }
        updateBars()
    }

    // MARK: - Tab 增删 / 切换

    private func newTab(in side: PaneID? = nil) {
        let s = side ?? workspace.active
        let tab = (s == .left) ? workspace.leftTabs : workspace.rightTabs
        let container = (s == .left) ? leftContainer! : rightContainer!
        let pane = FilePane(id: s, source: LocalFileSource(), startPath: Self.startPath)
        tab.add(pane)                                   // core：追加并激活
        pane.onReload = { [weak self] p in self?.refresh(p) }
        container.addTab(pane: pane, workspace: workspace, router: router)
        pane.load()                                     // 本地源同步加载
        applyActiveState()
    }

    @discardableResult
    private func closeTab(in side: PaneID, at index: Int) -> Bool {
        let tab = (side == .left) ? workspace.leftTabs : workspace.rightTabs
        let container = (side == .left) ? leftContainer! : rightContainer!
        guard let removed = tab.close(at: index) else { return false }  // 最后一个标签
        container.removeTab(pane: removed)
        applyActiveState()
        return true
    }

    @discardableResult
    private func closeActiveTab() -> Bool {
        let s = workspace.active
        return closeTab(in: s, at: workspace.activeTab.activeIndex)
    }

    private func switchTab(in side: PaneID, to index: Int) {
        let tab = (side == .left) ? workspace.leftTabs : workspace.rightTabs
        tab.activate(index: index)
        applyActiveState()
    }

    private func operationStateChanged(_ s: OperationState) {
        switch s {
        case .running(let label, let progress): setStatus("\(label) \(Int(progress * 100))%")
        case .done(let m): setStatus(m)
        case .failed(let m): setStatus(L10n.t(.statusErrorPrefix) + m)
        case .idle: setStatus("")
        }
    }

    /// 工具栏右侧的状态文本（操作进度/结果/已选 N 项）。
    private var statusLabel: NSTextField?

    func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    private func updateBars() {
        let a = workspace.activePane
        view.window?.title = a.path.displayString()
        let op = a.selection.operationIDs.count
        statusLabel?.stringValue = op > 0 ? L10n.t(.selectedCount, "\(op)") : ""
    }

    // MARK: - Toolbar wiring

    func attachStatusLabel(_ label: NSTextField) {
        statusLabel = label
        updateBars()
    }

    // MARK: - NSSplitViewDelegate（任一窗格至少 160pt，拖拽/缩放都不会消失）

    func splitView(_ splitView: NSSplitView,
                   constrainSplitPosition proposedPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        let width = splitView.bounds.width
        guard width > 320 else { return proposedPosition }
        return min(max(proposedPosition, 160), width - 160)
    }

    // MARK: - Menu actions（Cmd 组合快捷键的落点）

    @objc func menuNewDirectory(_ sender: Any?) { promptMakeDirectory() }

    @objc func menuRename(_ sender: Any?) { promptRename() }

    @objc func menuTrashDelete(_ sender: Any?) {
        let a = workspace.activePane
        let targets = a.operationTargets
        if !targets.isEmpty { doTrashDelete(pane: a, targets: targets) }
    }

    @objc func menuCopyToOtherPane(_ sender: Any?) { router.execute(.copy) }

    @objc func menuMoveToOtherPane(_ sender: Any?) { router.execute(.move) }

    @objc func menuSearch(_ sender: Any?) { router.execute(.search) }

    @objc func menuConnect(_ sender: Any?) { beginConnection() }

    @objc func menuSMBConnect(_ sender: Any?) { beginSMBConnection() }

    @objc func menuTheme(_ sender: Any?) { themeWindow.present() }

    @objc func menuSelectAll(_ sender: Any?) { router.execute(.selectAll) }

    @objc func menuPreview(_ sender: Any?) {
        if let item = workspace.activePane.focusedItem, !item.isDirectory { showPreview(item) }
    }

    @objc func menuEdit(_ sender: Any?) {
        if let item = workspace.activePane.focusedItem, !item.isDirectory { openForEdit(item) }
    }

    @objc func menuSwitchPane(_ sender: Any?) { router.execute(.switchPane) }

    @objc func menuGoToParent(_ sender: Any?) { router.execute(.parent) }

    @objc func menuNewTab(_ sender: Any?) { newTab() }
    @objc func menuCloseTab(_ sender: Any?) { _ = closeActiveTab() }

    @objc func menuLangEnglish(_ sender: Any?) { L10n.current = .en }
    @objc func menuLangChinese(_ sender: Any?) { L10n.current = .zh }

    // MARK: - AppKit-provided operations

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "csv", "json", "xml", "plist", "ini",
        "swift", "m", "h", "mm", "c", "cpp", "hxx", "py", "js", "ts", "rb",
        "go", "rs", "sh", "zsh", "yml", "yaml", "toml", "html", "css", "sql",
    ]

    private func showPreview(_ item: FileItem) {
        PreviewWindowController.show(item: item)
    }

    private func openForEdit(_ item: FileItem) {
        let url = item.path.url
        if Self.textExtensions.contains(url.pathExtension.lowercased()),
           let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: .init()) { [weak self] _, error in
                if error != nil {
                    DispatchQueue.main.async {
                        if let self, !NSWorkspace.shared.open(url) {
                            self.setStatus(L10n.t(.cannotOpenFile))
                        }
                    }
                }
            }
        } else {
            if !NSWorkspace.shared.open(url) {
                setStatus(L10n.t(.cannotOpenFile))
            }
        }
    }

    private func beginSearch(in root: TCPath, source: FileSource) {
        searchWindow.onOperation = { [weak self] state in self?.workspace.operationState(state) }
        searchWindow.present(root: root, source: source) { [weak self] hit in
            guard let self else { return }
            let pane = self.workspace.activePane
            if hit.isDirectory {
                pane.navigate(to: hit.path)
            } else if let parent = hit.path.parent {
                pane.navigate(to: parent)
            }
            pane.revealItem(id: hit.path.pathString)
        }
    }

    /// 打开 SFTP 连接窗；成功后在活动侧开新标签接到远端源（远端 home 目录），
    /// 不覆盖当前活动标签。
    private func beginConnection() {
        connectionWindow.onConnected = { [weak self] source, home in
            guard let self else { return }
            let side = self.workspace.active
            let tab = (side == .left) ? self.workspace.leftTabs : self.workspace.rightTabs
            let container = (side == .left) ? self.leftContainer! : self.rightContainer!
            let path = SFTPSource.tcPath(host: source.config.host,
                                         port: Int(source.config.port),
                                         remotePath: home)
            let pane = FilePane(id: side, source: source, startPath: path)
            tab.add(pane)                                   // 新标签（保留当前活动标签）
            pane.onReload = { [weak self] p in self?.refresh(p) }
            container.addTab(pane: pane, workspace: self.workspace, router: self.router)
            pane.loadAsync()                                // 远端后台加载
            self.applyActiveState()
        }
        connectionWindow.present()
    }

    /// 打开 SMB 连接窗；成功后在活动侧开新标签接到 SMB 源（share 根）。
    private func beginSMBConnection() {
        smbConnectionWindow.onConnected = { [weak self] source, home in
            guard let self else { return }
            let side = self.workspace.active
            let tab = (side == .left) ? self.workspace.leftTabs : self.workspace.rightTabs
            let container = (side == .left) ? self.leftContainer! : self.rightContainer!
            let pane = FilePane(id: side, source: source, startPath: home)
            tab.add(pane)                                   // 新标签（保留当前活动标签）
            pane.onReload = { [weak self] p in self?.refresh(p) }
            container.addTab(pane: pane, workspace: self.workspace, router: self.router)
            pane.loadAsync()                                // 远端后台加载
            self.applyActiveState()
        }
        smbConnectionWindow.present()
    }

    private func promptRename() {
        guard let item = workspace.activePane.focusedItem else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t(.renameTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.okBtn))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.rename(to: field.stringValue)
        }
    }

    private func promptMakeDirectory() {
        let alert = NSAlert()
        alert.messageText = L10n.t(.newDirTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.createBtn))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.makeDirectory(named: field.stringValue)
        }
    }

    private func promptConflict(_ src: TCPath, _ dst: TCPath) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = L10n.t(.conflictTitle)
        alert.informativeText = L10n.t(.conflictQuestion, dst.fileName)
        alert.addButton(withTitle: L10n.t(.overwrite))
        alert.addButton(withTitle: L10n.t(.skip))
        alert.addButton(withTitle: L10n.t(.overwriteAll))
        alert.addButton(withTitle: L10n.t(.skipAll))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .overwriteAll
        case NSApplication.ModalResponse(rawValue: 1003): return .skipAll
        default: return .cancel
        }
    }

    private func doTrashDelete(pane: FilePane, targets: [FileItem]) {
        // 远端无废纸篓：确认后直接删（后台执行，主线程不阻塞）。
        if pane.source.isRemote {
            doRemoteDelete(pane: pane, targets: targets)
            return
        }
        if targets.count > 1 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.t(.trashConfirm, "\(targets.count)")
            alert.addButton(withTitle: L10n.t(.deleteWord))
            alert.addButton(withTitle: L10n.t(.cancelBtn))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        let urls = targets.map { $0.path.url }
        NSWorkspace.shared.recycle(urls) { [weak self] _, _ in
            DispatchQueue.main.async {
                pane.load()
                self?.workspace.operationState(.done("已删除 \(targets.count) 个文件"))
            }
        }
    }

    /// 远端删除：确认（"无法恢复"）→ 后台 performDelete（引擎 source.removeItem 递归）。
    private func doRemoteDelete(pane: FilePane, targets: [FileItem]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.remoteDeleteConfirm, "\(targets.count)")
        alert.informativeText = L10n.t(.remoteNoTrash)
        alert.addButton(withTitle: L10n.t(.deleteWord))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        if alert.runModal() != .alertFirstButtonReturn { return }

        let source = pane.source
        let engine = self.engine
        let state = { [weak self] s in self?.workspace.operationState(s) }
        state(.running(label: "删除 \(targets.count) 个文件", progress: 0))
        // 系统预建全局队列执行（不新建 DispatchQueue——SDK 约束）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do { try engine.performDelete(targets, source: source); result = .success(()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    state(.done("已删除 \(targets.count) 个文件"))
                case .failure(let error):
                    state(.failed((error as? TCError)?.message ?? error.localizedDescription))
                }
                self?.reloadPane(pane)
            }
        }
    }
}
