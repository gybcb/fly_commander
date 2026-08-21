import AppKit

final class CommandBar: NSView {
    private let prompt = NSTextField(labelWithString: "> ")
    private let path = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1

        prompt.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        path.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        for v in [prompt, path, status] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            prompt.centerYAnchor.constraint(equalTo: centerYAnchor),
            path.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 2),
            path.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            path.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPath(_ p: String, selected: Int) {
        path.stringValue = p + (selected > 0 ? "  (\(selected))" : "")
    }

    func setStatus(_ s: String) {
        status.stringValue = s
    }
}
