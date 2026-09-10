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

    /// 每列一套布局约束（互斥激活）。旧写法四视图共用一条横向链跑所有列——size 列里
    /// 隐藏的图标(16pt)+空名称标签仍占左缘 ~32pt、空日期标签占右缘，右对齐的大小文本
    /// (需 ~49pt)被挤到 cell 右缘外 ~11pt（issue #2「大小栏右边字被遮挡」）。按列只钉
    /// 该列要显示的视图，其余视图约束整套停用 → 各自铺满整格宽度。
    private var nameConstraints: [NSLayoutConstraint] = []
    private var sizeConstraints: [NSLayoutConstraint] = []
    private var dateConstraints: [NSLayoutConstraint] = []
    private var activeColumn = -1   // 已激活的列（-1=未激活）；同格只服务一列，变了才换套

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
        // 日期列对齐合同：HEAD 里 dateLabel 只钉 trailing，靠固有宽度贴 cell 右缘=视觉右
        // 对齐。改版铺满整格后必须显式 .right，否则 .natural 落到左起排=整列位置跳变。
        dateLabel.alignment = .right
        sizeLabel.textColor = .secondaryLabelColor
        dateLabel.textColor = .secondaryLabelColor
        // 名称过长须截断省略，而非把整条链顶出右缘（压缩优先级低于其它视图）。
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 大小/日期在列被拖到 min 宽时同理：截断省略，绝不溢出列缘。压缩优先级调低，
        // 让 leading/trailing 的 required 约束赢过固有宽度（否则 AutoLayout 反过来弃约束）。
        sizeLabel.lineBreakMode = .byTruncatingTail
        dateLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        [iconView, nameLabel, sizeLabel, dateLabel].forEach { addSubview($0) }

        let iconCY = iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        let iconWH_w = iconView.widthAnchor.constraint(equalToConstant: 16)
        let iconWH_h = iconView.heightAnchor.constraint(equalToConstant: 16)
        nameConstraints = [
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconCY, iconWH_w, iconWH_h,
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ]
        sizeConstraints = [
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        dateConstraints = [
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
    }

    /// 切到目标列的布局集：停用其它列约束、激活本列约束，不相关视图置隐
    /// （隐藏视图不进 AX 树也不参与命中）。同格恒服务同一列，变了才换套。
    private func applyLayout(column: Int) {
        if column == activeColumn { return }
        NSLayoutConstraint.deactivate((0...2).filter { $0 != column }.flatMap { columnConstraints($0) })
        NSLayoutConstraint.activate(columnConstraints(column))
        activeColumn = column
        iconView.isHidden = column != 0
        nameLabel.isHidden = column != 0
        sizeLabel.isHidden = column != 1
        dateLabel.isHidden = column != 2
    }

    private func columnConstraints(_ column: Int) -> [NSLayoutConstraint] {
        switch column {
        case 0: return nameConstraints
        case 1: return sizeConstraints
        default: return dateConstraints
        }
    }

    /// 按列填充内容：0=图标+名称，1=大小，其余=日期；行高亮底色三列都铺。
    func configure(item: FileItem, focus: Bool, marked: Bool, column: Int) {
        wantsLayer = true
        applyLayout(column: column)
        switch column {
        case 0:
            iconView.image = Self.cachedIcon(for: item)
            nameLabel.stringValue = item.name
        case 1:
            iconView.image = nil
            nameLabel.stringValue = ""
            sizeLabel.stringValue = item.isDirectory
                ? "" : ByteCountFormatter().string(fromByteCount: max(0, item.size))
            dateLabel.stringValue = ""
        default:
            iconView.image = nil
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
