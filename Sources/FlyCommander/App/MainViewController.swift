import AppKit
import TCCore

final class MainViewController: NSViewController, NSSplitViewDelegate, NSMenuItemValidation {
    // 隐式解包：本工具链禁止在 loadView 里直接给 `let` 存储属性赋值
    // （workspace/viewOfPane 为 internal 而非 private：接线测试需经 @testable 访问）
    var workspace: Workspace!
    // router 为 internal 而非 private：UICrossCopyDemo.swift（#if DEBUG）跨文件扩展需触发 .copy。
    var router: CommandRouter!
    /// internal 而非 private：F2 钩子在另一文件的 extension（MainViewController+Favorites）
    /// 里需按 pane.id 还原容器；private 是文件作用域跨不过去（favoritesStore 同因）。
    var leftContainer: SidePaneContainer!
    var rightContainer: SidePaneContainer!
    private var split: NSSplitView!
    private let searchWindow = SearchWindowController()
    /// 统一连接窗：executors 注入接线适配层（SFTP 的 home:String→TCPath 转换在此侧）。
    private let connectionWindow: ConnectionWindowController = {
        let wc = ConnectionWindowController()
        wc.executors = RemoteConnectExecutors.defaults
        return wc
    }()
    private let themeWindow = ThemeWindowController()
    /// 更新流程（checker→窗→installer 编排；单窗复用，AppDelegate 首检共用同一入口）。
    let updateFlow = UpdateFlow()
    private var transferEngine: TransferEngine!
    /// T3：进度面板生命周期旗——presentTransfer 置位，终态（done/failed/idle）复位。
    /// 旁路门控：只有为 true 时 OperationState 终态才喂面板（搜索/删除的 done 不误关）。
    private var transferPanelActive = false
    /// 隐藏文件全局开关（⌘⇧.）：持久缺省 false=隐藏（Finder 习惯；行为变更经用户确认）。
    /// 必须用 `bool(forKey:)` 而非 `object as? Bool`：launchArguments 的
    /// `-showHiddenFiles YES` 落成**字符串** "YES"，`as? Bool` 转不动会静默落缺省
    /// （XCUITest 定态靠这条路）；bool(forKey:) 认 "YES"/"NO" 等串。写侧 set(Bool)。
    /// 传播与注入点 = `wirePaneCallbacks`（覆盖 loadView 两初生 pane 与全部新建路）。
    private var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: "showHiddenFiles")
    private var commandBar: CommandLineBar!
    /// 底部常驻状态栏（与命令栏同槽 34pt，isHidden 互换；见 BottomStatusBar 头注释）。
    private var bottomStatus: BottomStatusBar!
    /// 命令栏当前是否占着底部槽位（内部测试/变异锁读点）。
    private(set) var isCommandLineVisible = false
    private var commandExecutor: InternalCommandExecutor!
    /// router（本地快路径/元操作）与 transferEngine（远端传输）共用同一引擎，保证语义一致。
    private let engine = OperationEngine()
    /// L10n 观察者 token（单例生命周期，永久保留；切换时重刷常驻 UI）。
    private var l10nToken: Int?
    /// 主窗控制器弱引用（语言切换时重刷工具栏 label；强引用会成循环——window 持 contentVC）。
    private weak var mainWindowController: MainWindowController?

    /// 会话记忆（左右窗格目录 + 活动侧）的持久化门面；可注入（单测/UI 测试用独立 suite）。
    private let sessionStore: SessionStore
    /// 目录收藏夹（internal 而非 private：Favorites 分支在另一文件的 extension 里，
    /// private 是文件作用域跨不过去）。注入点同 sessionStore——测试用空 suite 隔离真实偏好。
    let favoritesStore: DirectoryFavoritesStore
    /// 收藏下拉的呈现口（缺省 = 真 `menu.popUp`；测试注入假实现断言「F2 链弹了对的那一侧」）。
    /// 必须声明在主类而非 Favorites extension：Swift 的 extension 不许有存储属性。
    /// 之所以要这层接缝：popUp 是嵌套跟踪循环，headless 直接触发会阻塞整条测试。
    var favoritesMenuPresenter: ((SidePaneContainer, NSMenu) -> Void)?
    /// 启动期在 loadView 创建，此后恒非 nil。
    private var recorder: SessionRecorder!
    /// 是否允许写回记忆：显式起始目录 / 参数域禁用 / 注入快照时关闭。
    private var recordingEnabled = false
    /// 启动期初始 load 进行中：避免把"正在恢复"当作用户操作写回。
    private var isRestoring = false

    /// 目录外部变更自动刷新中枢（每窗格一 FSEvents 流）。工厂可注入（单测塞假源）。
    /// internal 而非 private：AppDelegate 的 didBecomeActive 兜底要调 refreshAllWatched。
    let directoryWatcher: DirectoryWatchCoordinator

    /// AppDelegate 建窗后注入回链。
    func attachMainWindowController(_ wc: MainWindowController) { mainWindowController = wc }

    init(sessionStore: SessionStore = .shared,
         favoritesStore: DirectoryFavoritesStore = .shared,
         watcherFactory: DirectoryEventSourceFactory = FSEventsDirectorySourceFactory()) {
        self.sessionStore = sessionStore
        self.favoritesStore = favoritesStore
        self.directoryWatcher = DirectoryWatchCoordinator(factory: watcherFactory)
        super.init(nibName: nil, bundle: nil)
    }

    /// 显式起始目录：`--start-dir <路径>` 参数优先，其次 FLY_START_DIR 环境变量
    /// （供 UI 测试指向已知夹具目录）；空串/缺值一律忽略并回落下一来源，最终 nil。
    static func explicitStartPath(arguments: [String], environment: [String: String]) -> String? {
        if let i = arguments.firstIndex(of: "--start-dir"), i + 1 < arguments.count,
           !arguments[i + 1].isEmpty {
            return arguments[i + 1]
        }
        if let dir = environment["FLY_START_DIR"], !dir.isEmpty { return dir }
        return nil
    }

    /// 启动目录：显式起始目录优先，缺省为用户主目录。
    static var startPath: TCPath {
        TCPath(explicitStartPath(arguments: CommandLine.arguments,
                                 environment: ProcessInfo.processInfo.environment) ?? "~")
    }

    /// 启动期目录探测（启动路径上唯一的 IO）：能列出即视为可用，否则由 SessionRestore
    /// 逐级上溯。已删除/无权限/被卸载的目录都走这条降级路，绝不抛到调用方。
    private static func localDirectoryProbe(_ s: String) -> Bool {
        let p = TCPath(s)
        guard !p.isRemote else { return false }
        return (try? LocalFileSource().listDirectory(p)) != nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        // 启动决策（纯函数 + 一次快照读取，无网络、无阻塞）：显式起始目录 > 注入快照
        // （UI 测试）> 恢复快照 > 默认 ~。候选不可用则由 SessionRestore 逐级上溯。
        let explicit = Self.explicitStartPath(arguments: CommandLine.arguments,
                                              environment: ProcessInfo.processInfo.environment)
        let restore = SessionPolicy.restoreEnabled(
            explicitStartPath: explicit,
            argumentDisabled: SessionStore.disabledByArgumentDomain)
        let injected = SessionStore.injectedSnapshot()
        let hasInjected = SessionStore.hasInjectedSnapshot
        recordingEnabled = SessionPolicy.recordingEnabled(restoreEnabled: restore,
                                                          hasInjectedSnapshot: hasInjected)
        let snapshot = SessionPolicy.snapshotToUse(restoreEnabled: restore,
                                                   hasInjectedSnapshot: hasInjected,
                                                   injected: injected, stored: sessionStore.snapshot)
        let fallback = explicit ?? "~"
        let leftResolved: String
        let rightResolved: String
        if let snapshot = snapshot {
            leftResolved = SessionRestore.resolve(candidate: snapshot.leftPath, fallback: fallback,
                                                  probe: Self.localDirectoryProbe)
            rightResolved = SessionRestore.resolve(candidate: snapshot.rightPath, fallback: fallback,
                                                   probe: Self.localDirectoryProbe)
        } else {
            leftResolved = fallback
            rightResolved = fallback
        }
        // candidate 传快照原始串（含 nil），**不是** fallback——degraded 语义靠它守护。
        recorder = SessionRecorder(startups: [
            .left: SessionRecorder.SideStartup(resolved: leftResolved, candidate: snapshot?.leftPath),
            .right: SessionRecorder.SideStartup(resolved: rightResolved, candidate: snapshot?.rightPath),
        ])

        let source = LocalFileSource()
        let leftPane = FilePane(id: .left, source: source, startPath: TCPath(leftResolved))
        let rightPane = FilePane(id: .right, source: source, startPath: TCPath(rightResolved))
        workspace = Workspace(left: TabGroup(side: .left, panes: [leftPane]),
                              right: TabGroup(side: .right, panes: [rightPane]),
                              active: snapshot?.active == "right" ? .right : .left)

        router = CommandRouter(workspace: workspace, engine: engine)
        router.conflictPrompt = { [weak self] src, dst in self?.promptConflict(src, dst) ?? .overwrite }
        router.onDelete = { [weak self] pane, targets in self?.doTrashDelete(pane: pane, targets: targets) }
        router.onView = { [weak self] item in self?.showPreview(item) }
        router.onEdit = { [weak self] item in self?.openForEdit(item) }
        // 回车/双击落在文件上：默认程序打开（远端先下载到本地缓存，后台）。
        router.onOpen = { [weak self] item in self?.openWithDefault(item) }
        router.onSearch = { [weak self] root, source in self?.beginSearch(in: root, source: source) }
        wireFavorites()   // F2（openFavoritesMenu）→ 弹活动侧收藏下拉，切换收藏经菜单内建项
        // 警告成品串（"源端残留：X（…）"）在本地化边界组装——内核只给 (文件名, TCError)。
        router.warnFormatter = { name, err in L10n.t(.warnSourceLeftover, name, tcErrorDisplay(err)) }

        // 远端传输：router 检测到任一端 isRemote 时委托后台执行器（主线程不冻结）。
        transferEngine = TransferEngine(engine: engine)
        // T3：传输器自己的 state 通道喂进度面板（终态收口）——**只挂在这里**而非
        // workspace 全局通道，搜索/删除等其它 OperationState 来源不会误触面板。
        transferEngine.state = { [weak self] s in
            guard let self else { return }
            self.workspace.operationState(s)
            guard self.transferPanelActive else { return }
            switch s {
            case .done, .failed:
                TransferProgressWindowController.shared.finish(state: s)
            default:
                break   // idle 不裁决（冲突取消也报 idle）——收口交给 onFinished
            }
        }
        transferEngine.onFinished = { [weak self] srcPane, dstPane in
            guard let self else { return }
            // 无条件收尾：done/failed 已 finish 过（ended 幂等），这里只会关掉残留 = 取消路径。
            if self.transferPanelActive {
                self.transferPanelActive = false
                TransferProgressWindowController.shared.finishCancelled()
            }
            self.reloadPane(srcPane)
            self.reloadPane(dstPane)
            self.updateBars()
        }
        router.onRemoteTransfer = { [weak self] isCopy, src, dst in
            guard let self else { return }
            // promptOnMain：runModal 只允许主线程（引擎在后台线程逐文件询问）。
            self.transferEngine.prompt = TransferEngine.promptOnMain { s, d in
                self.promptConflict(s, d) ?? .overwrite
            }
            // T3：进度面板 + 取消旗（per-run；面板经 state 旁路收终态）。
            let targets = src.operationTargets
            guard !targets.isEmpty else { return }
            let cancel = CancelFlag()
            TransferProgressWindowController.shared
                .presentTransfer(isCopy: isCopy, fileTotal: targets.count, cancel: cancel)
            self.transferPanelActive = true
            self.transferEngine.run(isCopy, src, dst, cancel: cancel) { [weak self] info in
                guard let self, self.transferPanelActive else { return }
                TransferProgressWindowController.shared.apply(info)
            }
        }

        // 底部命令栏先建（PaneTableView/SidePaneContainer 需要 commandBar 引用）。
        commandBar = CommandLineBar()
        bottomStatus = BottomStatusBar()

        // 命令栏执行器（T7）：copy/move 复用 router 的传输路径（远端自动走后台）。
        commandExecutor = InternalCommandExecutor(workspace: workspace, engine: engine)
        commandExecutor.onDelete = { [weak self] req in self?.doTrashDelete(pane: req.pane, targets: req.targets) }
        commandExecutor.onConnectSFTP = { [weak self] host, port in
            self?.beginConnection(proto: .sftp, host: host, port: port.map(Int.init))
        }
        commandExecutor.onConnectSMB = { [weak self] server, share, user in
            self?.beginConnection(proto: .smb, server: server, share: share, user: user)
        }
        commandExecutor.onConnectFTP = { [weak self] host, port in
            self?.beginConnection(proto: .ftp, host: host, port: port.map(Int.init))
        }
        commandExecutor.onOpenTheme = { [weak self] in self?.themeWindow.present() }
        commandExecutor.onCheckUpdate = { [weak self] in self?.updateFlow.check(manual: true) }
        commandExecutor.onNewTab = { [weak self] in self?.newTab() }
        commandExecutor.onCloseTab = { [weak self] in
            guard let self else { return false }
            return closeActiveTab()
        }
        ThemeStore.shared.didChange = { [weak self] in
            guard let self else { return }
            self.leftContainer.allPaneViews.forEach { $0.reload() }
            self.rightContainer.allPaneViews.forEach { $0.reload() }
            // tab 激活底色是 rebuild 时定格进 layer 的 accent CGColor——只 reload 表格
            // 不重画标签条，改主题后活动 tab 留旧色直到下次导航（评审 wf_855e5db8 confirmed）。
            // applyActiveState=正规幂等入口（双侧 show→tabBar.rebuild 现取新 accent）。
            self.applyActiveState()
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
        wirePaneCallbacks(leftPane)
        wirePaneCallbacks(rightPane)
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
            let out = self.commandExecutor.execute(line: line)
            self.commandBar.showOutput(out)
            // 回显镜像到状态栏：命令栏执行/取消后即收回，回显须活在常驻栏里
            //（UI 测试的 cmdBarOutput 读点也已迁到 bottomStatusMessage）。
            self.bottomStatus.showMessage(out)
        }
        // 命令栏与状态栏同槽互换：activate() 第一时间换出命令栏（先显示后聚焦，
        // 隐藏视图拿不到第一响应者）；输入框失焦（回车/Esc/点行/切标签…一切回焦路径
        // 的共同终点）收回。幂等守卫在 setCommandLineVisible 内（自隐递归靠它挡）。
        commandBar.onActivate = { [weak self] in self?.setCommandLineVisible(true) }
        commandBar.onResignFocus = { [weak self] in self?.setCommandLineVisible(false) }
        // Esc 取消：连状态栏里的回显镜像一起清（回车/点行收回不清——回显留到下次命令）。
        commandBar.onCleared = { [weak self] in self?.bottomStatus.showMessage(nil) }
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
        root.addSubview(bottomStatus!)
        root.addSubview(commandBar!)
        // 底部同槽：splitView 底 = root 底 −34（固定），命令栏与状态栏都钉 root 底，
        // isHidden 互换——每次唤出/收回零约束改写、splitView 不重排（分隔条不抖）。
        // 两栏终身在层级里：removeFromSuperview 会让 commandBar.activate 的
        // `guard let win = window` 静默失败（右箭头失效）。
        NSLayoutConstraint.activate([
            commandBar!.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar!.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar!.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bottomStatus!.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomStatus!.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomStatus!.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            splitView.topAnchor.constraint(equalTo: root.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -BottomStatusBar.height),
        ])
        commandBar!.isHidden = true        // 默认隐藏命令行（用户定档），状态栏常驻
        bottomStatus!.isHidden = false

        self.view = root
        split = splitView
        split.delegate = self
        // loadView 时机 setPosition 会折叠，延迟到布局后设 50/50（reduced-SDK）。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.split.bounds.width > 0 else { return }
            self.split.setPosition(self.split.bounds.width / 2, ofDividerAt: 0)
        }

        // 恢复期的初始 load：包在 isRestoring 里，避免把恢复本身当用户操作写回记忆。
        isRestoring = true
        leftPane.load()
        rightPane.load()
        applyActiveState()
        updateBars()
        isRestoring = false

        // 语言切换 → 重刷所有"建一次即常驻"的 UI（整份菜单/列头/命令栏/状态栏）。
        // 回调在 L10n.current 的 setter 内同步触发（菜单动作在主线程 → 重建亦在主线程）。
        l10nToken = L10n.observe { [weak self] in self?.rebuildForLanguage() }

        #if DEBUG
        // UI 测试钩子（FLY_UI_DEMO=crossCopy 才动）：见 UICrossCopyDemo.swift。
        DispatchQueue.main.async { [weak self] in self?.maybeStartUICrossCopyDemo() }
        #endif
    }

    /// 语言变更后的全量重刷：重建整份主菜单（MainMenu 为纯静态、可重入），
    /// 重设两窗格列头标题，刷新命令栏常驻文案与状态栏。对话框/告警在调用时现取
    /// t()，本就随语言更新，无需在此重绘。Theme/Connection/Search 三个常驻窗口
    /// 缓存其 VC、标签在 loadView 冻结，故各经其 WindowController 就地重刷（含窗口标题）；
    /// 预览窗（第五个常驻单例，首次预览才建）经 PreviewWindowController 的可选单例短路——
    /// 从未预览过时 _shared 为 nil，重刷不建窗、绝不 showWindow（未显示的窗口不被弹出）。
    private func rebuildForLanguage() {
        NSApp.mainMenu = MainMenu.build(target: self)
        leftContainer.allPaneViews.forEach { $0.retitleColumns() }
        rightContainer.allPaneViews.forEach { $0.retitleColumns() }
        // 标签条 ×/＋ tooltip 在 tabBar.rebuild 里冻结——show 是其正规入口
        // （幂等：tab title=路径非本地化串；可见性/边框/选中态按现状态原样重设）。
        leftContainer.show(tabGroup: workspace.leftTabs, isActiveSide: workspace.active == .left)
        rightContainer.show(tabGroup: workspace.rightTabs, isActiveSide: workspace.active == .right)
        commandBar!.refreshLocalizedText()
        bottomStatus!.refreshLocalizedText()
        mainWindowController?.refreshLocalizedLabels()
        searchWindow.refreshLocalizedText()
        connectionWindow.refreshLocalizedText()
        themeWindow.refreshLocalizedText()
        PreviewWindowController.refreshLocalizedTextIfCreated()
        TransferProgressWindowController.refreshLocalizedTextIfCreated()
        UpdateWindowController.refreshLocalizedTextIfCreated()
        updateBars()
    }

    private func wireTabBar(_ container: SidePaneContainer) {
        let side = container.side
        container.tabBar.onSwitchTab = { [weak self] i in self?.switchTab(in: side, to: i) }
        container.tabBar.onNewTab = { [weak self] in self?.newTab(in: side) }
        container.tabBar.onCloseTab = { [weak self] i in _ = self?.closeTab(in: side, at: i) }
        container.tabBar.onFavorites = { [weak self] in self?.showFavoritesDropdown(in: container) }
    }

    /// 窗口的初始第一响应者：**活动侧**当前标签的窗格，供 window.initialFirstResponder 使用。
    /// 必须按 workspace.active 取：loadView 期的 makeFirstResponder 因 window==nil 是 no-op，
    /// 恢复会话后活动侧可能是右——若恒取左，会出现"方向键动左窗格、F5/回车动右窗格"的脑裂。
    var initialKeyView: NSView {
        viewOfPane(workspace.activePane) ?? leftContainer.activePaneView ?? leftContainer.allPaneViews.first!
    }

    // MARK: - Core callbacks

    /// 每个 FilePane 的两条刷新路统一在此接（loadView/newTab/连接建标签共用）：
    /// onReload = 内容变了（列表/导航）走全量；onSelectionChange = 只焦点/标记变了
    /// 走快路（局部重绘 + 同步滚动，不重排 sortedIDs、不重建标签条）。
    private func wirePaneCallbacks(_ pane: FilePane) {
        // 隐藏文件开关的唯一注入点：全部 pane 创建路（loadView 两初生 / newTab /
        // SFTP 连接 / SMB 连接）都经这里，新 pane 必继承当前全局态。
        pane.showHidden = showHiddenFiles
        // onReload 尾 = 自动刷新的生命周期单挂点：注册/换路径/注销三合一在此
        // （navigate/setSource/断连回退的终点必是 load→onReload）。同路径 no-op → 不成环。
        pane.onReload = { [weak self] p in self?.refresh(p); self?.directoryWatcher.noteReloaded(p) }
        pane.onSelectionChange = { [weak self] p in
            guard let self else { return }
            self.viewOfPane(p)?.refreshSelection()
            self.updateBars()
        }
    }

    /// 操作后刷新窗格：远端源走异步加载（同步 load 会把网络 RTT 卡进主线程）。
    private func reloadPane(_ pane: FilePane) {
        if pane.source.isRemote { pane.loadAsync() } else { pane.load() }
    }

    private func refresh(_ pane: FilePane) {
        // 首条：导航/刷新即更新记忆。后台标签 reload 也走此路，但记录的是该侧**活动**标签。
        recordSessionIfChanged()
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

    /// internal（非 private）：接线测试经 @testable 访问，验证"记录的是活动标签"。
    func viewOfPane(_ pane: FilePane) -> PaneTableView? {
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
        recordSessionIfChanged()   // 末条：活动侧变化也要落盘
    }

    /// 把两侧**活动标签**的当前目录写回记忆（相等则 saveIfChanged 静默跳过）。
    /// 用 workspace.<side>Tabs.activePane 而非回调传入的 pane：后台标签的 reload
    /// 不得污染记忆（记的是该侧活动标签的目录，不是刚加载完的那个后台标签）。
    private func recordSessionIfChanged() {
        guard recordingEnabled, !isRestoring else { return }
        let left = workspace.leftTabs.activePane
        let right = workspace.rightTabs.activePane
        let snap = SessionSnapshot(
            version: 1,
            leftPath: recorder.valueToRecord(side: .left, current: left.path.pathString,
                                             isRemote: left.source.isRemote),
            rightPath: recorder.valueToRecord(side: .right, current: right.path.pathString,
                                              isRemote: right.source.isRemote),
            active: workspace.active == .left ? "left" : "right")
        sessionStore.saveIfChanged(snap)
    }

    // MARK: - Tab 增删 / 切换

    /// 新标签继承**该侧当前标签的目录**（TC 行为）。用当前目录而非 `startPath` 不只是手感：
    /// 会话恢复的 degraded 侧（候选目录不可用、已上溯到祖先）若开新标签落回 `~`，随后的
    /// 记录就会把真实记忆覆盖成 `~`——继承当前目录则 `current == resolved`，degraded 保护成立。
    /// 远端标签的路径不是本地路径（SMB 的 `/share/dir` 与本地无法区分），故回落默认起始目录。
    /// internal（非 private）供接线测试直接驱动：`@testable` 可见，仅模块内。
    func newTab(in side: PaneID? = nil) {
        let s = side ?? workspace.active
        let tab = (s == .left) ? workspace.leftTabs : workspace.rightTabs
        let container = (s == .left) ? leftContainer! : rightContainer!
        let current = tab.activePane
        let startPath = current.source.isRemote ? Self.startPath : current.path
        let pane = FilePane(id: s, source: LocalFileSource(), startPath: startPath)
        tab.add(pane)                                   // core：追加并激活
        wirePaneCallbacks(pane)
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
        directoryWatcher.stopWatching(removed)   // 关标签 = 注销其 FSEvents 流
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
        setStatus(Self.statusText(for: s) ?? "")
    }

    /// OperationState → 状态栏成品串（Plan B：唯一的文案组装边界）。
    ///
    /// 纯函数（无 UI 依赖）故可直接单测。`opCopying`/`opMoving` 是"进度标签"，
    /// done 时套 `statusDone`/`statusDoneWarn` 成 "X 完成"；`opRenameDone`/`opMkdirDone`/
    /// `opDeleteDone`/`opSearchDone` 本身就是成品句（"已重命名"…），逐字显示不再套"完成"。
    /// `warningLines` 已是成品串（`warnFormatter`/TransferEngine 组装），此处只负责 join + ⚠。
    /// 返回 nil = 无内容（idle），调用方清空状态栏。
    static func statusText(for s: OperationState) -> String? {
        switch s {
        case .idle:
            return nil
        case .running(let label, let args, let progress):
            return L10n.t(.statusRunning, args: [L10n.t(label, args: args), "\(Int(progress * 100))"])
        case .done(let label, let args, let warningLines):
            let expanded = L10n.t(label, args: args)
            let base = Self.appendCompleteLabels.contains(label) ? L10n.t(.statusDone, expanded) : expanded
            guard !warningLines.isEmpty else { return base }
            return L10n.t(.statusDoneWarn, args: [base, warningLines.joined(separator: L10n.t(.statusWarnJoin))])
        case .failed(let error):
            // 前缀只在这里给（statusErrorPrefix）：`errUnknown` 模板是裸 {0}，
            // 语义 case 自带 "Not found: " 等英文/中文前缀，状态栏单层前缀不叠字。
            return L10n.t(.statusErrorPrefix) + tcErrorDisplay(error)
        }
    }

    /// done 时需要再套"X 完成"模板的标签键（其余 done 标签本身即成品句）。
    /// internal（非 private）：暴露给结构守卫测，锁"成品句误投"不变量。
    static let appendCompleteLabels: Set<L10nKey> = [.opCopying, .opMoving]

    /// 工具栏右侧的状态文本（操作进度/结果/已选 N 项）。
    private var statusLabel: NSTextField?

    func setStatus(_ text: String) {
        statusLabel?.stringValue = text
    }

    private func updateBars() {
        let a = workspace.activePane
        view.window?.title = a.path.displayString()
        // operationTargets（可见感知）：筛选无命中时 marked 已被内核剪空、focusID 仍指向
        // 隐藏项，operationIDs 会回退成 [focusID]——用它状态栏会谎报「已选 1 项」。
        let op = a.operationTargets.count
        statusLabel?.stringValue = op > 0 ? L10n.t(.selectedCount, "\(op)") : ""
        updateBottomStatus(for: a)
    }

    /// 底部状态栏内容刷新（工具栏行的既有语义逐字节不动，这里只喂底部）。
    /// 多选门禁 = `selection.marked` 非空：`operationIDs` 无标记时回退 [focusID]
    ///（SelectionModel.swift:43），纯焦点会被它误报「已选 1 项」。
    private func updateBottomStatus(for a: FilePane) {
        if a.selection.marked.isEmpty {
            let line = a.focusedItem.map(Self.statusLine) ?? L10n.t(.statusEmptyPane)
            bottomStatus?.show(fileInfo: line, selectionInfo: nil)
        } else {
            let targets = a.operationTargets   // 可见感知（筛选隐藏的不计）
            guard !targets.isEmpty else {     // 全被筛掉：无可报，清左栏（工具栏同款教训）
                bottomStatus?.show(fileInfo: "", selectionInfo: nil)
                return
            }
            let bytes = targets.reduce(Int64(0)) { $0 &+ max(0, $1.size) }
            bottomStatus?.show(fileInfo: "", selectionInfo: L10n.t(
                .statusSelectedTotal, "\(targets.count)",
                ByteCountFormatter().string(fromByteCount: bytes)))
        }
    }

    /// 焦点文件行文案：「名 · 大小/文件夹 · 日期」。目录不给字节（对齐 FileCellView
    /// 大小列对目录留空的既有约定）。纯函数便于单测。
    static func statusLine(_ item: FileItem) -> String {
        let sizePart = item.isDirectory
            ? L10n.t(.statusFolder)
            : ByteCountFormatter().string(fromByteCount: max(0, item.size))
        return [item.name, sizePart, L10n.localized(date: item.modificationDate)]
            .joined(separator: " · ")
    }

    /// 命令栏 ↔ 状态栏同槽互换的唯一收口。幂等守卫兼重入守卫：收回命令栏时
    /// 输入框随父视图隐藏会再触发一次 resignFirstResponder → 回调自指，靠守卫挡回。
    func setCommandLineVisible(_ show: Bool) {
        guard isCommandLineVisible != show else { return }
        isCommandLineVisible = show
        commandBar?.isHidden = !show
        bottomStatus?.isHidden = show
        if !show { updateBars() }   // 收回瞬间让焦点行回位
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

    /// ⌃R：手动重载活动窗格当前目录（外部改文件的兜底入口）。路由到 TCCore 的
    /// `.refresh` → reloadPane（本地同步 load / 远端 loadAsync），焦点/标记/筛选保留。
    @objc func menuRefresh(_ sender: Any?) { router.execute(.refresh) }

    /// ⌘⇧F：展开/收起活动窗格的筛选行（与标签条右端常驻按钮同一入口）。
    @objc func menuFilter(_ sender: Any?) {
        viewOfPane(workspace.activePane)?.toggleFilterRow()
    }

    /// ⌘⇧.：切换隐藏文件（全局两窗格同步）。逐 pane 赋 showHidden——FilePane didSet
    /// 自带可见集重算 + 剪枝/重定位 + 快路回调，视图刷新不需要额外全量路。
    /// 菜单 ✓ 走 validateMenuItem（打开菜单时按当前态刷新，仿语言子菜单）。
    @objc func menuToggleHidden(_ sender: Any?) {
        showHiddenFiles.toggle()
        // UI 测试模式抑制落盘（真窗 ⌘⇧. 用例不污染开发者偏好；内存态照常传播）。
        if !TestIsolation.suppressPreferenceWrites {
            UserDefaults.standard.set(showHiddenFiles, forKey: "showHiddenFiles")
        }
        for pane in workspace.leftTabs.panes + workspace.rightTabs.panes {
            pane.showHidden = showHiddenFiles
        }
        // 快路（showHidden didSet 只发 onSelectionChange 不发 onReload）下视图不知内核可见集
        // 变了——必须像语言切换那样手动重投影：visibleItemIDs 已重算，视图 reload 才见 dotfile
        // 增删。漏这步 = 表格停留在旧可见集（真窗实测：开后 .hidden 不现身）。
        leftContainer.allPaneViews.forEach { $0.reload() }
        rightContainer.allPaneViews.forEach { $0.reload() }
        setStatus(L10n.t(showHiddenFiles ? .hiddenFilesShown : .hiddenFilesHidden))
    }

    // NSMenuItemValidation 协议方法（非 override）：打开菜单时刷 ✓（仿语言子菜单当前态）。
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(menuToggleHidden(_:)) {
            menuItem.state = showHiddenFiles ? .on : .off
        }
        return true
    }

    /// 打开统一「连接到远端」窗；成功后在活动侧开新标签接到远端源（远端 home 目录），
    /// 不覆盖当前活动标签。proto=nil=表单当前协议（缺省 SFTP）；其余参数为预填。
    private func beginConnection(proto: RemoteProto? = nil, host: String? = nil, port: Int? = nil,
                                 server: String? = nil, share: String? = nil, user: String? = nil) {
        connectionWindow.setPending(proto: proto, host: host, port: port,
                                    server: server, share: share, user: user)
        connectionWindow.onConnected = { [weak self] source, home in
            guard let self else { return }
            let side = self.workspace.active
            let tab = (side == .left) ? self.workspace.leftTabs : self.workspace.rightTabs
            let container = (side == .left) ? self.leftContainer! : self.rightContainer!
            let pane = FilePane(id: side, source: source, startPath: home)
            tab.add(pane)                                   // 新标签（保留当前活动标签）
            wirePaneCallbacks(pane)
            container.addTab(pane: pane, workspace: self.workspace, router: self.router)
            pane.loadAsync()                                // 远端后台加载
            self.applyActiveState()
        }
        connectionWindow.present()
    }

    @objc func menuConnect(_ sender: Any?) { beginConnection() }

    @objc func menuTheme(_ sender: Any?) { themeWindow.present() }

    @objc func menuCheckUpdate(_ sender: Any?) { updateFlow.check(manual: true) }

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

    /// 回车/双击/右键"打开"：本地直接交默认程序；远端先下载到本地缓存（后台，
    /// 不卡主线程），落到 Caches 临时件后再打开。缓存按 (源, 路径, 大小, mtime)
    /// 命名，命中即复用，避免重复下载。
    private func openWithDefault(_ item: FileItem) {
        let source = workspace.activePane.source
        if !source.isRemote {
            if !NSWorkspace.shared.open(item.path.url) { setStatus(L10n.t(.cannotOpenFile)) }
            return
        }
        setStatus(L10n.t(.remoteDownloading))
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlyCommander.Remote", isDirectory: true)
        let stamp = Int(item.modificationDate.timeIntervalSince1970)
        let key = "\(source.sourceID)|\(item.path.pathString)|\(item.size)|\(stamp)"
        let digest = String(key.utf8.map { String(format: "%02x", $0) }.joined()
            .prefix(48))   // 定长十六进制，避开非法文件名字符
        let cacheURL = cacheDir.appendingPathComponent("\(digest)-\(item.name)")
        let path = item.path
        // 远端下载走**独立传输连接**（同 TransferEngine 的合同）：FTP 单控制连接不能
        // 多路复用，用浏览源下载会整程独占它 → 该窗格浏览/刷新全部排队，而命令栏 cd
        // 在主线程同步 stat（InternalCommandExecutor.doCd），最长挂满 controlTimeout。
        let transfer = transferEngine.transferSourceProvider(source)
        let dlSource = transfer?.0 ?? source
        let cleanup = transfer?.1 ?? {}
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { cleanup() }
            // 命中缓存（同 key 同大小）→ 直接开；否则 openReader 泵到临时件再改名落位。
            if FileManager.default.fileExists(atPath: cacheURL.path),
               (try? Data(contentsOf: cacheURL)) != nil {
                DispatchQueue.main.async { self?.openLocal(cacheURL) }
                return
            }
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let reader = try dlSource.openReader(path)
                let tmp = cacheDir.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                guard let fh = FileHandle(forWritingAtPath: tmp.path) else { throw TCError.unknown("cache open") }
                // 64KB 块泵：reader 返回 nil=EOF，返回 Data 可能为空（0 字节须继续读，勿当 EOF）。
                while let chunk = try reader(64 * 1024), !chunk.isEmpty {
                    try fh.write(contentsOf: chunk)
                }
                try fh.close()
                try? FileManager.default.removeItem(at: cacheURL)
                try FileManager.default.moveItem(at: tmp, to: cacheURL)
                DispatchQueue.main.async { self?.openLocal(cacheURL) }
            } catch {
                DispatchQueue.main.async { self?.setStatus(L10n.t(.cannotOpenFile)) }
            }
        }
    }

    private func openLocal(_ url: URL) {
        if !NSWorkspace.shared.open(url) { setStatus(L10n.t(.cannotOpenFile)) }
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

    private func promptRename() {
        guard let item = workspace.activePane.focusedItem else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t(.renameTitle)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t(.okBtn))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        alert.setDefaultConfirmCancel()
        if alert.runConfirmModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
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
        alert.setDefaultConfirmCancel()
        if alert.runConfirmModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
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
        // 冲突框：覆盖是第 1 按钮 → ⏎ 默认落「覆盖」（破坏性默认，与 TC/mc 一致）。
        // **必须保持同步**：返回值被传输引擎同步消费（TransferEngine.prompt → promptOnMain 用
        // DispatchQueue.main.sync 阻塞等结果），改成异步会立即返回错值甚至死锁。
        // `runConfirmModal()` 本身是同步的（返回 runModal 原值），故这里可以照换。
        alert.setDefaultConfirmCancel()
        switch alert.runConfirmModal() {
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
        // 本地删除一律先确认（含单文件）：与远程删除（doRemoteDelete）语义对齐。
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.t(.trashConfirm, "\(targets.count)")
        alert.addButton(withTitle: L10n.t(.deleteWord))
        alert.addButton(withTitle: L10n.t(.cancelBtn))
        alert.setDefaultConfirmCancel()
        if alert.runConfirmModal() != .alertFirstButtonReturn { return }
        let urls = targets.map { $0.path.url }
        NSWorkspace.shared.recycle(urls) { [weak self] _, _ in
            DispatchQueue.main.async {
                pane.load()
                self?.workspace.operationState(.done(label: .opDeleteDone, args: ["\(targets.count)"],
                                                     warningLines: []))
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
        alert.setDefaultConfirmCancel()
        if alert.runConfirmModal() != .alertFirstButtonReturn { return }

        let source = pane.source
        let engine = self.engine
        let state = { [weak self] s in self?.workspace.operationState(s) }
        state(.running(label: .opDeleteRunning, args: ["\(targets.count)"], progress: 0))
        // 系统预建全局队列执行（不新建 DispatchQueue——SDK 约束）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do { try engine.performDelete(targets, source: source); result = .success(()) }
            catch { result = .failure(error) }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    state(.done(label: .opDeleteDone, args: ["\(targets.count)"], warningLines: []))
                case .failure(let error):
                    state(.failed(asTCError(error)))
                }
                self?.reloadPane(pane)
            }
        }
    }
}
