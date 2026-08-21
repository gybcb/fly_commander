import AppKit
import TCCore

final class PreviewViewController: NSViewController {
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "tif", "bmp", "webp"]
    private static let textSniffSize = 8192
    private static let textMaxBytes = 512 * 1024 * 1024

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
    }

    func show(item: FileItem) {
        let content: NSView
        switch Self.classify(url: item.path.url) {
        case .text:
            content = makeTextView(url: item.path.url)
        case .image:
            content = makeImageView(url: item.path.url)
        case .binary:
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

    private enum Kind { case text, image, binary }

    private static func classify(url: URL) -> Kind {
        if imageExtensions.contains(url.pathExtension.lowercased()) { return .image }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: textSniffSize)) ?? Data()
            return !head.isEmpty && head.contains(0) ? .binary : .text
        } catch {
            return .binary
        }
    }

    private func makeTextView(url: URL) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.isRichText = false
        text.autoresizingMask = []
        text.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = text

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])

        let data = Self.readLimited(url: url, limit: Self.textMaxBytes)
        text.string = String(decoding: data, as: UTF8.self)
        return container
    }

    private static func readLimited(url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        var data = Data()
        while data.count < limit {
            let chunk = (try? handle.read(upToCount: min(1 << 20, limit - data.count))) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
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
