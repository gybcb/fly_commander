import AppKit
import TCCore

/// 底部常驻状态栏（与命令行同槽互换，34pt）：
/// - 左 `info`：焦点文件「名 · 大小 · 日期」；有标记时换成「已选 N 项 · 合计 …」
///   （门禁是 `selection.marked` 非空——`operationIDs` 无标记时回退 [focusID]，
///   纯焦点会被误报「已选 1 项」，见 SelectionModel.swift:43）。
/// - 右 `message`：命令回显镜像（命令行收回后回显仍可见，TC 语义）。多行拍平成 " · "。
///
/// 显示/隐藏由 `MainViewController.setCommandLineVisible` 统一翻转（本视图自身不决定去留）。
final class BottomStatusBar: NSView {
    static let height: CGFloat = 34

    private let info = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        info.font = .systemFont(ofSize: 12)
        info.textColor = .labelColor
        info.lineBreakMode = .byTruncatingTail
        info.translatesAutoresizingMaskIntoConstraints = false
        info.setAccessibilityIdentifier("bottomStatus")

        message.font = .systemFont(ofSize: 11)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        message.translatesAutoresizingMaskIntoConstraints = false
        message.setAccessibilityIdentifier("bottomStatusMessage")

        addSubview(info)
        addSubview(message)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            info.centerYAnchor.constraint(equalTo: centerYAnchor),
            info.trailingAnchor.constraint(equalTo: message.leadingAnchor, constant: -8),
            message.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 回显最长不超四成宽：防 help 长清单把文件行挤没。
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 左栏：多选汇总优先于焦点行（selectionInfo 非空即覆盖）。
    func show(fileInfo: String, selectionInfo: String?) {
        info.stringValue = selectionInfo ?? fileInfo
    }

    /// 右栏命令回显：多行（help 清单）拍平成单行，防撑破 34pt。
    func showMessage(_ text: String?) {
        guard let text, !text.isEmpty else { message.stringValue = ""; return }
        message.stringValue = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .joined(separator: " · ")
    }

    /// 语言切换重刷：文案都是组装时定格的中文字符串，由调用方（updateBars）重算即可；
    /// 本方法留作与 CommandLineBar.refreshLocalizedText 对齐的钩子（当前无静态常驻文案）。
    func refreshLocalizedText() {}
}
