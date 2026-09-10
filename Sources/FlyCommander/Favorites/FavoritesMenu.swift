import AppKit
import TCCore

/// 收藏夹下拉的纯构建器：给定收藏列表 + 当前窗格态，产出 NSMenu（不弹窗，可 headless 测）。
/// 弹窗（popUp）与跳转动作留在 MainViewController——只有它持 workspace/store 写侧。
enum FavoritesMenu {
    /// representedObject 挂载类型：区分"跳转某收藏"与"切换当前目录收藏态"两种条目；
    /// 各自携带**发起下拉的那一侧**（非活动侧的 🔽 也要跳自己侧，动作分发回 VC 时还原）。
    enum Payload {
        case jump(DirectoryFavorite, side: PaneID)
        case toggleCurrent(side: PaneID)
    }

    /// 构建菜单。favoriteSelected/toggleFavorite 由调用方（VC）实现的 selector。
    /// 结构：各收藏项（新在前）→ separator →「收藏/取消收藏当前目录」（当前目录已收藏时带 ✓）。
    /// 空收藏：仅显示底部切换项（首点即建立第一条收藏）。
    static func build(side: PaneID,
                      isCurrentFavorited: Bool,
                      favorites: [DirectoryFavorite],
                      target: AnyObject,
                      jumpAction: Selector, toggleAction: Selector) -> NSMenu {
        let menu = NSMenu()
        for fav in favorites {
            let item = NSMenuItem(title: fav.displayName, action: jumpAction, keyEquivalent: "")
            item.target = target
            item.representedObject = PayloadHolder(.jump(fav, side: side))
            menu.addItem(item)
        }
        if !favorites.isEmpty { menu.addItem(.separator()) }
        let toggle = NSMenuItem(
            title: L10n.t(isCurrentFavorited ? .removeFavorite : .addFavorite),
            action: toggleAction, keyEquivalent: "")
        toggle.target = target
        toggle.state = isCurrentFavorited ? .on : .off
        toggle.representedObject = PayloadHolder(.toggleCurrent(side: side))
        menu.addItem(toggle)
        return menu
    }
}

/// NSMenuItem.representedObject 只接 AnyObject，故用引用盒包 enum payload。
final class PayloadHolder {
    let payload: FavoritesMenu.Payload
    init(_ payload: FavoritesMenu.Payload) { self.payload = payload }
}
