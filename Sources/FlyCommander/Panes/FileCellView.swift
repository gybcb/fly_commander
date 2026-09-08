import AppKit
import TCCore
import UniformTypeIdentifiers

/// 原生表格行单元：16pt 系统图标 + 名称/大小/日期 标签，两级系统色高亮。
final class FileCellView: NSTableCellView {
    let iconView = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    let dateLabel = NSTextField(labelWithString: "")

    private static let iconCache = NSCache<NSString, NSImage>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        wantsLayer = true
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        nameLabel.font = .systemFont(ofSize: 12)
        sizeLabel.font = .systemFont(ofSize: 11)
        dateLabel.font = .systemFont(ofSize: 11)
        sizeLabel.alignment = .right
        sizeLabel.textColor = .secondaryLabelColor
        dateLabel.font = .systemFont(ofSize: 11)
        dateLabel.textColor = .secondaryLabelColor
        [iconView, nameLabel, sizeLabel, dateLabel].forEach { addSubview($0) }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -6),
            sizeLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -6),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// 按列填充内容：0=图标+名称，1=大小，其余=日期；行高亮底色三列都铺。
    func configure(item: FileItem, focus: Bool, marked: Bool, column: Int) {
        wantsLayer = true
        switch column {
        case 0:
            iconView.image = Self.cachedIcon(for: item)
            iconView.isHidden = false
            nameLabel.stringValue = item.name
            sizeLabel.stringValue = ""
            dateLabel.stringValue = ""
        case 1:
            iconView.image = nil
            iconView.isHidden = true   // 隐藏的空图标不进 AX 树
            nameLabel.stringValue = ""
            sizeLabel.stringValue = item.isDirectory
                ? "" : ByteCountFormatter().string(fromByteCount: max(0, item.size))
            dateLabel.stringValue = ""
        default:
            iconView.image = nil
            iconView.isHidden = true
            nameLabel.stringValue = ""
            sizeLabel.stringValue = ""
            dateLabel.stringValue = L10n.localized(date: item.modificationDate)
        }

        if focus {
            nameLabel.textColor = .selectedControlTextColor
            nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        } else if marked {
            nameLabel.textColor = ThemeStore.shared.nameColor(for: item)
            nameLabel.font = .systemFont(ofSize: 12)
            layer?.backgroundColor = ThemeStore.shared.accentColor.withAlphaComponent(0.25).cgColor
        } else {
            nameLabel.textColor = ThemeStore.shared.nameColor(for: item)
            nameLabel.font = .systemFont(ofSize: 12)
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }

    /// 远端图标类型推导（纯函数，可单测）：目录→folder；文件按扩展名→UTType；无扩展名→data。
    static func iconType(for item: FileItem) -> UTType {
        if item.isDirectory { return .folder }
        let ext = (item.name as NSString).pathExtension
        return ext.isEmpty ? .data : (UTType(filenameExtension: ext) ?? .data)
    }

    private static func cachedIcon(for item: FileItem) -> NSImage {
        let key = item.path.pathString as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image: NSImage
        if item.path.isRemote {
            image = NSWorkspace.shared.icon(for: iconType(for: item))   // 远端无本地文件，按类型取
        } else {
            image = NSWorkspace.shared.icon(forFile: item.path.url.path) // 本地：真实 Finder 图标
        }
        image.size = NSSize(width: 16, height: 16)
        iconCache.setObject(image, forKey: key)
        return image
    }
}
