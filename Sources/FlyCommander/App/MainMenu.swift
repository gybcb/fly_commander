import AppKit

/// 构建 FlyCommander 的主菜单（App / 文件 / 编辑 / 查看）。
/// Cmd 组合快捷键走菜单 keyEquivalent，焦点在窗内任何控件都生效；
/// 裸 F 键（F3-F8）不能做 keyEquivalent，仍由 KeyDispatcher 处理。
enum MainMenu {
    static func build(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()

        // App 菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: L10n.t(.aboutApp), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: L10n.t(.hideApp), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        let quitItem = appMenu.addItem(withTitle: L10n.t(.quitApp), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        // 文件菜单
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: L10n.t(.menuFile))
        fileMenuItem.submenu = fileMenu
        add(fileMenu, L10n.t(.newTab), #selector(MainViewController.menuNewTab(_:)), "t", target)
        add(fileMenu, L10n.t(.closeTab), #selector(MainViewController.menuCloseTab(_:)), "w", target)
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.t(.newDirectory), #selector(MainViewController.menuNewDirectory(_:)), "n", target)
        add(fileMenu, L10n.t(.rename), #selector(MainViewController.menuRename(_:)), "r", target)
        add(fileMenu, L10n.t(.moveToTrash), #selector(MainViewController.menuTrashDelete(_:)), "\u{8}", target, .command)
        add(fileMenu, L10n.t(.copyToOtherPane), #selector(MainViewController.menuCopyToOtherPane(_:)), "", target)
        add(fileMenu, L10n.t(.moveToOtherPane), #selector(MainViewController.menuMoveToOtherPane(_:)), "", target)
        fileMenu.addItem(.separator())
        add(fileMenu, L10n.t(.sftpConnect), #selector(MainViewController.menuConnect(_:)), "", target)
        add(fileMenu, L10n.t(.smbConnect), #selector(MainViewController.menuSMBConnect(_:)), "", target)

        // 编辑菜单
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L10n.t(.menuEdit))
        editMenuItem.submenu = editMenu
        add(editMenu, L10n.t(.find), #selector(MainViewController.menuSearch(_:)), "f", target)
        add(editMenu, L10n.t(.selectAll), #selector(MainViewController.menuSelectAll(_:)), "a", target)

        // 查看菜单（裸 F 键无法做 keyEquivalent，仅显示功能入口）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: L10n.t(.menuView))
        viewMenuItem.submenu = viewMenu
        add(viewMenu, L10n.t(.preview), #selector(MainViewController.menuPreview(_:)), "", target)
        add(viewMenu, L10n.t(.editItem), #selector(MainViewController.menuEdit(_:)), "", target)
        add(viewMenu, L10n.t(.switchPane), #selector(MainViewController.menuSwitchPane(_:)), "", target)
        add(viewMenu, L10n.t(.parentDirectory), #selector(MainViewController.menuGoToParent(_:)), "", target)
        add(viewMenu, L10n.t(.themeEllipsis), #selector(MainViewController.menuTheme(_:)), "", target)

        return mainMenu
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                            _ key: String, _ target: AnyObject,
                            _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mask
        item.target = target
        return item
    }
}
