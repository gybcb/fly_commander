import AppKit
import TCCore

/// 原生 NSTableView 窗格：视图层排序（焦点/标记按 id 存储，不受排序影响）、
/// 表级列宽 autosave、两级系统色高亮、鼠标/键盘全部翻译成 core 调用。
final class PaneTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum SortKey { case name, size, date }
    enum SortDirection { case ascending, descending }

    /// 列的稳定 identifier（语言无关，永不变）：既是 NSTableColumn 的 id，也是列头点击
    /// 选列的依据。点击排序靠它匹配，与本地化标题彻底解耦——语言切换/列头重建都不影响。
    static let nameColumnID = "name"
    static let sizeColumnID = "size"
    static let dateColumnID = "date"

    let pane: FilePane
    private let workspace: Workspace
    private let router: CommandRouter
    let id: PaneID
    /// 底部命令栏（两窗格共享同一实例）：无修饰字符键/Return/Backspace/Esc 经拦截送入。
    var commandBar: CommandLineBar?

    var tableView: ClickForwardingTableView!
    private var scrollView: NSScrollView!

    /// display 顺序（item id 列表），与 pane.selection.items 一一对应。
    private var displayIDs: [String] = []
    private var sortKey: SortKey = .name
    private var sortDirection: SortDirection = .ascending
    private(set) var isActive = false

    /// type-ahead 前缀缓冲（pane 模式下累积字母，1 秒无输入自动清空）。
    private var typeAheadBuffer = ""
    private var typeAheadReset: DispatchWorkItem?

    init(pane: FilePane, workspace: Workspace, router: CommandRouter, id: PaneID) {
        self.pane = pane
        self.workspace = workspace
        self.router = router
        self.id = id

        let tv = ClickForwardingTableView()
        tv.usesAlternatingRowBackgroundColors = false
        tv.selectionHighlightStyle = .none
        tv.intercellSpacing = NSSize(width: 4, height: 0)
        tv.rowHeight = 20
        tv.autoresizingMask = [.width]
        tv.autosaveTableColumns = true
        tv.autosaveName = "FlyCommanderPane\((id == .left) ? "L" : "R")\(ObjectIdentifier(pane).hashValue)"

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.nameColumnID))
        name.title = L10n.t(.colName)
        name.width = 280
        name.minWidth = 80
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.sizeColumnID))
        size.title = L10n.t(.colSize)
        size.width = 70
        size.minWidth = 40
        let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Self.dateColumnID))
        date.title = L10n.t(.colDate)
        date.width = 150
        date.minWidth = 80
        [name, size, date].forEach { tv.addTableColumn($0) }

        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.documentView = tv

        super.init(frame: .zero)
        tableView = tv
        scrollView = sv
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        tv.delegate = self
        tv.dataSource = self
        tv.onRowClick = { [weak self] row, event, double in
            self?.handleMouseClick(row: row, event: event, doubleClick: double)
        }
        addSubview(sv)
        sv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: topAnchor),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    // MARK: - Public

    func reload() {
        displayIDs = PaneTableView.sortedIDs(pane.selection.items,
                                             items: pane.itemByID,
                                             key: sortKey,
                                             direction: sortDirection)
        tableView.reloadData()
        DispatchQueue.main.async { [weak self] in self?.scrollFocusRowIntoView() }
    }

    func setActive(_ active: Bool) {
        isActive = active
        layer?.borderColor = (active ? ThemeStore.shared.accentColor.cgColor : NSColor.separatorColor.cgColor)
        layer?.borderWidth = active ? 1 : 0.5
    }

    /// 语言切换后重刷列头标题：按**稳定 identifier** 找回列（与显示标题解耦），
    /// 重设 .title 后请求表头重绘。列宽/顺序/autosave 全不受影响。
    func retitileColumns() {
        for col in tableView.tableColumns {
            switch col.identifier.rawValue {
            case Self.nameColumnID: col.title = L10n.t(.colName)
            case Self.sizeColumnID: col.title = L10n.t(.colSize)
            case Self.dateColumnID: col.title = L10n.t(.colDate)
            default: break
            }
        }
        tableView.headerView?.needsLayout = true
        tableView.tile()
    }

    // MARK: - Data source

    func numberOfRows(in tableView: NSTableView) -> Int { displayIDs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < displayIDs.count else { return nil }
        let idOfRow = displayIDs[row]
        guard let item = pane.itemByID[idOfRow] else { return nil }
        // 本 SDK 无 registerClass:forIdentifier:，makeView 恒 nil → 回退手动创建。
        // 表格在无复用 view 时每次都会调本委托，手动 new 正确且受支持。
        let cell = (tableView.makeView(withIdentifier: column.identifier, owner: self)
                    as? FileCellView) ?? FileCellView(frame: .zero)
        cell.configure(item: item,
                       focus: pane.selection.isFocus(idOfRow),
                       marked: pane.selection.isMarked(idOfRow),
                       column: tableView.tableColumns.firstIndex(of: column) ?? 0)
        return cell
    }

    // MARK: - Column header sorting（视图层：点击列头换 display 顺序）

    /// 点列头换排序列。参数是**稳定 identifier**（"name"/"size"/"date"），不是显示标题——
    /// 选列完全与本地化解耦，语言切换或列头重建都不会让点击失效。
    func sortByColumnIdentifier(_ identifier: String) {
        let newKey: SortKey
        switch identifier {
        case Self.nameColumnID: newKey = .name
        case Self.sizeColumnID: newKey = .size
        case Self.dateColumnID: newKey = .date
        default: return
        }
        if newKey == sortKey {
            sortDirection = (sortDirection == .ascending) ? .descending : .ascending
        } else {
            sortKey = newKey
            sortDirection = .ascending
        }
        reload()
    }

    // MARK: - Mouse（Ctrl/Option 单击 = 切换标记，普通 = 移动焦点，双击 = 进入）

    func handleMouseClick(row: Int, event: NSEvent, doubleClick: Bool) {
        guard row >= 0, row < displayIDs.count else { return }
        // display 行号 ≠ selection 索引（排序后错位）：按 item id 反查。
        guard let selIndex = pane.selection.items.firstIndex(of: displayIDs[row]) else { return }
        let modifiers = event.modifierFlags
        if modifiers.contains(.control) || modifiers.contains(.option) {
            window?.makeFirstResponder(self)
            if workspace.active != id { workspace.activate(id) }
            pane.toggleMark(at: selIndex)
            return
        }
        window?.makeFirstResponder(self)
        if workspace.active != id { workspace.activate(id) }
        if doubleClick {
            pane.moveFocus(to: selIndex, mode: .simple)
            router.execute(.enter)
        } else {
            // 与 P1 行为一致：普通单击只移焦点、不清标记
            pane.setFocus(to: selIndex)
        }
    }

    // MARK: - Key handling（KeyDispatcher 的落点）

    override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self else { super.keyDown(with: event); return }
        let input = KeyInput(keyCode: event.keyCode, modifiers: event.modifierFlags)
        // 1) KeyDispatcher 认领的键（方向/F 键/Return/Backspace/Space/Tab/Esc…）走 TC 原路径；
        //    处理前先清 type-ahead 前缀（任何"别的"键都中断字母累积）。
        if let result = KeyDispatcher.dispatch(input) {
            typeAheadBuffer = ""
            typeAheadReset?.cancel()
            handleDispatched(result)
            return
        }
        // 2) 未被认领的键：无修饰可打印字符 → type-ahead（字母导航，TC 行为）。
        if typeAheadChar(event) { return }
        super.keyDown(with: event)
    }

    private func handleDispatched(_ result: DispatchResult) {
        switch result.command {
        case .up: navigate(delta: -1, mode: result.moveMode)
        case .down: navigate(delta: 1, mode: result.moveMode)
        case .pageUp: navigate(delta: -15, mode: result.moveMode)
        case .pageDown: navigate(delta: 15, mode: result.moveMode)
        case .home: navigate(toEdge: .home, mode: result.moveMode)
        case .end: navigate(toEdge: .end, mode: result.moveMode)
        case .rename: promptRename()
        case .makeDirectory: promptMakeDirectory()
        case .delete: router.execute(.delete, moveMode: result.moveMode)
        case .activateCommandLine: activateCommandLineBar()
        default: router.execute(result.command, moveMode: result.moveMode)
        }
    }

    /// 右箭头激活命令栏：焦点移到输入框（其自身接管后续键入；Enter/Esc 会 focus 回窗格）。
    private func activateCommandLineBar() {
        commandBar?.activate()
    }

    /// type-ahead：累积无修饰可打印字符为前缀，1 秒内连续字母扩展、超时自动清空；
    /// 命中后从焦点下一行环形找第一个 name 前缀匹配的项。返回 true 表示已消费。
    private func typeAheadChar(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        else { return false }
        // 可打印字符（含中文/符号）；方向键/F 键/Home/End 等在 macOS 上
        // charactersIgnoringModifiers 落在私有区 0xE000–0xF8FF，须排除。
        guard let chars = event.charactersIgnoringModifiers,
              !chars.isEmpty,
              let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value != 0x7f,
              (scalar.value < 0xE000 || scalar.value > 0xF8FF) else { return false }
        typeAheadReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.typeAheadBuffer = "" }
        typeAheadReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: reset)
        typeAheadBuffer.append(chars)
        performTypeAhead(prefix: typeAheadBuffer)
        return true
    }

    private func performTypeAhead(prefix: String) {
        guard let target = PaneTableView.typeAheadSelectionIndex(
            displayIDs: displayIDs,
            itemByID: pane.itemByID,
            selectionItems: pane.selection.items,
            focusID: pane.selection.focusID,
            prefix: prefix) else { return }
        // .sticky：移焦点但保留标记集（与方向键一致的 TC 粘性语义）。
        pane.moveFocus(to: target, mode: .sticky)
    }

    /// 键盘方向移动：按**显示顺序**相邻（乱序列头后仍落在可见的下一/上一行，而非
    /// selection 存储序里相邻的项）。delta 在 display 位置上加减并 clamp，再映射回
    /// selection 索引；home/end 直接取 display 首/末行。
    enum Edge { case home, end }

    func navigate(delta: Int, mode: SelectionModel.MoveMode) {
        let target = PaneTableView.targetSelectionIndex(displayIDs: displayIDs,
                                                        items: pane.selection.items,
                                                        focusID: pane.selection.focusID,
                                                        delta: delta)
        pane.moveFocus(to: target, mode: mode)
    }

    func navigate(toEdge edge: Edge, mode: SelectionModel.MoveMode) {
        let target = PaneTableView.targetSelectionIndex(displayIDs: displayIDs,
                                                        items: pane.selection.items,
                                                        edge: edge)
        pane.moveFocus(to: target, mode: mode)
    }

    private func scrollFocusRowIntoView() {
        guard let focusID = pane.selection.focusID,
              let row = displayIDs.firstIndex(of: focusID) else { return }
        tableView.scrollRowToVisible(row)
    }

    // MARK: - Prompts

    private func promptRename() {
        guard let item = pane.focusedItem else { return }
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

    // MARK: - Pure sorting（可单测）

    static func sortedIDs(_ ids: [String], items: [String: FileItem],
                          key: SortKey, direction: SortDirection) -> [String] {
        guard !ids.isEmpty else { return ids }
        func value(_ id: String) -> (String, Int64, Date) {
            let item = items[id]!
            return (item.name, item.isDirectory ? 0 : item.size, item.modificationDate)
        }
        let sorted: [String]
        switch key {
        case .name:
            // 目录优先 + 名称（与内核 selection 存储序一致 → 默认序下 display==selection）
            sorted = ids.sorted { left, right in
                let li = items[left]!, ri = items[right]!
                if li.isDirectory != ri.isDirectory { return li.isDirectory && !ri.isDirectory }
                return li.name.localizedStandardCompare(ri.name) == .orderedAscending
            }
        case .size:
            sorted = ids.sorted { value($0).1 != value($1).1 ? value($0).1 < value($1).1
                                                             : value($0).0.localizedStandardCompare(value($1).0) == .orderedAscending }
        case .date:
            sorted = ids.sorted { value($0).2 != value($1).2 ? value($0).2 < value($1).2
                                                             : value($0).0.localizedStandardCompare(value($1).0) == .orderedAscending }
        }
        return direction == .descending ? Array(sorted.reversed()) : sorted
    }

    /// 把"显示位置上的第 target 行"映射回 selection 存储序的索引。
    /// 焦点项不在 display（空页/切换中）时 delta 从首行起算。
    static func targetSelectionIndex(displayIDs: [String], items: [String],
                                    focusID: String?, delta: Int) -> Int {
        guard !displayIDs.isEmpty else { return 0 }
        let focusRow: Int
        if let fid = focusID, let r = displayIDs.firstIndex(of: fid) {
            focusRow = r
        } else {
            focusRow = 0
        }
        let target = min(max(focusRow + delta, 0), displayIDs.count - 1)
        return items.firstIndex(of: displayIDs[target]) ?? 0
    }

    static func targetSelectionIndex(displayIDs: [String], items: [String], edge: Edge) -> Int {
        guard !displayIDs.isEmpty else { return 0 }
        let target = (edge == .home) ? 0 : displayIDs.count - 1
        return items.firstIndex(of: displayIDs[target]) ?? 0
    }

    /// type-ahead 纯函数：从焦点**下一行**环形遍历 display 顺序，返回第一个 name
    /// 前缀匹配（忽略大小写）项的 selection 索引；无匹配返回 nil（焦点不动，TC 行为）。
    /// 从焦点后开始使"再按当前项首字母"跳到下一同名项。displayIDs=显示序，
    /// selectionItems=存储序（pane.selection.items），focusID 定位起点。
    static func typeAheadSelectionIndex(displayIDs: [String],
                                        itemByID: [String: FileItem],
                                        selectionItems: [String],
                                        focusID: String?,
                                        prefix: String) -> Int? {
        guard !displayIDs.isEmpty, !prefix.isEmpty else { return nil }
        let lowered = prefix.lowercased()
        let startRow: Int
        if let fid = focusID, let r = displayIDs.firstIndex(of: fid) {
            startRow = (r + 1) % displayIDs.count
        } else {
            startRow = 0
        }
        let n = displayIDs.count
        for offset in 0..<n {
            let row = (startRow + offset) % n
            let id = displayIDs[row]
            guard let item = itemByID[id] else { continue }
            if item.name.lowercased().hasPrefix(lowered) {
                return selectionItems.firstIndex(of: id)
            }
        }
        return nil
    }
}

/// 不做原生选中/焦点切换，行点击统一转给窗格容器处理。
final class ClickForwardingTableView: NSTableView {
    var onRowClick: ((Int, NSEvent, Bool) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return }
        onRowClick?(row, event, event.clickCount >= 2)
    }
}
