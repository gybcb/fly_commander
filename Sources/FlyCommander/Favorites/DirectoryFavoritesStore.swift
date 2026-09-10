import Foundation
import TCCore

/// 一条目录收藏。`path` = `TCPath.pathString`（本地绝对路径 / 远端绝对路径，不含 host）；
/// 跳转时经 `tcPath` 重组完整 TCPath（远端 = sourceID 前缀 + path，SFTPSource 同款拼接）。
struct DirectoryFavorite: Codable, Equatable {
    let sourceID: String      // "local" 或 "sftp://host:port"
    let path: String          // url.path（恒以 / 开头）
    let displayName: String   // 收藏时的 tabTitle 快照

    /// 重组完整 TCPath。按 scheme 三分派：
    /// - sftp：必须走 `SFTPSource.tcPath`（逐段 percent-encode）——裸拼在含空格名上
    ///   URL(string:)==nil → TCPath 回落本地分支（静默错路由，SFTPSource:80 实证坑）；
    /// - smb：`smb://` 串走 TCPath 直解（SMBSource 以 id==pathString 维持该形态）；
    /// - local：直连。
    var tcPath: TCPath {
        if sourceID.hasPrefix("sftp://"),
           let comps = URLComponents(string: sourceID), let host = comps.host {
            return SFTPSource.tcPath(host: host, port: comps.port ?? 22, remotePath: path)
        }
        if sourceID.hasPrefix("smb://") { return TCPath("\(sourceID)\(path)") }
        return TCPath(path)
    }
}

/// 目录收藏夹持久化（完全仿 ConnectionStore.touchRecent/persistRecent 模板）：
/// 单例 + 注入 UserDefaults + Codable JSON + 去重前插，cap 20（收藏=用户策展，宽于最近连接）。
/// 放 AppKit 层——TCCore 零 UserDefaults 纪律；消费者全在 UI（TabBar 箭头下拉 / F2 快捷键）。
final class DirectoryFavoritesStore {
    static let shared = DirectoryFavoritesStore()

    private let defaults: UserDefaults
    private let storeKey = "favorites.directories"
    private static let cap = 20
    private var favorites: [DirectoryFavorite] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let list = try? JSONDecoder().decode([DirectoryFavorite].self, from: data) {
            favorites = list
        }
    }

    /// 新在前（下拉菜单显示序）。
    var all: [DirectoryFavorite] { favorites }

    func add(sourceID: String, path: String, displayName: String) {
        let fav = DirectoryFavorite(sourceID: sourceID, path: path, displayName: displayName)
        favorites.removeAll { $0.sourceID == fav.sourceID && $0.path == fav.path }
        favorites.insert(fav, at: 0)
        if favorites.count > Self.cap { favorites.removeLast(favorites.count - Self.cap) }
        persist()
    }

    func remove(sourceID: String, path: String) {
        favorites.removeAll { $0.sourceID == sourceID && $0.path == path }
        persist()
    }

    func isFavorited(sourceID: String, path: String) -> Bool {
        favorites.contains { $0.sourceID == sourceID && $0.path == path }
    }

    private func persist() {
        // UI 测试模式（-flyDisableSessionRestore）抑制落盘：夹具路径不真收藏进用户偏好。
        guard !TestIsolation.suppressPreferenceWrites else { return }
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: storeKey)
    }
}
