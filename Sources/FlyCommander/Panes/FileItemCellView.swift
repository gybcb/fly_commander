import AppKit
import TCCore

/// Lets a cell ask its owning pane view to re-apply column widths to every
/// visible cell while a drag is in flight.
protocol FileItemCellDelegate: AnyObject {
    func fileItemCellDidChangeColumns(_ cell: FileItemCellView)
}

final class FileItemCellView: NSCollectionViewItem {
    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let bgView = NSView()
    weak var cellDelegate: FileItemCellDelegate?

    private var sizeWidthConstraint: NSLayoutConstraint!
    private var dateWidthConstraint: NSLayoutConstraint!

    private var draggingColumn: Column?
    private var dragStartX: CGFloat = 0
    private var dragStartWidth: CGFloat = 0

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 22))
        self.view = container
        bgView.wantsLayer = true
        bgView.layer?.cornerRadius = 2
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

            sizeLabel.trailingAnchor.constraint(equalTo: dateLabel.leadingAnchor, constant: -6),
            sizeLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            dateLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            dateLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        sizeWidthConstraint = sizeLabel.widthAnchor.constraint(equalToConstant: PaneColumnLayout.defaultSize)
        dateWidthConstraint = dateLabel.widthAnchor.constraint(equalToConstant: PaneColumnLayout.defaultDate)
        sizeWidthConstraint.isActive = true
        dateWidthConstraint.isActive = true

        installResizeHandle(on: container, atLeftEdgeOf: sizeLabel, column: .size)
        installResizeHandle(on: container, atLeftEdgeOf: dateLabel, column: .date)
    }

    // MARK: - Column widths

    enum Column: Hashable { case size, date }

    private func installResizeHandle(on container: NSView, atLeftEdgeOf label: NSView, column: Column) {
        let handle = ColumnResizeHandle()
        handle.column = column
        handle.cell = self
        handle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(handle)
        NSLayoutConstraint.activate([
            handle.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            handle.topAnchor.constraint(equalTo: container.topAnchor),
            handle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
        ])
    }

    func applyColumnWidths(size: CGFloat, date: CGFloat) {
        sizeWidthConstraint.constant = size
        dateWidthConstraint.constant = date
    }

    // MARK: - Dragging (called by ColumnResizeHandle)

    func beginResize(column: Column, atWindowX x: CGFloat) {
        draggingColumn = column
        dragStartX = x
        let layout = PaneColumnLayout()
        dragStartWidth = column == .size ? layout.sizeWidth : layout.dateWidth
    }

    func updateResize(atWindowX x: CGFloat) {
        guard let column = draggingColumn else { return }
        // The handle sits on the left edge of the column: dragging right
        // moves that edge right, so the column gets NARROWER.
        let newWidth = dragStartWidth - (x - dragStartX)
        let layout = PaneColumnLayout()
        switch column {
        case .size: layout.sizeWidth = newWidth
        case .date: layout.dateWidth = newWidth
        }
        applyColumnWidths(size: layout.sizeWidth, date: layout.dateWidth)
        cellDelegate?.fileItemCellDidChangeColumns(self)
    }

    func endResize() { draggingColumn = nil }

    func resetColumn(_ column: Column) {
        let layout = PaneColumnLayout()
        switch column {
        case .size: layout.sizeWidth = PaneColumnLayout.defaultSize
        case .date: layout.dateWidth = PaneColumnLayout.defaultDate
        }
        applyColumnWidths(size: layout.sizeWidth, date: layout.dateWidth)
        cellDelegate?.fileItemCellDidChangeColumns(self)
    }

    // MARK: - Content

    func configure(with item: FileItem, role: FileVisualRole, dark: Bool) {
        nameLabel.stringValue = item.name
        sizeLabel.stringValue = item.isDirectory ? "" : ByteCountFormatter().string(fromByteCount: max(0, item.size))
        dateLabel.stringValue = item.modificationDate.formatted(date: .abbreviated, time: .shortened)

        let text = PaneColor.text(for: role, dark: dark)
        nameLabel.textColor = text
        sizeLabel.textColor = .secondaryLabelColor
        dateLabel.textColor = .secondaryLabelColor

        let bold = PaneColor.isBold(role)
        nameLabel.font = bold ? .systemFont(ofSize: 12, weight: .bold) : .systemFont(ofSize: 12)
        bgView.layer?.backgroundColor = PaneColor.background(for: role, active: true, dark: dark).cgColor
        if let borderColor = PaneColor.border(for: role) {
            bgView.layer?.borderColor = borderColor.cgColor
            bgView.layer?.borderWidth = 1
        } else {
            bgView.layer?.borderWidth = 0
        }
    }
}

/// Transparent 5pt strip on a column boundary; drags resize the column,
/// double-click restores its default width.
final class ColumnResizeHandle: NSView {
    var column: FileItemCellView.Column = .size
    weak var cell: FileItemCellView?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let cell else { return }
        if event.clickCount >= 2 {
            cell.resetColumn(column)
            return
        }
        cell.beginResize(column: column, atWindowX: event.locationInWindow.x)
    }

    override func mouseDragged(with event: NSEvent) {
        cell?.updateResize(atWindowX: event.locationInWindow.x)
    }

    override func mouseUp(with event: NSEvent) {
        cell?.endResize()
    }
}
