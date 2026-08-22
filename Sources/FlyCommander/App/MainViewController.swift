import AppKit
import TCCore

final class MainViewController: NSViewController {
    // Minimal compile fix: this toolchain forbids assigning `let` stored
    // properties inside loadView(); declare them implicitly unwrapped instead.
    private var workspace: Workspace!
    private var router: CommandRouter!
    private var leftPaneView: PaneView!
    private var rightPaneView: PaneView!
    private var commandBar: CommandBar!
    private var statusBar: StatusBar!
    private let searchWindow = SearchWindowController()

    // Minimal compile fix: the reduced SDK (Xcode 26.6) does not expose an
    // inherited no-argument initializer on NSViewController, so provide one.
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let home = TCPath("~")
        let source = LocalFileSource()
        let left = FilePane(id: .left, source: source, startPath: home)
        let right = FilePane(id: .right, source: source, startPath: home)
        workspace = Workspace(left: left, right: right, active: .left)

        router = CommandRouter(workspace: workspace, engine: OperationEngine())
        router.conflictPrompt = { [weak self] src, dst in self?.promptConflict(src, dst) ?? .overwrite }
        router.onDelete = { [weak self] pane, targets in self?.doTrashDelete(pane: pane, targets: targets) }
        router.onView = { [weak self] item in self?.showPreview(item) }
        router.onEdit = { [weak self] item in self?.openForEdit(item) }
        router.onSearch = { [weak self] root in self?.beginSearch(in: root) }

        left.onReload = { [weak self] p in self?.refresh(p) }
        right.onReload = { [weak self] p in self?.refresh(p) }
        workspace.onActiveChange = { [weak self] _ in self?.panesDidBecomeActive() }
        workspace.onOperationState = { [weak self] s in self?.operationStateChanged(s) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 680))

        commandBar = CommandBar(frame: .zero)
        statusBar = StatusBar(frame: .zero)
        leftPaneView = PaneView(pane: left, workspace: workspace, router: router, id: .left)
        rightPaneView = PaneView(pane: right, workspace: workspace, router: router, id: .right)
        // Minimal compile fix: IUO values become plain optionals inside an
        // array literal on this toolchain, so unwrap explicitly.
        for v in [leftPaneView!, rightPaneView!, commandBar!, statusBar!] { v.translatesAutoresizingMaskIntoConstraints = false }

        root.addSubview(leftPaneView)
        root.addSubview(rightPaneView)
        root.addSubview(commandBar)
        root.addSubview(statusBar)

        NSLayoutConstraint.activate([
            leftPaneView.topAnchor.constraint(equalTo: root.topAnchor),
            leftPaneView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            leftPaneView.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            leftPaneView.trailingAnchor.constraint(equalTo: root.centerXAnchor, constant: -0.5),

            rightPaneView.topAnchor.constraint(equalTo: root.topAnchor),
            rightPaneView.leadingAnchor.constraint(equalTo: root.centerXAnchor, constant: 0.5),
            rightPaneView.bottomAnchor.constraint(equalTo: commandBar.topAnchor),
            rightPaneView.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            commandBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            commandBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            commandBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4),
            commandBar.heightAnchor.constraint(equalToConstant: 26),

            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 20),
        ])

        self.view = root

        leftPaneView.setActive(true)
        rightPaneView.setActive(false)
        left.load()
        right.load()
        updateBars()
    }

    // MARK: - Core callbacks

    private func refresh(_ pane: FilePane) {
        // Minimal compile fix: IUO values become plain optionals inside a
        // ternary on this toolchain, so unwrap explicitly.
        let pv: PaneView = pane.id == .left ? leftPaneView! : rightPaneView!
        pv.reload()
        updateBars()
    }

    private func panesDidBecomeActive() {
        leftPaneView.setActive(workspace.active == .left)
        rightPaneView.setActive(workspace.active == .right)
    }

    private func operationStateChanged(_ s: OperationState) {
        switch s {
        case .running(let label, let progress): commandBar.setStatus("\(label) \(Int(progress * 100))%")
        case .done(let m): commandBar.setStatus(m)
        case .failed(let m): commandBar.setStatus("错误：\(m)")
        case .idle: commandBar.setStatus("")
        }
    }

    private func updateBars() {
        let a = workspace.activePane
        let op = a.selection.operationIDs.count
        commandBar.setPath(a.path.displayString(), selected: op)
        let total = a.operationTargets.reduce(Int64(0)) { $0 + $1.size }
        statusBar.show(diskFree: Self.diskFree(), selected: op, totalBytes: total)
    }

    private static func diskFree() -> Int64 {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: FileManager.default.homeDirectoryForCurrentUser.path)
        return (attrs?[.systemFreeSize] as? Int64) ?? 0
    }

    // MARK: - AppKit-provided operations

    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "csv", "json", "xml", "plist", "ini",
        "swift", "m", "h", "mm", "c", "cpp", "hxx", "py", "js", "ts", "rb",
        "go", "rs", "sh", "zsh", "yml", "yaml", "toml", "html", "css", "sql",
    ]

    private func showPreview(_ item: FileItem) {
        NSLog("FLYPREVIEW showPreview name=\(item.name) path=\(item.path.pathString)")
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
                            self.commandBar.setStatus("无法打开文件")
                        }
                    }
                }
            }
        } else {
            if !NSWorkspace.shared.open(url) {
                commandBar.setStatus("无法打开文件")
            }
        }
    }

    private func beginSearch(in root: TCPath) {
        NSLog("FLYSEARCH beginSearch root=\(root.pathString)")
        searchWindow.onOperation = { [weak self] state in self?.workspace.operationState(state) }
        searchWindow.present(root: root) { [weak self] hit in
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

    private func promptConflict(_ src: TCPath, _ dst: TCPath) -> ConflictChoice {
        let alert = NSAlert()
        alert.messageText = "目标已存在"
        alert.informativeText = "“\(dst.fileName)” 已存在，如何处理？"
        alert.addButton(withTitle: "覆盖")
        alert.addButton(withTitle: "跳过")
        alert.addButton(withTitle: "全部覆盖")
        alert.addButton(withTitle: "全部跳过")
        alert.addButton(withTitle: "取消")
        // Minimal compile fix: this reduced SDK's NSApplication.ModalResponse only
        // names the first three alert buttons; per NSAlert.h, the Nth button
        // (N > 3) returns NSAlertThirdButtonReturn + (N - 3), i.e. 1003 for button 4.
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .overwrite
        case .alertSecondButtonReturn: return .skip
        case .alertThirdButtonReturn: return .overwriteAll
        case NSApplication.ModalResponse(rawValue: 1003): return .skipAll
        default: return .cancel
        }
    }

    private func doTrashDelete(pane: FilePane, targets: [FileItem]) {
        if targets.count > 1 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "删除 \(targets.count) 个文件到废纸篓？"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
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
}
