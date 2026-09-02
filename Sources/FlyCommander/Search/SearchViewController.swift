import AppKit
import TCCore

final class HitTableView: NSTableView {
    var onActivate: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / numpad Enter
            if selectedRow >= 0 { onActivate?() }
        case 53: // Esc closes the search window
            window?.close()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount >= 2, selectedRow >= 0 {
            onActivate?()
        }
    }
}

final class SearchViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onOperation: ((OperationState) -> Void)?

    // MARK: - State

    private var root: TCPath = TCPath("~")
    private var source: FileSource = LocalFileSource()
    private var onSelect: ((SearchHit) -> Void)?
    private var hits: [SearchHit] = []
    private var isSearching = false

    private let lock = NSLock()
    private var cancelled = false

    // MARK: - Form segment

    private let formContainer = NSView()
    private let rootLabel = NSTextField(labelWithString: "")
    private let patternField = NSTextField(frame: .zero)
    private let hintLabel = NSTextField(labelWithString: L10n.t(.searchHint))
    private let startButton = NSButton(title: L10n.t(.startSearch), target: nil, action: nil)
    private let cancelButton = NSButton(title: L10n.t(.cancel), target: nil, action: nil)

    // MARK: - Result segment

    private let resultContainer = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: L10n.t(.stop), target: nil, action: nil)
    private let newSearchButton = NSButton(title: L10n.t(.newSearch), target: nil, action: nil)
    private let table = HitTableView()

    /// 语言切换重刷绑定：每条闭包捕获控件 + key（非成品串），刷新时按当前语言重算 t() 回写。
    private var localizedBindings: [() -> Void] = []
    private func bind(_ field: NSTextField, _ key: L10nKey) {
        localizedBindings.append { field.stringValue = L10n.t(key) }
    }
    private func bind(_ button: NSButton, _ key: L10nKey) {
        localizedBindings.append { button.title = L10n.t(key) }
    }

    /// 语言变更后重刷本窗所有静态标签（提示/按钮/列头）。状态文本随流程覆盖，不在此重刷。
    /// 视图未加载时绑定表为空 → 无操作，不会强行 loadView。
    func refreshLocalizedText() {
        localizedBindings.forEach { $0() }
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))
        buildForm()
        buildResult()
        // 两个顶层容器铺满窗口：reduced-SDK 下 NSView() 默认 0x0 frame，若漏设
        // translates=false，其约束与 frame autoresizing 冲突会把 content 压到 0 宽
        // （窗口塌成 0×标题栏高，视觉上"搜索窗出不来"）。对齐 PreviewViewController。
        formContainer.translatesAutoresizingMaskIntoConstraints = false
        resultContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(formContainer)
        container.addSubview(resultContainer)
        NSLayoutConstraint.activate([
            formContainer.topAnchor.constraint(equalTo: container.topAnchor),
            formContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            formContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            formContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            resultContainer.topAnchor.constraint(equalTo: container.topAnchor),
            resultContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            resultContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            resultContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
        resultContainer.isHidden = true

        // 静态标签绑定（提示/四个按钮）；根标签、状态文本随流程覆盖，不绑定。
        bind(hintLabel, .searchHint)
        bind(startButton, .startSearch)
        bind(cancelButton, .cancel)
        bind(stopButton, .stop)
        bind(newSearchButton, .newSearch)
    }

    private func buildForm() {
        rootLabel.font = .systemFont(ofSize: 12, weight: .medium)
        patternField.translatesAutoresizingMaskIntoConstraints = false
        patternField.placeholderString = "*"
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.keyEquivalentModifierMask = []
        startButton.target = self
        startButton.action = #selector(startTapped)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        cancelButton.target = self
        cancelButton.action = #selector(closeTapped)

        let buttonRow = NSStackView(views: [startButton, cancelButton])
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [rootLabel, patternField, hintLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        formContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: formContainer.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: formContainer.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: formContainer.trailingAnchor, constant: -20),
            patternField.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    private func buildResult() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hit"))
        column.title = L10n.t(.colFile)
        column.width = 460
        table.addTableColumn(column)
        localizedBindings.append { column.title = L10n.t(.colFile) }   // 当前 headerView=nil（不显），仍绑定防将来启用
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.translatesAutoresizingMaskIntoConstraints = false
        table.onActivate = { [weak self] in self?.hitActivated() }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        stopButton.bezelStyle = .rounded
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        newSearchButton.bezelStyle = .rounded
        newSearchButton.target = self
        newSearchButton.action = #selector(newSearchTapped)
        let buttonRow = NSStackView(views: [statusLabel, newSearchButton, stopButton])
        buttonRow.spacing = 10
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        resultContainer.addSubview(scroll)
        resultContainer.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            buttonRow.topAnchor.constraint(equalTo: resultContainer.topAnchor, constant: 12),
            buttonRow.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: resultContainer.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: resultContainer.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: resultContainer.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Public

    func prepare(root: TCPath, source: FileSource, onSelect: @escaping (SearchHit) -> Void) {
        self.root = root
        self.source = source
        self.onSelect = onSelect
        hits = []
        isSearching = false
        rootLabel.stringValue = L10n.t(.searchRootLabel, root.displayString())
        patternField.stringValue = "*"
        statusLabel.stringValue = ""
        stopButton.isHidden = true
        newSearchButton.isHidden = true
        formContainer.isHidden = false
        resultContainer.isHidden = true
    }

    /// 聚焦模式输入框。窗口须已就位（window 为 nil 时 makeFirstResponder 无效）。
    func focusPatternField() {
        view.window?.makeFirstResponder(patternField)
    }

    // MARK: - Actions

    @objc private func startTapped() {
        let pattern = patternField.stringValue.isEmpty ? "*" : patternField.stringValue
        isSearching = true
        lock.lock(); cancelled = false; lock.unlock()
        formContainer.isHidden = true
        resultContainer.isHidden = false
        statusLabel.stringValue = L10n.t(.searching)
        stopButton.isHidden = false
        newSearchButton.isHidden = true
        table.reloadData()
        table.deselectAll(nil)

        let rootPath = root
        let searchSource = source
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var visited = 0
            // 进度刷新节流：大目录树 progress 每逢 10 项回调一次，逐次 dispatch 主线程会洪泛；
            // 收尾状态由下方完成块负责（不受此节流影响）。
            var lastFlush = CFAbsoluteTimeGetCurrent()
            let found = FileSearcher().search(
                root: rootPath,
                pattern: NamePattern(pattern),
                source: searchSource,
                progress: { n in
                    visited = n
                    let now = CFAbsoluteTimeGetCurrent()
                    guard now - lastFlush >= 0.1 else { return }
                    lastFlush = now
                    DispatchQueue.main.async {
                        guard self.isSearching else { return }
                        self.statusLabel.stringValue = L10n.t(.searchingChecked, "\(n)")
                        self.onOperation?(.running(label: "搜索", progress: 0))
                    }
                },
                isCancelled: { [weak self] in
                    guard let self else { return true }
                    self.lock.lock(); defer { self.lock.unlock() }
                    return self.cancelled
                })
            DispatchQueue.main.async {
                guard self.isSearching else { return }
                self.isSearching = false
                self.hits = found
                self.table.reloadData()
                self.stopButton.isHidden = true
                self.newSearchButton.isHidden = false
                self.lock.lock(); let wasCancelled = self.cancelled; self.lock.unlock()
                if wasCancelled {
                    self.statusLabel.stringValue = L10n.t(.searchStopped, "\(found.count)")
                    self.onOperation?(.idle)
                } else {
                    self.statusLabel.stringValue = L10n.t(.searchSummary, "\(found.count)", "\(visited)")
                    self.onOperation?(.done("搜索完成，\(found.count) 个结果"))
                }
                if found.isEmpty && !wasCancelled {
                    self.statusLabel.stringValue = L10n.t(.searchNone, "\(visited)")
                }
            }
        }
    }

    @objc private func closeTapped() {
        view.window?.close()
    }

    @objc private func stopTapped() {
        lock.lock(); cancelled = true; lock.unlock()
        statusLabel.stringValue = L10n.t(.stopping)
    }

    @objc private func newSearchTapped() {
        formContainer.isHidden = false
        resultContainer.isHidden = true
        patternField.stringValue = "*"
        view.window?.makeFirstResponder(patternField)
    }

    private func hitActivated() {
        let row = table.selectedRow
        guard row >= 0, row < hits.count else { return }
        let hit = hits[row]
        view.window?.close()
        onSelect?(hit)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { hits.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("hitCell")
        let cell: NSView
        if let reused = tableView.makeView(withIdentifier: id, owner: self) {
            cell = reused
        } else {
            cell = NSView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingMiddle
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let hit = hits[row]
        (cell.subviews.first as? NSTextField)?.stringValue = relativePath(of: hit)
        (cell.subviews.first as? NSTextField)?.font = hit.isDirectory
            ? .systemFont(ofSize: 12, weight: .bold)
            : .systemFont(ofSize: 12)
        return cell
    }

    private func relativePath(of hit: SearchHit) -> String {
        let prefix = root.pathString
        let full = hit.path.pathString
        guard full.hasPrefix(prefix) else { return full }
        var rel = full.dropFirst(prefix.count)
        if rel.hasPrefix("/") { rel = rel.dropFirst() }
        return String(rel)
    }
}
