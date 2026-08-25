import AppKit
import TCCore

/// 一侧容器：顶部 TabBarView + 叠放 N 个常驻 PaneTableView（非活动 isHidden，不增删）。
/// 作为 NSSplitView 的一列。isHidden 切换规避 reduced-SDK 的 split setPosition 折叠坑，
/// 并复用 FilePane.loadAsync 的 per-instance token 去重（后台加载互不串）。
///
/// 顺序契约：调用方保证 tabGroup.panes 顺序与本容器 addTab 顺序一致（add 先 core 后 view，
/// close 先 core 后 view）。show 依此对齐。
final class SidePaneContainer: NSView {
    let side: PaneID
    let tabBar = TabBarView()
    var commandBar: CommandLineBar? {
        didSet { allPaneViews.forEach { $0.commandBar = commandBar } }
    }

    private let content = NSView()
    private var ordered: [PaneTableView] = []                    // 顺序 = TabGroup.panes
    private var byPane: [ObjectIdentifier: PaneTableView] = [:]  // 按 pane identity 查

    init(side: PaneID) {
        self.side = side
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        // 顶部标签条 + 下方内容区，纯手动约束（不用 NSStackView——reduced-SDK 下
        // stack 叠排子视图的约束易冲突；与代码库 CommandLineBar 一致）。
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabBar)
        addSubview(content)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.barHeight),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 追加一个标签的 PaneTableView（叠放在 content 内，先隐藏；由 show 决定显示）。
    @discardableResult
    func addTab(pane: FilePane, workspace: Workspace, router: CommandRouter) -> PaneTableView {
        let pv = PaneTableView(pane: pane, workspace: workspace, router: router, id: side)
        pv.commandBar = commandBar
        pv.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: content.topAnchor),
            pv.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        pv.isHidden = true
        ordered.append(pv)
        byPane[ObjectIdentifier(pane)] = pv
        pv.reload()
        return pv
    }

    func removeTab(pane: FilePane) {
        guard let pv = byPane[ObjectIdentifier(pane)] else { return }
        byPane[ObjectIdentifier(pane)] = nil
        ordered.removeAll { $0 === pv }
        pv.removeFromSuperview()
    }

    func paneView(_ pane: FilePane) -> PaneTableView? { byPane[ObjectIdentifier(pane)] }
    var allPaneViews: [PaneTableView] { ordered }
    var activePaneView: PaneTableView? { ordered.first { !$0.isHidden } }

    /// 按 tabGroup.activeIndex 显示对应 PaneTableView（其余 isHidden）、设边框、刷标签条。
    /// 调用方须保证 tabGroup.side == self.side 且 panes 顺序与 addTab 一致。
    func show(tabGroup: TabGroup, isActiveSide: Bool) {
        assert(tabGroup.side == side, "SidePaneContainer.show 侧不匹配")
        let idx = tabGroup.activeIndex
        for (i, pv) in ordered.enumerated() {
            pv.isHidden = (i != idx)
            pv.setActive(isActiveSide && i == idx)
        }
        tabBar.rebuild(titles: tabGroup.panes.map { Self.tabTitle($0.path) },
                       activeIndex: idx, isActiveSide: isActiveSide)
    }

    /// 纯函数：标签标题。本地=目录名（根="/"）；远端=host:port+路径（根=host:port）。
    static func tabTitle(_ path: TCPath) -> String {
        if path.isRemote {
            var s = path.url.host ?? ""
            if let port = path.url.port { s += ":\(port)" }
            let suffix = path.isRoot ? "" : path.url.path
            return s + suffix
        }
        return path.isRoot ? "/" : path.fileName
    }
}
