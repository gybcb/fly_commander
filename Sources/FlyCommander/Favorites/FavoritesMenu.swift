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
    /// 结构：各编号收藏项（新在前）→ separator →「收藏/取消收藏当前目录」（当前目录已收藏时带 ✓）。
    /// 空收藏：仅显示底部切换项（首点即建立第一条收藏）。
    ///
    /// 编号与数字跳转（真窗 spike 实证后定档，见 UITests/FavoritesAndHiddenUITests 类注释）：
    /// 标题 `N. 名称`，前 9 条另挂裸数字 keyEquivalent（mask 必显式清空——NSMenuItem 缺省
    /// mask 是 ⌘，不清等于做成 ⌘N）。**实测：弹出菜单的 tracking loop 对裸键走 type-select
    /// （按标题首字符前缀匹配 → 高亮该条），不触发 keyEquivalent**（A 案判负）；子类化 NSMenu
    /// 覆写 performKeyEquivalent 也拿不到裸键（tracking loop 根本不调它，C 案判负）。故最终
    /// 落 **B 档：按数字 → type-select 高亮对应条目 → 回车跳转**（非「按下即跳」）。keyEquivalent
    /// 保留：它在菜单右列显示数字提示（视觉锚点），且 mask 空不与命令行栏/主菜单冲突。
    /// 10~20 条（store cap 超出 1~9）仅显示序号，无键可绑。裸数字仅在菜单打开时可达——
    /// keyEquivalent 全局扫描只扫主菜单，本菜单是 popUp 出去的游离菜单，关闭态零劫持，
    /// 窗格焦点时裸数字照常走 type-ahead 字母导航（命令栏仅右箭头激活）。切换项不编号、
    /// keyEquivalent 恒空。
    static func build(side: PaneID,
                      isCurrentFavorited: Bool,
                      favorites: [DirectoryFavorite],
                      target: AnyObject,
                      jumpAction: Selector, toggleAction: Selector) -> NSMenu {
        let menu = NSMenu()
        for (idx, fav) in favorites.enumerated() {
            let key = idx < 9 ? String(idx + 1) : ""
            let item = NSMenuItem(title: "\(idx + 1). \(fav.displayName)", action: jumpAction, keyEquivalent: key)
            if !key.isEmpty { item.keyEquivalentModifierMask = [] }
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
