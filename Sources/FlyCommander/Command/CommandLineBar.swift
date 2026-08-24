import AppKit
import TCCore

/// TC 式底部命令栏：左 "命令:" 提示 + 输入行（首响应者在窗格表格，键入经拦截追加），
/// 右为输出行（执行结果中文回显）。高 34pt，系统色。
///
/// 输入缓冲由本视图持有（`buffer`）：窗格 keyDown 拦截字符/Backspace/Return/Esc
/// 调用 append/deleteBackward/execute/clear；鼠标点进输入框打字也走 NSTextField
/// 自己的编辑，controlTextDidChange 反向同步 buffer——两条路径最终一致。
final class CommandLineBar: NSView {
    private let input = NSTextField()
    private let output = NSTextField(labelWithString: "")
    private let prompt = NSTextField(labelWithString: "命令:")

    /// 输入缓冲（首响应者在窗格时经 keyDown 拦截更新）。
    private(set) var buffer = "" { didSet { if input.stringValue != buffer { input.stringValue = buffer } } }
    /// Return 时触发（带当前 buffer 快照；本方法不自动清空，由执行方决定）。
    var onExecute: ((String) -> Void)?
    /// Esc 时触发（清空输入 + 输出由 MainViewController 决定）。
    var onClear: (() -> Void)?

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

    // MARK: - 键入拦截入口（PaneTableView.keyDown 调用）

    func append(_ text: String) {
        buffer.append(text)
    }

    func deleteBackward() {
        guard !buffer.isEmpty else { return }
        buffer.removeLast()
    }

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
            return true
        }
        return false
    }
}
