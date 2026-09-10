import AppKit
import TCCore

extension NSToolbarItem.Identifier {
    static let copy = NSToolbarItem.Identifier("copy")
    static let move = NSToolbarItem.Identifier("move")
    static let makeDirectory = NSToolbarItem.Identifier("makeDirectory")
    static let delete = NSToolbarItem.Identifier("delete")
    static let rename = NSToolbarItem.Identifier("rename")
    static let search = NSToolbarItem.Identifier("search")
    static let connect = NSToolbarItem.Identifier("connect")
    static let smbConnect = NSToolbarItem.Identifier("smbConnect")
    static let theme = NSToolbarItem.Identifier("theme")
    static let selectionStatus = NSToolbarItem.Identifier("selectionStatus")
}

/// 文本输入控件需要接管 ⌃⇥ 时的可选协议。输入框聚焦时 firstResponder 是 field editor
/// （NSTextView），事件到不了输入框自身，故由 FlyWindow 解到其 delegate 再投递（探针实证）。
protocol ControlTabRouting: NSResponder {
    /// 返回 true = 已消费该键。
    func handleControlTab(shift: Bool) -> Bool
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
            // 输入框聚焦时 firstResponder 是 field editor（NSTextView），⌃⇥ 到不了输入框
            // 自身；解到其 delegate，若它 opt-in 了 ControlTabRouting 就投递给它
            // （方向从 event 本体取，不用 NSApp.currentEvent——测试直调 sendEvent 时其为 nil）。
            if let routed = (firstResponder as? NSTextView)?.delegate as? ControlTabRouting,
               routed.handleControlTab(shift: event.modifierFlags.contains(.shift)) {
                return
            }
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

    /// identifier → 文案键。工具栏项 label/toolTip 在 delegate 建 item 时一次性冻结，
    /// 切语言后须据此重刷。唯一不带此 label 的 .selectionStatus（状态文本 view，label 恒空）
    /// 故意不入映射 → 重刷时自然跳过。纯函数，供单测断言各语言映射。
    static let toolbarLabelKeys: [NSToolbarItem.Identifier: L10nKey] = [
        .copy: .toolbarCopy, .move: .toolbarMove, .makeDirectory: .newDirectory,
        .delete: .toolbarDelete, .rename: .rename, .search: .find,
        .connect: .toolbarConnect, .smbConnect: .toolbarSMB, .theme: .toolbarTheme,
    ]

    /// 纯函数：给定语言下各工具栏项的 label（走 L10n 表兜底：本语言缺→en 缺→rawValue）。
    static func toolbarLabels(lang: Language) -> [NSToolbarItem.Identifier: String] {
        let table = lang == .en ? L10nTable.en : L10nTable.zh
        return toolbarLabelKeys.mapValues { table[$0] ?? L10nTable.en[$0] ?? $0.rawValue }
    }

    /// 语言切换后重刷工具栏 label/toolTip：按稳定 identifier 找回项、查当前语言表重设。
    /// .selectionStatus（无映射）跳过，保持其空 label 语义。
    func refreshLocalizedLabels() {
        let labels = MainWindowController.toolbarLabels(lang: L10n.current)
        for item in window?.toolbar?.items ?? [] {
            guard let label = labels[item.itemIdentifier] else { continue }
            item.label = label
            item.toolTip = label
        }
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
            return item(id: .copy, label: L10n.t(.toolbarCopy), symbol: "doc.on.doc",
                        action: #selector(MainViewController.menuCopyToOtherPane(_:)))
        case .move:
            return item(id: .move, label: L10n.t(.toolbarMove), symbol: "arrow.left.arrow.right",
                        action: #selector(MainViewController.menuMoveToOtherPane(_:)))
        case .makeDirectory:
            return item(id: .makeDirectory, label: L10n.t(.newDirectory), symbol: "folder.badge.plus",
                        action: #selector(MainViewController.menuNewDirectory(_:)))
        case .delete:
            return item(id: .delete, label: L10n.t(.toolbarDelete), symbol: "trash",
                        action: #selector(MainViewController.menuTrashDelete(_:)))
        case .rename:
            return item(id: .rename, label: L10n.t(.rename), symbol: "pencil",
                        action: #selector(MainViewController.menuRename(_:)))
        case .search:
            return item(id: .search, label: L10n.t(.find), symbol: "magnifyingglass",
                        action: #selector(MainViewController.menuSearch(_:)))
        case .connect:
            return item(id: .connect, label: L10n.t(.toolbarConnect), symbol: "network",
                        action: #selector(MainViewController.menuConnect(_:)))
        case .smbConnect:
            return item(id: .smbConnect, label: L10n.t(.toolbarSMB), symbol: "server.rack",
                        action: #selector(MainViewController.menuSMBConnect(_:)))
        case .theme:
            return item(id: .theme, label: L10n.t(.toolbarTheme), symbol: "paintpalette",
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
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .smbConnect, .theme,
         .space, .selectionStatus]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.copy, .move, .makeDirectory, .delete, .rename, .search, .connect, .smbConnect, .theme,
         .selectionStatus, .space]
    }
}
