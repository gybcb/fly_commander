import AppKit
import TCCore

/// 目录收藏的 MainViewController 侧（独立文件防主文件膨胀；同 module extension 先例
/// = UICrossCopyDemo）。两个入口汇到同一处呈现：
/// - `showFavoritesDropdown`：🔽 箭头 **与 F2（router.onOpenFavoritesMenu）共用**——
///   F2 弹活动侧，🔽 弹自己那侧（可能是非活动侧），二者经同一 presenter。
/// - `favoriteJumpSelected`：下拉条目 → 同域 navigate / 换域 setSource(活连接) / 断连提示。
/// - `toggleFavorite(pane:)`：下拉底部切换项（收藏⇄取消）。F2 不再直切收藏，
///   切换动作收进菜单内。弹出菜单**无默认高亮**（预置高亮三路全灭，见 FavoritesMenu
///   注释的 spike 定档）——切换项靠鼠标点击到达，回车空操作。
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
        let present = favoritesMenuPresenter ?? { container, menu in
            // positioning: nil —— 真窗 spike 实证「预置默认高亮」三路全灭：私有 setter 与
            // KVC 均不可用（headless 探针），popUp(positioning: 切换项) 也不产生高亮
            // （回车空操作，S3a 判负），且它会把菜单锚到末项改几何。回落 nil：弹出无高亮，
            // 回车空操作（安全，不会误跳第一条收藏）。
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: container.tabBar.favoritesButton.bounds.maxY + 2),
                       in: container.tabBar.favoritesButton)
        }
        present(container, menu)
    }

    @objc func favoriteJumpSelected(_ sender: NSMenuItem) {
        guard case let .jump(fav, side)? = (sender.representedObject as? PayloadHolder)?.payload else { return }
        jump(to: fav, in: tabGroup(for: side).activePane)
    }

    @objc func favoriteToggleCurrentSelected(_ sender: NSMenuItem) {
        guard case let .toggleCurrent(side)? = (sender.representedObject as? PayloadHolder)?.payload else { return }
        toggleFavorite(pane: tabGroup(for: side).activePane)
    }

    /// F2（router.onOpenFavoritesMenu 注入点）：弹**活动侧**收藏下拉——与点活动侧 🔽 完全
    /// 等价。router 只递来 activePane（TCCore 零 AppKit），用 pane.id 还原容器。loadView 接完 router 后调一次。
    func wireFavorites() {
        router.onOpenFavoritesMenu = { [weak self] pane in
            guard let self else { return }
            self.showFavoritesDropdown(in: pane.id == .left ? self.leftContainer : self.rightContainer)
        }
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
        // 评审 C2：换源后 setSource 内部走 loadAsync，注销（onReload→noteReloaded）要等
        // 网络回包——RTT 窗口里旧 fileURL 流仍会驱动**同步** load。换源后**同步**补一次
        // noteReloaded：此刻 path 已是新值，非 fileURL 立即注销（local 分支则立即换挂）。
        // loadAsync 回包时 onReload 再入一次，同路径 no-op，无害。
        if fav.sourceID == "local" {
            pane.setSource(LocalFileSource(), andPath: fav.tcPath)
            directoryWatcher.noteReloaded(pane)
            return
        }
        if fav.sourceID.hasPrefix("sftp://"), let live = ConnectionStore.shared.source(for: fav.sourceID) {
            pane.setSource(live, andPath: fav.tcPath)
            directoryWatcher.noteReloaded(pane)
            return
        }
        if fav.sourceID.hasPrefix("smb://"), let live = SMBConnectionStore.shared.source(for: fav.sourceID) {
            pane.setSource(live, andPath: fav.tcPath)
            directoryWatcher.noteReloaded(pane)
            return
        }
        // ftp：没有「活连接池」可复用（FTPSource 自建自管控制连接），按已保存条目重建一条。
        // 只建对象不建连——FTPSource 首次操作才懒连（同 SFTPSource 语义），故主线程不阻塞；
        // 失败在 loadAsync 回包时落状态栏，与 sftp/smb 分支同一体验。
        // （不走 FTPConnectionFactory.connect：它同步阻塞当前线程，主线程调用会冻结 runloop。）
        if fav.sourceID.hasPrefix("ftp://"),
           let record = RemoteConnectionStore.shared.record(forSourceID: fav.sourceID),
           let host = record.host, !host.isEmpty {
            let secret = try? RemoteConnectionStore.shared.loadSecret(for: record)
            let source = FTPSource(config: FTPClient.Config(host: host,
                                                            port: UInt16(record.port ?? 21),
                                                            username: record.username,
                                                            password: secret,
                                                            tls: record.tls ?? false))
            pane.setSource(source, andPath: fav.tcPath)
            directoryWatcher.noteReloaded(pane)
            return
        }
        setStatus(L10n.t(.favoritesNeedReconnect))
    }

    private func tabGroup(for side: PaneID) -> TabGroup {
        side == .left ? workspace.leftTabs : workspace.rightTabs
    }
}
