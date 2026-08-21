import AppKit
import TCCore

final class FileItemCellView: NSCollectionViewItem {
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let bgView = NSView()

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 20))
        self.view = container
        bgView.wantsLayer = true
        container.addSubview(bgView)
        container.addSubview(nameLabel)
        container.addSubview(sizeLabel)
        container.addSubview(dateLabel)

        nameLabel.font = .systemFont(ofSize: 12)
        sizeLabel.font = .systemFont(ofSize: 11)
        dateLabel.font = .systemFont(ofSize: 11)
        sizeLabel.alignment = .right

        bgView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bgView.topAnchor.constraint(equalTo: container.topAnchor),
            bgView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bgView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bgView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -6),

            sizeLabel.widthAnchor.constraint(equalToConstant: 90),
            sizeLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -6),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            dateLabel.widthAnchor.constraint(equalToConstant: 150),
            dateLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            dateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    func configure(with item: FileItem, role: FileVisualRole, dark: Bool) {
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.isDirectory ? "" : ByteCountFormatter().string(fromByteCount: max(0, item.size))
        dateLabel.stringValue = item.modificationDate.formatted(date: .abbreviated, time: .shortened)

        let text = PaneColor.text(for: role, dark: dark)
        nameLabel.textColor = text
        sizeLabel.textColor = text.withAlphaComponent(0.7)
        dateLabel.textColor = text.withAlphaComponent(0.7)

        let bold = PaneColor.isBold(role)
        nameLabel.font = bold ? .systemFont(ofSize: 12, weight: .bold) : .systemFont(ofSize: 12)
        bgView.layer?.backgroundColor = PaneColor.background(for: role, active: true, dark: dark).cgColor
    }
}
