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

    /// display 顺序（item id 列表）；正常路径与 `pane.selection.items` 同源，
    /// 防御路径下可能少项（`sortedIDs` 跳过 items 字典里缺失的 id）。
    private var displayIDs: [String] = []
    private var sortKey: SortKey = .name
    private var sortDirection: SortDirection = .ascending
    private(set) var isActive = false

    /// type-ahead 前缀缓冲（pane 模式下累积字母，1 秒无输入自动清空）。
    private var typeAheadBuffer = ""
    private var typeAheadReset: DispatchWorkItem?
    /// 右键菜单的共享选择器（show 弹出期间须持有 picker 防释放）。
    private var sharePicker: NSSharingServicePicker?

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

    /// 选择态快路（方向键/空格/单击）：内容未变，只 focus/marks 变。全量 reload 的
    /// 代价实测 O(N) 重排（2 万项 ≈ 37ms）+ 重建全部可见 cell + main.async 滚动跳
    /// （"慢半拍"的字面来源）。这里：只重建**可见行**（含焦点行 + 任意标记行，
    /// selectAll/清空也覆盖）+ **同步** scrollRowToVisible；displayIDs 原样不重排。
    /// 不可见行的 focus/mark 变化在其滚入时由 viewFor 现取当前选择态自愈，无须预刷。
    func refreshSelection() {
        let visible = tableView.rows(in: tableView.visibleRect)
        let columnCount = tableView.tableColumns.count
        let columns = IndexSet(integersIn: 0..<columnCount)
        // 可见行须先按当前（未滚动的）选择态重绘，再滚动：新滚入的行由 viewFor 现建，
        // 天然带正确态；旧焦点行若滚出可视区也无所谓（已重绘为未高亮）。
        if visible.length > 0 {
            tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<visible.location + visible.length),
                                 columnIndexes: columns)
        }
        if let focusID = pane.selection.focusID, let row = displayIDs.firstIndex(of: focusID) {
            tableView.scrollRowToVisible(row)   // 同步滚动，不再 main.async
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        layer?.borderColor = (active ? ThemeStore.shared.accentColor.cgColor : NSColor.separatorColor.cgColor)
        layer?.borderWidth = active ? 1 : 0.5
    }

    /// 语言切换后重刷列头标题 + 单元格本地化格式（日期列随 L10n.current）：
    /// 按**稳定 identifier** 找回列（与显示标题解耦），重设 .title 后请求表头重绘；
    /// 再 reloadData 让可见 cell 重跑 configure（日期串现取当前语言 locale）。
    /// 列宽/顺序/autosave/排序全不受影响（不重排序，displayIDs 原样）。
    func retitleColumns() {
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
        tableView.reloadData()   // 让 dateLabel 按当前 locale 重渲染（④ formatter locale）
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

    // MARK: - Context menu（右键，Finder 式）

    /// 右键菜单。Finder 式选择语义：右键落在**已在选择集里**的行 → 保持多选，
    /// 操作对整组生效（copy/move/delete）；落在未选行 → 只选中该行（moveFocus .simple
    /// 清其余标记）。"打开/打开方式/预览/编辑/重命名"按单项目（右键命中的那一项）。
    /// 远端源禁用"打开方式/显示在 Finder/共享"（无本地 url、无默认程序关联）；
    /// "打开"对远端文件仍可用（router.onOpen 下载后开）。
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = tableView.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < displayIDs.count, let item = pane.itemByID[displayIDs[row]] else { return nil }
        window?.makeFirstResponder(self)
        if workspace.active != id { workspace.activate(id) }
        applyContextMenuSelection(to: item)
        return contextMenu(for: item)
    }

    /// Finder 式选择语义（可单测）：右键项已在选择集（marked ∪ focus）→ 保持多选不动；
    /// 否则只选这一行（.simple 清其余标记）。不在当前页的项（异常）→ 不动。
    func applyContextMenuSelection(to item: FileItem) {
        guard !(pane.selection.isMarked(item.id) || pane.selection.isFocus(item.id)),
              let idx = pane.selection.items.firstIndex(of: item.id) else { return }
        pane.moveFocus(to: idx, mode: .simple)
    }

    /// 按目标项构建右键菜单（可单测；不依赖鼠标坐标/离屏布局）。
    func contextMenu(for item: FileItem) -> NSMenu {
        let remote = pane.source.isRemote
        let menu = NSMenu()

        func add(_ key: L10nKey, _ action: Selector, target: AnyObject,
                 enabled: Bool = true, keyEquivalent: String = "") -> NSMenuItem {
            let it = menu.addItem(withTitle: L10n.t(key), action: action, keyEquivalent: keyEquivalent)
            it.target = target
            it.isEnabled = enabled
            return it
        }

        add(.menuOpen, #selector(ctxOpen(_:)), target: self).representedObject = item
        // 打开方式：本地文件才有关联程序。
        let openWith = menu.addItem(withTitle: L10n.t(.openWithMenu), action: nil, keyEquivalent: "")
        openWith.isEnabled = !remote && !item.isDirectory
        openWith.submenu = buildOpenWithMenu(for: item, enabled: !remote && !item.isDirectory)
        let reveal = add(.showInFinder, #selector(ctxReveal(_:)), target: self, enabled: !remote)
        reveal.representedObject = item
        menu.addItem(.separator())
        add(.preview, #selector(ctxPreview(_:)), target: self, enabled: !item.isDirectory).representedObject = item
        add(.editItem, #selector(ctxEdit(_:)), target: self, enabled: !item.isDirectory).representedObject = item
        menu.addItem(.separator())
        _ = add(.copyToOtherPane, #selector(ctxCopy(_:)), target: self, enabled: !item.isDirectory)
        _ = add(.moveToOtherPane, #selector(ctxMove(_:)), target: self, enabled: !item.isDirectory)
        add(.rename, #selector(ctxRename(_:)), target: self).representedObject = item
        _ = add(.moveToTrash, #selector(ctxDelete(_:)), target: self)
        menu.addItem(.separator())
        _ = add(.newDirectory, #selector(ctxNewDirectory(_:)), target: self)
        add(.share, #selector(ctxShare(_:)), target: self, enabled: !remote).representedObject = item
        return menu
    }

    /// 打开方式子菜单：urlsForApplications(toOpen:) 列出可开该本地 url 的 App。
    /// "打开方式"子菜单的一个 App 条目携带的原料：目标文件 + 用它打开的 App。
    private struct OpenWithTarget { let file: FileItem; let app: URL }

    private func buildOpenWithMenu(for item: FileItem, enabled: Bool) -> NSMenu {
        let sub = NSMenu()
        guard enabled else { return sub }
        let url = item.path.url
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
        for appURL in apps {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let it = sub.addItem(withTitle: name, action: #selector(ctxOpenWithApp(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = OpenWithTarget(file: item, app: appURL)
        }
        if apps.isEmpty {
            let none = sub.addItem(withTitle: "—", action: nil, keyEquivalent: "")
            none.isEnabled = false
        }
        return sub
    }

    /// 共享：NSSharingServicePicker 弹原生服务面板（AirDrop/邮件/信息…）。
    /// menuItems() 在本 SDK 不存在（probe 实证），show() 可用；picker 项自带
    /// target=picker，须持住 picker 本体（sharePicker）防其被释放。
    @objc private func ctxShare(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        let picker = NSSharingServicePicker(items: [item.path.url])
        sharePicker = picker
        picker.show(relativeTo: .zero, of: self, preferredEdge: .minY)
    }

    // MARK: - Context menu actions

    /// 单项操作统一走此路：**不清整组选择**（Finder 式——多选时打开/预览其一，
    /// 其余标记原样保留），只把焦点落到右键项（高亮/后续内核定位都跟着它）。
    private func focusContextItem(_ item: FileItem) {
        if let idx = pane.selection.items.firstIndex(of: item.id) {
            pane.moveFocus(to: idx, mode: .sticky)
        }
    }

    @objc private func ctxOpen(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        focusContextItem(item)
        router.execute(.enter)     // 目录→进入；文件→router.onOpen（默认程序/远端下载）
    }

    @objc private func ctxOpenWithApp(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? OpenWithTarget else { return }
        focusContextItem(t.file)
        NSWorkspace.shared.open([t.file.path.url], withApplicationAt: t.app,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func ctxReveal(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.path.url])
    }

    @objc private func ctxPreview(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        focusContextItem(item)
        router.execute(.viewFile)
    }

    @objc private func ctxEdit(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem else { return }
        focusContextItem(item)
        router.execute(.editFile)
    }

    @objc private func ctxRename(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? FileItem,
              let idx = pane.selection.items.firstIndex(of: item.id) else { return }
        pane.moveFocus(to: idx, mode: .simple)
        promptRename()
    }

    @objc private func ctxDelete(_ sender: NSMenuItem) {
        router.execute(.delete)    // 走 router.onDelete → 废纸篓确认（多选生效）
    }

    @objc private func ctxNewDirectory(_ sender: NSMenuItem) { promptMakeDirectory() }

    /// 复制/移动 = router 传输路（本窗格为源、另一侧为目标；远端自动走后台）。
    /// 菜单构建时已 activate(id)，活动窗格即本窗格，operationTargets 含整组选择。
    @objc private func ctxCopy(_ sender: NSMenuItem) { router.execute(.copy) }
    @objc private func ctxMove(_ sender: NSMenuItem) { router.execute(.move) }

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
        // 缺失 id 直接跳过（第二道防线：可见集与 items 短暂不同步时不得 trap）。
        let present = ids.compactMap { id in items[id].map { (id: id, item: $0) } }
        guard !present.isEmpty else { return [] }
        func value(_ e: (id: String, item: FileItem)) -> (String, Int64, Date) {
            (e.item.name, e.item.isDirectory ? 0 : e.item.size, e.item.modificationDate)
        }
        let sorted: [(id: String, item: FileItem)]
        switch key {
        case .name:
            // 目录优先 + 名称（与内核 selection 存储序一致 → 默认序下 display==selection）
            sorted = present.sorted { left, right in
                let li = left.item, ri = right.item
                if li.isDirectory != ri.isDirectory { return li.isDirectory && !ri.isDirectory }
                return li.name.localizedStandardCompare(ri.name) == .orderedAscending
            }
        case .size:
            sorted = present.sorted { value($0).1 != value($1).1 ? value($0).1 < value($1).1
                                                             : value($0).0.localizedStandardCompare(value($1).0) == .orderedAscending }
        case .date:
            sorted = present.sorted { value($0).2 != value($1).2 ? value($0).2 < value($1).2
                                                             : value($0).0.localizedStandardCompare(value($1).0) == .orderedAscending }
        }
        let ordered = sorted.map(\.id)
        return direction == .descending ? Array(ordered.reversed()) : ordered
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
