import AppKit
import Foundation

final class StatusBar: NSView {
    private let left = NSTextField(labelWithString: "")
    private let right = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        left.font = .systemFont(ofSize: 10)
        left.textColor = .secondaryLabelColor
        right.font = .systemFont(ofSize: 10)
        right.textColor = .secondaryLabelColor
        right.alignment = .right

        left.translatesAutoresizingMaskIntoConstraints = false
        right.translatesAutoresizingMaskIntoConstraints = false
        addSubview(left)
        addSubview(right)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            left.centerYAnchor.constraint(equalTo: centerYAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(diskFree: Int64, selected: Int, totalBytes: Int64) {
        left.stringValue = "磁盘可用 " + ByteCountFormatter().string(fromByteCount: max(0, diskFree))
        right.stringValue = selected > 0
            ? "选中 \(selected) 项 · \(ByteCountFormatter().string(fromByteCount: max(0, totalBytes)))"
            : ""
    }
}
