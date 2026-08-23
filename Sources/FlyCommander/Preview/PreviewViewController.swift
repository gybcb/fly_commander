import AppKit
import TCCore

final class PreviewViewController: NSViewController {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp"]
    /// 文本预览只加载文件开头这么多字节：排版/滚动开销随字符数走，
    /// 1.5MB 文件滚动已实测变慢 → 上限取 512KB 保证流畅，超出走截断横幅。
    private static let textPreviewLimit = 512 * 1024
    /// 超过此大小的文件直接走二进制降级（不再读取）。
    private static let textMaxBytes = 512 * 1024 * 1024
    /// 单行上限：TextKit 的排版量/文档高度随单行字符数走（probe 实测 524K 字符
    /// 单行 → 78645pt document view，且曾导致预览区空白）→ 超长行截到此值。
    static let textLineLimit = 32 * 1024
    /// 长行截断处的可见标记（UI 测试按此文案断言）。
    static let longLineMarker = " …（行已截断）"
    /// 这些扩展名**跳过二进制嗅探**直接按文本预览：.torrent 是 bencode 文本 +
    /// piece 哈希二进制块，哈希里的 NUL/控制字节能占到前 8KB 的 50%（多 piece 时），
    /// 任何"NUL/密度"嗅探都会误判（用户实测小 .torrent 无法预览）；哈希字节按
    /// UTF-8 解出替换符显示，可读部分（tracker/name）正常——与 TC 预览行为一致。
    static let forceTextExtensions: Set<String> = ["torrent"]

    /// 有界文本读取结果。纯 Foundation，便于单测。
    struct PreviewText {
        let text: String        // 解码后文本（≤ limit 字节，单行 ≤ textLineLimit）
        let totalBytes: Int64   // 文件实际大小
        let truncated: Bool     // 是否被字节上限截断
        let longLineTruncated: Bool  // 是否有单行被 textLineLimit 截断
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
    }

    /// Esc 关闭预览窗（NSWindow 把 cancelOperation 派发到响应链；
    /// 焦点在文本区/横幅按钮上时同样能关）。
    override func cancelOperation(_ sender: Any?) {
        view.window?.performClose(nil)
    }

    func show(item: FileItem) {
        let url = item.path.url
        let content: NSView
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            content = makeImageView(url: url)
        } else if let pt = Self.loadPreviewText(url: url, limit: Self.textPreviewLimit) {
            content = makeTextView(url: url, item: item, text: pt)
        } else {
            content = makeFallbackView(item: item)
        }
        // Swap content
        for subview in view.subviews { subview.removeFromSuperview() }
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// 只读文件开头 `limit` 字节做文本预览。
    /// - 文件 > textMaxBytes → nil（走二进制降级）
    /// - 非 `forceTextExtensions` 且 head 控制字符密度超阈值 → nil（二进制）
    /// - 读取失败 → nil
    /// - 空文件 → 空文本（正常显示空白）
    /// - 单行超过 textLineLimit → 截断该行并追加 `longLineMarker`
    static func loadPreviewText(url: URL, limit: Int) -> PreviewText? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        let total = Int64(values.fileSize ?? 0)
        guard total <= Int64(textMaxBytes) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = handle.readData(ofLength: limit)
            let forceText = Self.forceTextExtensions.contains(url.pathExtension.lowercased())
            if !forceText, !Self.isProbablyText(head) { return nil }
            let raw = String(decoding: head, as: UTF8.self)
            let (text, longLineTruncated) = truncateLongLines(raw)
            return PreviewText(text: text,
                               totalBytes: total,
                               truncated: total > Int64(head.count),
                               longLineTruncated: longLineTruncated)
        } catch {
            return nil
        }
    }

    /// 二进制判定：前 8KB 控制字符（<0x20，含 NUL；跳过 \t\r\n）密度 > 2%。
    /// "含 NUL 即二进制"会把 .torrent 这类"文本为主、夹 piece 哈希二进制块"
    /// 的文件误判为二进制（用户实测小 .torrent 无法预览）；密度阈值放行它。
    static func isProbablyText(_ head: Data) -> Bool {
        guard !head.isEmpty else { return true }
        let sniff = head.prefix(8192)
        let control = sniff.reduce(0) { total, byte in
            (byte < 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A) ? total + 1 : total
        }
        return Double(control) / Double(sniff.count) <= 0.02
    }

    /// 单行超过 `textLineLimit` 字符的行截断到上限并追加标记。
    /// 纯函数，O(n)；多行文件（各行 ≤ 上限）返回原样、标志为 false，
    /// 换行结构（含尾换行）逐字节保持。
    static func truncateLongLines(_ raw: String) -> (text: String, truncated: Bool) {
        var truncated = false
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            if line.count > textLineLimit {
                truncated = true
                return String(line.prefix(textLineLimit)) + longLineMarker
            }
            return String(line)
        }
        return (lines.joined(separator: "\n"), truncated)
    }

    private func makeTextView(url: URL, item: FileItem, text pt: PreviewText) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        guard let text = scroll.documentView as? NSTextView else {
            return makeFallbackView(item: item)
        }
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.string = pt.text
        fallbackURL = url

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        var topAnchor = container.topAnchor
        var topConstant: CGFloat = 8
        if pt.truncated || pt.longLineTruncated {
            let banner = makeTruncationBanner(totalBytes: pt.totalBytes, longLineTruncated: pt.longLineTruncated)
            container.addSubview(banner)
            banner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                banner.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
                banner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                banner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            ])
            topAnchor = banner.bottomAnchor
            topConstant = 4
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    /// 截断横幅：文案 + "用默认应用打开"小按钮（看全量内容的出口）。
    /// 横幅必须有确定性高度——label 若只 centerY 钉住，横幅高度歧义，
    /// Auto Layout 会把 scroll 压到 0 高（probe 复现：文字区消失、无滚动条）。
    private func makeTruncationBanner(totalBytes: Int64, longLineTruncated: Bool) -> NSView {
        var message = "仅显示前 \(ByteCountFormatter().string(fromByteCount: Int64(Self.textPreviewLimit)))"
            + "（文件共 \(ByteCountFormatter().string(fromByteCount: totalBytes))）"
        if longLineTruncated {
            message += "，超 \(ByteCountFormatter().string(fromByteCount: Int64(Self.textLineLimit))) 的长行已截断"
        }
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "用默认应用打开", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(openWithDefaultApplication)

        let banner = NSView()
        banner.addSubview(label)
        banner.addSubview(button)
        NSLayoutConstraint.activate([
            banner.heightAnchor.constraint(equalToConstant: 28),
            label.topAnchor.constraint(equalTo: banner.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: banner.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
        ])
        return banner
    }

    private func makeImageView(url: URL) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        if let image = NSImage(contentsOf: url) {
            let imageView = NSImageView()
            imageView.image = image
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                imageView.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
                imageView.heightAnchor.constraint(lessThanOrEqualTo: container.heightAnchor, constant: -24),
            ])
        } else {
            let label = NSTextField(labelWithString: "无法读取图片：\(url.lastPathComponent)")
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
        return container
    }

    private func makeFallbackView(item: FileItem) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "无法预览此文件")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false

        let pathLabel = NSTextField(labelWithString: item.path.displayString())
        pathLabel.font = .systemFont(ofSize: 12)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.isSelectable = true
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = NSButton(title: "用默认应用打开", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.target = self
        button.action = #selector(openWithDefaultApplication)
        fallbackURL = item.path.url

        let stack = NSStackView(views: [title, pathLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private var fallbackURL: URL?

    @objc private func openWithDefaultApplication() {
        guard let url = fallbackURL else { return }
        NSWorkspace.shared.open(url)
    }
}
