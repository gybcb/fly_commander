import AppKit
import TCCore

final class PaneView: NSView, NSCollectionViewDataSource, NSCollectionViewDelegate {
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
        flowLayout.itemSize = NSSize(width: max(320, frame.width), height: 22)
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
        cell.configure(with: item, role: role, dark: isDarkAppearance)
        return cell
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
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let input = KeyInput(keyCode: event.keyCode, modifiers: event.modifierFlags)
        guard let result = KeyDispatcher.dispatch(input) else { super.keyDown(with: event); return }
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
        // reloadData() is asynchronous; scroll after the layout pass so the
        // target item's position is valid.
        DispatchQueue.main.async { [weak self] in
            guard let self, idx < self.items.count else { return }
            self.collectionView.scrollToItems(at: [IndexPath(item: idx, section: 0)],
                                             scrollPosition: .nearestVerticalEdge)
        }
    }

    private func updateActiveBorder() {
        layer?.borderColor = (isActive ? NSColor.systemBlue : NSColor.separatorColor).cgColor
        layer?.borderWidth = isActive ? 1 : 0.5
    }
}
