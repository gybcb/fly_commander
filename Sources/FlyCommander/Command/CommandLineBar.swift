import AppKit
import TCCore

/// TC 式底部命令栏：左 "命令:" 提示 + 输入行（首响应者在窗格表格，键入经拦截追加），
/// 右为输出行（执行结果中文回显）。高 34pt，系统色。
///
/// 输入缓冲由本视图持有（`buffer`）：窗格 keyDown 拦截字符/Backspace/Return/Esc
/// 调用 append/deleteBackward/execute/clear；鼠标点进输入框打字也走 NSTextField
/// 自己的编辑，controlTextDidChange 反向同步 buffer——两条路径最终一致。
final class CommandLineBar: NSView {
    private let input = CommandBarInputField()
    private let output = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: "命令:")

    /// 输入缓冲（焦点在字段时经 controlTextDidChange 同步；focus 在窗格时不再使用）。
    private(set) var buffer = "" { didSet { if input.stringValue != buffer { input.stringValue = buffer } } }
    /// Return 时触发（带当前 buffer 快照；本方法不自动清空，由执行方决定）。
    var onExecute: ((String) -> Void)?
    /// Enter（执行后）或 Esc（清空后）触发：把第一响应者交回活动窗格。
    var onReturnToPane: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .secondaryLabelColor
        prompt.translatesAutoresizingMaskIntoConstraints = false
        input.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        input.placeholderString = "输入命令（ls / cd / mkdir / copy / move / del / sftp / help）"
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
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            prompt.widthAnchor.constraint(equalToConstant: 36),
            input.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 4),
            input.centerYAnchor.constraint(equalTo: centerYAnchor),
            input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            output.leadingAnchor.constraint(equalTo: input.leadingAnchor),
            output.topAnchor.constraint(equalTo: input.bottomAnchor, constant: 1),
            output.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            output.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - 焦点切换（PaneTableView 右箭头 → 激活；Enter/Esc → 返回窗格）

    /// 让输入框成为第一响应者并把光标移到末尾（右箭头激活时用）。
    func activate() {
        guard let win = window else { return }
        win.makeFirstResponder(input)
        focusFieldToEnd()
    }

    /// 光标移到文本末尾（焦点刚进字段、准备续输入时）。
    func focusFieldToEnd() {
        let editor = input.currentEditor()
        editor?.selectedRange = NSRange(location: input.stringValue.count, length: 0)
    }

    // MARK: - 键入（字段获得焦点后由原生编辑驱动；controlTextDidChange 反向同步 buffer）

    func executeBuffered() {
        let line = buffer
        buffer = ""
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
        onReturnToPane?()
    }

    private func syncFromField() {
        buffer = input.stringValue
    }
}

extension CommandLineBar: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        syncFromField()
    }

    func control(_ control: NSControl, textView: NSTextView,
                doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            executeBuffered()
            onReturnToPane?()
            return true
        }
        return false
    }
}

/// 命令栏输入框：Esc 走 cancelOperation（原生 NSTextField 不处理 Esc，需覆写）。
final class CommandBarInputField: NSTextField {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}
