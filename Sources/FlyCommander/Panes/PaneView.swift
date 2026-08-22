import AppKit
import TCCore

final class PaneView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate, FileItemCellDelegate {
    let pane: FilePane
    private let workspace: Workspace
    private let router: CommandRouter
    let id: PaneID

    private let flowLayout = NSCollectionViewFlowLayout()
    private let collectionView: FileCollectionView
    private let scrollView: NSScrollView
    private let titleLabel = NSTextField(labelWithString: "")

    private var items: [FileItem] = []
    private var isDarkAppearance = false
    var isActive = false

    init(pane: FilePane, workspace: Workspace, router: CommandRouter, id: PaneID) {
        self.pane = pane
        self.workspace = workspace
        self.router = router
        self.id = id

        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        flowLayout.itemSize = NSSize(width: 500, height: 22)

        let cv = FileCollectionView(frame: .zero)
        cv.collectionViewLayout = flowLayout
        cv.isSelectable = false
        cv.autoresizingMask = [.width]
        cv.translatesAutoresizingMaskIntoConstraints = false
        self.collectionView = cv

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.documentView = cv
        sv.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = sv

        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        collectionView.paneView = self
        collectionView.dataSource = self
        collectionView.delegate = self

        addSubview(titleLabel)
        addSubview(sv)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.drawsBackground = true
        titleLabel.backgroundColor = .controlBackgroundColor
        titleLabel.wantsLayer = true
        titleLabel.layer?.cornerRadius = 4
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.heightAnchor.constraint(equalToConstant: 16),
            sv.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func layout() {
        super.layout()
        // Initial width; FileCollectionView.layout keeps it in sync when the
        // scroller appears (it shrinks the document view without re-running
        // this layout).
        let width = collectionView.bounds.width > 0 ? collectionView.bounds.width : frame.width
        flowLayout.itemSize = NSSize(width: max(320, width - 20), height: 22)
        flowLayout.invalidateLayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        isDarkAppearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        reload()
    }

    // MARK: - Data source

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = items[indexPath.item]
        let role = visualRole(for: item,
                              isMarked: pane.selection.isMarked(item.id),
                              isFocus: pane.selection.isFocus(item.id))
        let cell = FileItemCellView()
        _ = cell.view
        cell.cellDelegate = self
        cell.configure(with: item, role: role, dark: isDarkAppearance)
        refreshColumns(on: cell)
        return cell
    }

    // MARK: - Column widths

    func fileItemCellDidChangeColumns(_ cell: FileItemCellView) {
        refreshVisibleCellColumns()
    }

    private func refreshColumns(on cell: NSCollectionViewItem) {
        guard let cell = cell as? FileItemCellView else { return }
        let layout = PaneColumnLayout()
        cell.applyColumnWidths(size: layout.sizeWidth, date: layout.dateWidth)
    }

    func refreshVisibleCellColumns() {
        let layout = PaneColumnLayout()
        for item in collectionView.visibleItems() {
            if let cell = item as? FileItemCellView {
                cell.applyColumnWidths(size: layout.sizeWidth, date: layout.dateWidth)
            }
        }
    }

    // MARK: - Public

    func reload() {
        items = pane.page?.items ?? []
        collectionView.reloadData()
        updateTitle()
        scrollFocusIntoView()
        updateActiveBorder()
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateActiveBorder()
        reload()
    }

    func handleClick(indexPath: IndexPath, control: Bool, doubleClick: Bool) {
        guard let window = window else { return }
        window.makeFirstResponder(self)
        let idx = indexPath.item
        if workspace.active != id { workspace.activate(id) }
        if control {
            pane.setFocus(to: idx)
            pane.toggleMark(at: idx)
        } else if doubleClick {
            pane.moveFocus(to: idx, mode: .simple)
            router.execute(.enter)
        } else {
            pane.moveFocus(to: idx, mode: .simple)
        }
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        let isFirstResponder = (window?.firstResponder === self)
        let input = KeyInput(keyCode: event.keyCode, modifiers: event.modifierFlags)
        let result = KeyDispatcher.dispatch(input)
        // DIAG: 临时按键日志（诊断 Cmd+F），定案后删除
        let cmdName = result.map { String(describing: $0.command) } ?? "unmapped"
        DiagLog.write("key keyCode=\(event.keyCode) chars=\"\(event.characters ?? "")\" "
            + "charsIgnoring=\"\(event.charactersIgnoringModifiers ?? "")\" "
            + "modifiers=\(event.modifierFlags.rawValue) isFirstResponder=\(isFirstResponder) "
            + "dispatch=\(cmdName)")
        guard isFirstResponder else { super.keyDown(with: event); return }
        guard let result else { super.keyDown(with: event); return }
        switch result.command {
        case .rename: promptRename()
        case .makeDirectory: promptMakeDirectory()
        case .delete: router.execute(.delete, moveMode: result.moveMode)
        default: router.execute(result.command, moveMode: result.moveMode)
        }
    }

    // MARK: - Prompts

    private func promptRename() {
        guard let item = pane.focusedItem else { return }
        let alert = NSAlert()
        alert.messageText = "重命名"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = item.name
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.rename(to: field.stringValue)
        }
    }

    private func promptMakeDirectory() {
        let alert = NSAlert()
        alert.messageText = "新建目录"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            router.makeDirectory(named: field.stringValue)
        }
    }

    // MARK: - Private

    private func updateTitle() {
        titleLabel.stringValue = pane.path.displayString()
    }

    private func scrollFocusIntoView() {
        let idx = pane.selection.focusIndex
        guard idx >= 0, idx < items.count else { return }
        // scrollToItems(.nearestVerticalEdge) proved unreliable on this
        // toolchain (the clip view never moves), so scroll the clip view
        // manually. The collection view is flipped: y grows downward, and
        // item N's layout y is exactly N * row height.
        DispatchQueue.main.async { [weak self] in
            guard let self, idx < self.items.count else { return }
            self.collectionView.layoutSubtreeIfNeeded()
            guard let attrs = self.flowLayout.layoutAttributesForItem(at: IndexPath(item: idx, section: 0)) else { return }
            let clip = self.scrollView.contentView
            let visibleHeight = clip.bounds.height
            let itemTop = attrs.frame.minY
            let itemBottom = attrs.frame.maxY
            var target = clip.bounds.origin.y
            if itemBottom > clip.bounds.origin.y + visibleHeight {
                target = itemBottom - visibleHeight
            } else if itemTop < clip.bounds.origin.y {
                target = itemTop
            }
            let maxOffset = max(0, self.collectionView.bounds.height - visibleHeight)
            target = min(max(target, 0), maxOffset)
            clip.scroll(NSPoint(x: 0, y: target))
        }
    }

    private func updateActiveBorder() {
        layer?.borderColor = (isActive ? NSColor.systemBlue : NSColor.separatorColor).cgColor
        layer?.borderWidth = isActive ? 1 : 0.5
    }
}
