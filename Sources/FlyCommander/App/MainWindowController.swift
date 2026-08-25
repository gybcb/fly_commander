import AppKit

extension NSToolbarItem.Identifier {
    static let copy = NSToolbarItem.Identifier("copy")
    static let move = NSToolbarItem.Identifier("move")
    static let makeDirectory = NSToolbarItem.Identifier("makeDirectory")
    static let delete = NSToolbarItem.Identifier("delete")
    static let rename = NSToolbarItem.Identifier("rename")
    static let search = NSToolbarItem.Identifier("search")
    static let connect = NSToolbarItem.Identifier("connect")
    static let theme = NSToolbarItem.Identifier("theme")
    static let selectionStatus = NSToolbarItem.Identifier("selectionStatus")
}

/// 主窗口：拦下 Ctrl+Tab / Ctrl+Shift+Tab（keyCode 48 + .control），转发给第一响应者的
/// keyDown 并消费掉，避免 macOS 原生 window tabbing 在 sendEvent 层吞掉它。
///
/// 背景（诊断实证，详见项目记忆 reduced-sdk）：本 app 的 Ctrl+Tab 用于 TC 式标签切换
/// （PaneTableView.keyDown → .nextTab/.prevTab）。但 macOS 把 ⌃⇥/⌃⇧⇥ 占作原生
/// "显示下一/上一个窗口标签页"，在 NSWindow.sendEvent 层、firstResponder.keyDown 之前
/// 拦截。且 `tabbingMode = .disallowed` 与 `NSWindow.allowsAutomaticWindowTabbing = false`
/// 在本 SDK（Xcode 26.6 / macOS 26）下均**拦不住**该 key binding（已 probe 实证：两者都
/// 设置后 ⌃⇥ 仍到不了 keyDown）。同修饰的 ⌃Q 能进 keyDown、纯 Tab（切窗格）也能进，
/// 唯独 ⌃⇥ 被吞——故只能在此手动抢在 super.sendEvent 之前把键喂给第一响应者。
final class FlyWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 48,
           event.modifierFlags.contains(.control) {
            firstResponder?.keyDown(with: event)   // PaneTableView 处理 .nextTab/.prevTab
            return                                  // 消费掉，不交给 super（原生 tabbing 会吞）
        }
        super.sendEvent(event)
    }
}

final class MainWindowController: NSWindowController, NSToolbarDelegate {
    private var statusLabel: NSTextField?
    private weak var mainVC: MainViewController?

    convenience init() {
        let window = FlyWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        window.title = "FlyCommander"
        window.contentMinSize = NSSize(width: 760, height: 480)
        // 一并关掉原生 window tabbing（双保险；真正生效的是 FlyWindow.sendEvent 拦截）。
        window.tabbingMode = .disallowed
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
        case .connect:
            return item(id: .connect, label: "连接", symbol: "network",
                        action: #selector(MainViewController.menuConnect(_:)))
        case .theme:
            return item(id: .theme, label: "主题", symbol: "paintpalette",
                        action: #selector(MainViewController.menuTheme(_:)))
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
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .theme,
         .space, .selectionStatus]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .theme,
         .selectionStatus, .space]
    }
}
