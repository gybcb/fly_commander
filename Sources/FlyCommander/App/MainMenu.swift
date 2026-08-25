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
        appMenu.addItem(withTitle: "关于 FlyCommander", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let hideItem = appMenu.addItem(withTitle: "隐藏 FlyCommander", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        let quitItem = appMenu.addItem(withTitle: "退出 FlyCommander", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp

        // 文件菜单
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "文件")
        fileMenuItem.submenu = fileMenu
        add(fileMenu, "新建标签页", #selector(MainViewController.menuNewTab(_:)), "t", target)
        add(fileMenu, "关闭标签页", #selector(MainViewController.menuCloseTab(_:)), "w", target)
        fileMenu.addItem(.separator())
        add(fileMenu, "新建目录", #selector(MainViewController.menuNewDirectory(_:)), "n", target)
        add(fileMenu, "重命名", #selector(MainViewController.menuRename(_:)), "r", target)
        add(fileMenu, "移到废纸篓", #selector(MainViewController.menuTrashDelete(_:)), "\u{8}", target, .command)
        add(fileMenu, "复制到另一窗格", #selector(MainViewController.menuCopyToOtherPane(_:)), "", target)
        add(fileMenu, "移动到另一窗格", #selector(MainViewController.menuMoveToOtherPane(_:)), "", target)
        fileMenu.addItem(.separator())
        add(fileMenu, "SFTP 连接…", #selector(MainViewController.menuConnect(_:)), "", target)

        // 编辑菜单
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        add(editMenu, "查找", #selector(MainViewController.menuSearch(_:)), "f", target)
        add(editMenu, "全选", #selector(MainViewController.menuSelectAll(_:)), "a", target)

        // 查看菜单（裸 F 键无法做 keyEquivalent，仅显示功能入口）
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "查看")
        viewMenuItem.submenu = viewMenu
        add(viewMenu, "预览", #selector(MainViewController.menuPreview(_:)), "", target)
        add(viewMenu, "编辑", #selector(MainViewController.menuEdit(_:)), "", target)
        add(viewMenu, "切换窗格", #selector(MainViewController.menuSwitchPane(_:)), "", target)
        add(viewMenu, "上级目录", #selector(MainViewController.menuGoToParent(_:)), "", target)
        add(viewMenu, "主题…", #selector(MainViewController.menuTheme(_:)), "", target)

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
