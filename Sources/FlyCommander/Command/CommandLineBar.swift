import AppKit
import TCCore

/// TC 式底部命令栏：左 "命令:" 提示 + 输入行，右为输出行（执行结果中文回显）。高 34pt，系统色。
///
/// 默认隐藏，与 `BottomStatusBar` 同槽互换：窗格右箭头 → `activate()`（先经 `onActivate`
/// 让持有者把自己换出来）；后续键入由输入框原生编辑接管。输入框失去第一响应者
/// （回车执行 / Esc 清空 / 点表格行 / 切标签等一切回焦路径）→ `onResignFocus` →
/// 持有者收回本栏、状态栏回位。
final class CommandLineBar: NSView {
    private let input = CommandBarInputField()
    private let output = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: L10n.t(.commandBarPrompt))
    /// cd 下拉建议容器（输入行上方弹出，目录优先，前缀匹配）。
    private let dropdown = NSView()
    private let dropdownStack = NSStackView()

    /// 输入缓冲（焦点在字段时经 controlTextDidChange 同步；focus 在窗格时不再使用）。
    private(set) var buffer = "" { didSet { if input.stringValue != buffer { input.stringValue = buffer } } }
    /// Return 时触发（带当前 buffer 快照；本方法不自动清空，由执行方决定）。
    var onExecute: ((String) -> Void)?
    /// Enter（执行后）或 Esc（清空后）触发：把第一响应者交回活动窗格。
    var onReturnToPane: (() -> Void)?
    /// `activate()` 入口第一时间触发（先于 makeFirstResponder）：持有者在此把本栏
    /// 从隐藏态换出来——AppKit 拒绝把第一响应者给隐藏视图，必须先显示再聚焦。
    var onActivate: (() -> Void)?
    /// 输入框失去第一响应者（一切回焦路径的共同终点）：持有者在此收回本栏。
    var onResignFocus: (() -> Void)?
    /// Esc 清空后触发：持有者在此清掉**状态栏里的回显镜像**（回车不清——TC 语义是
    /// 回显留到下一条命令或 Esc 为止，点表格行收回同样不清）。
    var onCleared: (() -> Void)?
    /// cd 补全数据源：返回当前活动窗格所在目录的条目（app 层注入）。
    var suggestionProvider: (() -> [FileItem])?

    /// Tab 补全状态：0=未 Tab（下次给公共前缀）；>0=第 N 次循环命中。用户再键入时复位。
    private var tabCycle = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .secondaryLabelColor
        prompt.translatesAutoresizingMaskIntoConstraints = false
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.placeholderString = L10n.t(.commandBarPlaceholder)
        input.translatesAutoresizingMaskIntoConstraints = false
        input.setAccessibilityIdentifier("cmdBarInput")
        input.target = self
        input.action = #selector(fieldReturn)
        input.delegate = self
        input.onEscape = { [weak self] in self?.handleEscape() }
        output.font = .systemFont(ofSize: 11)
        output.textColor = .secondaryLabelColor
        output.lineBreakMode = .byTruncatingTail
        output.translatesAutoresizingMaskIntoConstraints = false
        output.setAccessibilityIdentifier("cmdBarOutput")

        addSubview(prompt)
        addSubview(input)
        addSubview(output)
        // cd 下拉建议：输入行上方弹出（NSView 默认不裁剪子视图 → 可延伸到窗格区域之上）。
        dropdown.translatesAutoresizingMaskIntoConstraints = false
        dropdown.wantsLayer = true
        dropdown.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        dropdown.layer?.borderColor = NSColor.separatorColor.cgColor
        dropdown.layer?.borderWidth = 0.5
        dropdown.isHidden = true
        dropdownStack.translatesAutoresizingMaskIntoConstraints = false
        dropdownStack.orientation = .vertical
        dropdownStack.alignment = .leading
        dropdownStack.spacing = 0
        dropdownStack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        dropdown.addSubview(dropdownStack)
        addSubview(dropdown)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            prompt.widthAnchor.constraint(equalToConstant: 60),
            input.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 4),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            output.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            output.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 1),
            output.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            output.heightAnchor.constraint(equalToConstant: 11),
            dropdown.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            dropdown.trailingAnchor.constraint(equalTo: input.trailingAnchor),
            dropdown.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -2),
            dropdownStack.leadingAnchor.constraint(equalTo: dropdown.leadingAnchor),
            dropdownStack.trailingAnchor.constraint(equalTo: dropdown.trailingAnchor),
            dropdownStack.topAnchor.constraint(equalTo: dropdown.topAnchor),
            dropdownStack.bottomAnchor.constraint(equalTo: dropdown.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 语言切换后重刷常驻文案：prompt/placeholder 在属性初始化时冻结，须显式重设。
    /// 输出行是当前回显（一次性），不在此重刷（切语言后下次执行自然用新语言）。
    func refreshLocalizedText() {
        prompt.stringValue = L10n.t(.commandBarPrompt)
        input.placeholderString = L10n.t(.commandBarPlaceholder)
    }

    // MARK: - 焦点切换（PaneTableView 右箭头 → 激活；Enter/Esc → 返回窗格）

    /// 让输入框成为第一响应者并把光标移到末尾（右箭头激活时用）。
    func activate() {
        onActivate?()   // 先让持有者把本栏显示出来，再聚焦（隐藏视图拿不到第一响应者）
        guard let win = window else { return }
        win.makeFirstResponder(input)
        focusFieldToEnd()
    }

    /// 光标移到文本末尾（焦点刚进字段、准备续输入时）。
    func focusFieldToEnd() {
        let editor = input.currentEditor()
        editor?.selectedRange = NSRange(location: input.stringValue.count, length: 0)
    }

    // MARK: - cd 自动补全（下拉建议 + Tab 循环）

    /// 当前是否处于可补全的 cd 态：命令名=cd 且恰有一个参数（"cd" 无参→空 prefix）。
    /// 返回该 cd 参数前缀；非 cd / 参数数≠1 / 解析失败 → nil（不补全）。
    private var cdSuggestionState: String? {
        guard let cmd = try? CommandLineParser.parse(buffer) else { return nil }
        guard cmd.name == "cd" else { return nil }
        if cmd.args.isEmpty { return "" }
        guard cmd.args.count == 1 else { return nil }
        return cmd.args[0]
    }

    private var currentSuggestions: [FileItem] = []
    /// Tab 循环候选（首次 Tab 派生，之后复用直到用户键入重置）——补全到全名后 buffer
    /// 锚定单项，若每次从 buffer 重算会让循环断裂，故循环期固定用这份候选。
    private var cdCycleList: [FileItem] = []
    private var tabCount = 0

    /// 文本变化后刷新下拉（用户键入 → 重置 Tab 循环）。
    private func updateSuggestions() {
        guard let prefix = cdSuggestionState else { hideSuggestions(); return }
        let matches = CdCompletion.matches(prefix: prefix, items: suggestionProvider?() ?? [])
        guard !matches.isEmpty else { hideSuggestions(); return }
        currentSuggestions = matches
        rebuildDropdown(matches)
        dropdown.isHidden = false
    }

    private func hideSuggestions() {
        dropdown.isHidden = true
    }

    private func rebuildDropdown(_ items: [FileItem]) {
        for v in dropdownStack.arrangedSubviews { v.removeFromSuperview() }
        for (i, item) in items.enumerated() {
            let b = NSButton(title: item.isDirectory ? item.name + "/" : item.name,
                             target: self, action: #selector(suggestionClicked(_:)))
            b.tag = i
            b.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            b.bezelStyle = .recessed
            b.alignment = .left
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setAccessibilityIdentifier("cmdBarSuggestion")
            dropdownStack.addArrangedSubview(b)
        }
    }

    @objc private func suggestionClicked(_ sender: NSButton) {
        guard sender.tag < currentSuggestions.count else { return }
        writeCdArgument(currentSuggestions[sender.tag].name)
        hideSuggestions()
        resetTabCycle()
        focusFieldToEnd()
    }

    /// 用户键入/删除时重置 Tab 循环（controlTextDidChange 调用）。
    func resetTabCycle() {
        cdCycleList = []
        tabCount = 0
    }

    /// Tab 补全：唯一→全名；多命中→首次给公共前缀、之后在候选间循环。
    /// 返回 true 表示已消费（拦截 Tab 的默认插入行为）。
    private func doTabComplete() -> Bool {
        guard let prefix = cdSuggestionState else { resetTabCycle(); return false }
        if cdCycleList.isEmpty {
            cdCycleList = CdCompletion.matches(prefix: prefix, items: suggestionProvider?() ?? [])
            tabCount = 0
        }
        guard !cdCycleList.isEmpty else { return false }
        guard let r = CdCompletion.tabComplete(matches: cdCycleList, cycleIndex: tabCount) else {
            return false
        }
        writeCdArgument(r.text)
        tabCount += 1
        updateSuggestions()
        focusFieldToEnd()
        return true
    }

    /// 把 cd 参数替换为给定文本（"cd <text>"）。text 经 encodeToken 编码为**单个
    /// token**——含空格/引号/反斜杠的文件名（如 "My Documents"）写回后仍被解析成
    /// 一个完整参数，而非被空格拆成多个导致 doCd 只取到 "My"。
    private func writeCdArgument(_ text: String) {
        buffer = "cd " + CommandLineParser.encodeToken(text)
    }

    // MARK: - 键入（字段获得焦点后由原生编辑驱动；controlTextDidChange 反向同步 buffer）

    func executeBuffered() {
        let line = buffer
        buffer = ""
        resetTabCycle()
        hideSuggestions()
        onExecute?(line)
    }

    func clearAll() {
        buffer = ""
        output.stringValue = ""
    }

    /// 执行结果回显。
    func showOutput(_ text: String?) {
        output.stringValue = text ?? ""
    }

    @objc private func fieldReturn() {
        executeBuffered()
        onReturnToPane?()
    }

    /// Esc：清空输入 + 输出，焦点返回窗格（TC 行为）。
    private func handleEscape() {
        clearAll()
        onCleared?()        // 状态栏回显镜像只在这里清（回车/点行收回不清）
        onReturnToPane?()
    }

    private func syncFromField() {
        buffer = input.stringValue
    }
}

extension CommandLineBar: NSTextFieldDelegate {
    /// 编辑结束（回车/Esc/点行/切标签…一切离开输入框的路径都经这里）→ 持有者收回本栏。
    /// **不能用输入框 resignFirstResponder**：makeFirstResponder(字段) 进入编辑态时
    /// AppKit 经 _NSEditTextCellWithOptions 会先调字段自己的 resignFirstResponder
    ///（field editor 接管 FR），激活瞬间就误触发收回（实测调用栈钉死）。
    func controlTextDidEndEditing(_ obj: Notification) {
        onResignFocus?()
    }

    func controlTextDidChange(_ obj: Notification) {
        // programmatic 写入（Tab/点击补全）经 buffer.didSet 同步 input.stringValue 后也会
        // 触发本回调——此时 buffer==input.stringValue（echo），须跳过重置，否则刚设的
        // tabCount/cdCycleList 被清 → Tab 循环断裂。真实用户编辑则二者不等。
        let wasEcho = (buffer == input.stringValue)
        syncFromField()
        if wasEcho { updateSuggestions(); return }
        resetTabCycle()
        updateSuggestions()
    }

    func control(_ control: NSControl, textView: NSTextView,
                doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            executeBuffered()
            onReturnToPane?()
            return true
        }
        if commandSelector == #selector(insertTab(_:)) {
            return doTabComplete()   // cd 态消费 Tab 做补全；非 cd 态返回 false 让 Tab 插空格
        }
        return false
    }
}

/// 命令栏输入框：Esc 走 cancelOperation（原生 NSTextField 不处理 Esc，需覆写）。
final class CommandBarInputField: NSTextField {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
