import AppKit

extension NSToolbarItem.Identifier {
    static let copy = NSToolbarItem.Identifier("copy")
    static let move = NSToolbarItem.Identifier("move")
    static let makeDirectory = NSToolbarItem.Identifier("makeDirectory")
    static let delete = NSToolbarItem.Identifier("delete")
    static let rename = NSToolbarItem.Identifier("rename")
    static let search = NSToolbarItem.Identifier("search")
    static let selectionStatus = NSToolbarItem.Identifier("selectionStatus")
}

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private var statusLabel: NSTextField?
    private weak var mainVC: MainViewController?

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FlyCommander"
        window.contentMinSize = NSSize(width: 760, height: 480)
        let vc = MainViewController()
        window.contentViewController = vc
        self.init(window: window)
        mainVC = vc
        window.initialFirstResponder = vc.initialKeyView
        setupToolbar()
        window.center()
    }

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "FlyCommanderToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func item(id: NSToolbarItem.Identifier, label: String, symbol: String,
                      action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = mainVC
        item.action = action
        return item
    }

    // MARK: - NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .copy:
            return item(id: .copy, label: "复制", symbol: "doc.on.doc",
                        action: #selector(MainViewController.menuCopyToOtherPane(_:)))
        case .move:
            return item(id: .move, label: "移动", symbol: "arrow.left.arrow.right",
                        action: #selector(MainViewController.menuMoveToOtherPane(_:)))
        case .makeDirectory:
            return item(id: .makeDirectory, label: "新建目录", symbol: "folder.badge.plus",
                        action: #selector(MainViewController.menuNewDirectory(_:)))
        case .delete:
            return item(id: .delete, label: "删除", symbol: "trash",
                        action: #selector(MainViewController.menuTrashDelete(_:)))
        case .rename:
            return item(id: .rename, label: "重命名", symbol: "pencil",
                        action: #selector(MainViewController.menuRename(_:)))
        case .search:
            return item(id: .search, label: "查找", symbol: "magnifyingglass",
                        action: #selector(MainViewController.menuSearch(_:)))
        case .selectionStatus:
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            let item = NSToolbarItem(itemIdentifier: .selectionStatus)
            item.view = label
            item.label = ""
            statusLabel = label
            mainVC?.attachStatusLabel(label)
            return item
        default:
            return nil
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search,
         .space, .selectionStatus]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search,
         .selectionStatus, .space]
    }
}
