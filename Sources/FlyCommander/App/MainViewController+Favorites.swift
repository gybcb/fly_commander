import AppKit
import TCCore

/// 目录收藏的 MainViewController 侧（独立文件防主文件膨胀；同 module extension 先例
/// = UICrossCopyDemo）。三个入口汇到两处写侧：
/// - `showFavoritesDropdown`：🔽 箭头 → FavoritesMenu 构建 → popUp（锚定按钮）。
/// - `favoriteJumpSelected`：下拉条目 → 同域 navigate / 换域 setSource(活连接) / 断连提示。
/// - `toggleFavorite(pane:)`：F2（router.onFavorite）与下拉底部切换项共用（收藏⇄取消）。
/// 目标侧别在构建菜单时打进 payload（下拉可能来自非活动侧的 🔽——跳自己侧，不抢全局焦点）。
extension MainViewController {

    /// 弹收藏下拉。目标窗格 = **本侧活动 pane**（与 🔍 筛选按钮同语义）。
    func showFavoritesDropdown(in container: SidePaneContainer) {
        let pane = tabGroup(for: container.side).activePane
        let menu = FavoritesMenu.build(
            side: container.side,
            isCurrentFavorited: favoritesStore
                .isFavorited(sourceID: pane.source.sourceID, path: pane.path.pathString),
            favorites: favoritesStore.all,
            target: self,
            jumpAction: #selector(favoriteJumpSelected(_:)),
            toggleAction: #selector(favoriteToggleCurrentSelected(_:)))
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: container.tabBar.favoritesButton.bounds.maxY + 2),
                   in: container.tabBar.favoritesButton)
    }

    @objc func favoriteJumpSelected(_ sender: NSMenuItem) {
        guard case let .jump(fav, side)? = (sender.representedObject as? PayloadHolder)?.payload else { return }
        jump(to: fav, in: tabGroup(for: side).activePane)
    }

    @objc func favoriteToggleCurrentSelected(_ sender: NSMenuItem) {
        guard case let .toggleCurrent(side)? = (sender.representedObject as? PayloadHolder)?.payload else { return }
        toggleFavorite(pane: tabGroup(for: side).activePane)
    }

    /// F2（router.onFavorite 注入点）：切换活动窗格当前目录的收藏态。loadView 接完 router 后调一次。
    func wireFavorites() {
        router.onFavorite = { [weak self] pane in self?.toggleFavorite(pane: pane) }
    }

    // MARK: - 写侧

    /// 收藏⇄取消（切换语义）。path 用 pathString（本地=绝对路径；sftp/smb=url.path）。
    func toggleFavorite(pane: FilePane) {
        let store = favoritesStore
        let sid = pane.source.sourceID, path = pane.path.pathString
        if store.isFavorited(sourceID: sid, path: path) {
            store.remove(sourceID: sid, path: path)
            setStatus(L10n.t(.favoriteRemoved))
        } else {
            store.add(sourceID: sid, path: path,
                      displayName: SidePaneContainer.tabTitle(pane.path))
            setStatus(L10n.t(.favoriteAdded))
        }
    }

    /// 跳转三分派：
    /// - 同 sourceID → navigate（本地同步 / 远端后台 stat 校验）；
    /// - 跨源且连接仍活 → setSource 换源接路径；
    /// - sftp/smb 连接已断 → 状态栏提示重连，**不自动弹连接窗**。
    func jump(to fav: DirectoryFavorite, in pane: FilePane) {
        if fav.sourceID == pane.source.sourceID {
            pane.navigate(to: fav.tcPath)
            return
        }
        if fav.sourceID == "local" {
            pane.setSource(LocalFileSource(), andPath: fav.tcPath)
            return
        }
        if fav.sourceID.hasPrefix("sftp://"), let live = ConnectionStore.shared.source(for: fav.sourceID) {
            pane.setSource(live, andPath: fav.tcPath)
            return
        }
        if fav.sourceID.hasPrefix("smb://"), let live = SMBConnectionStore.shared.source(for: fav.sourceID) {
            pane.setSource(live, andPath: fav.tcPath)
            return
        }
        setStatus(L10n.t(.favoritesNeedReconnect))
    }

    private func tabGroup(for side: PaneID) -> TabGroup {
        side == .left ? workspace.leftTabs : workspace.rightTabs
    }
}
