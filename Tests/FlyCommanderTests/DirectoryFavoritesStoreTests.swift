import XCTest
@testable import FlyCommander
import TCCore

/// DirectoryFavoritesStore 回归（仿 ConnectionStore 持久化模板的测试面）。
/// 总变异锚：删 add 里的 `removeAll` 去重 → dedup 用例红；cap 判断改 >10 → cap 用例红；
/// persist 不写 → round-trip 用例红。
final class DirectoryFavoritesStoreTests: XCTestCase {
    var suite: UserDefaults!
    var suiteName: String!
    var store: DirectoryFavoritesStore!

    override func setUp() {
        super.setUp()
        suiteName = "favorites.test.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)!
        store = DirectoryFavoritesStore(defaults: suite)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
        suite = nil; store = nil
        super.tearDown()
    }

    /// 重复收藏同一路径 → 单条目且置顶（最近收藏排最前）。
    /// 变异：add 去掉 removeAll → 出现两条；去掉 insert(at: 0) → 顺序颠倒，均红。
    func testAddDedupAndPrepend() {
        store.add(sourceID: "local", path: "/a", displayName: "a")
        store.add(sourceID: "local", path: "/b", displayName: "b")
        store.add(sourceID: "local", path: "/a", displayName: "a-renamed")
        XCTAssertEqual(store.all.count, 2)
        XCTAssertEqual(store.all.first?.path, "/a", "重新收藏应置顶")
        XCTAssertEqual(store.all.first?.displayName, "a-renamed", "去重=整条替换（快照更新）")
    }

    /// 上限 20：加 21 条 → 最旧被逐出，最新在前。
    /// 变异：cap 改 10 → 断 count==20 红；removeLast 数量算错 → 首条序错乱红。
    func testCapTwenty() {
        for i in 1...21 { store.add(sourceID: "local", path: "/p\(i)", displayName: "p\(i)") }
        XCTAssertEqual(store.all.count, 20)
        XCTAssertEqual(store.all.first?.path, "/p21")
        XCTAssertFalse(store.isFavorited(sourceID: "local", path: "/p1"), "最旧被逐出")
    }

    /// sourceID+path 联合键：同 path 不同源互不去重（本地 /a ≠ sftp 的 /a）。
    /// 变异：去重条件丢 sourceID → 两条塌成一条，本用例红。
    func testSamePathDifferentSourceBothKept() {
        store.add(sourceID: "local", path: "/a", displayName: "local-a")
        store.add(sourceID: "sftp://h:22", path: "/a", displayName: "remote-a")
        XCTAssertEqual(store.all.count, 2)
    }

    /// remove 精确命中 + isFavorited 前后翻转。
    /// 变异：remove 条件写反（保留而非删除）→ count 仍 2，红。
    func testRemoveAndIsFavorited() {
        store.add(sourceID: "local", path: "/a", displayName: "a")
        XCTAssertTrue(store.isFavorited(sourceID: "local", path: "/a"))
        store.remove(sourceID: "local", path: "/a")
        XCTAssertFalse(store.isFavorited(sourceID: "local", path: "/a"))
        XCTAssertTrue(store.all.isEmpty)
    }

    /// 持久化 round-trip：同 suite 重建 store → 列表还原（JSON 落 UserDefaults）。
    /// 变异：persist 不写键 / decode 失败静默丢 → 第二实例为空，红。
    func testPersistenceRoundTrip() {
        store.add(sourceID: "sftp://h:2222", path: "/srv/data", displayName: "h:2222/srv/data")
        store.add(sourceID: "local", path: "/Users/me/x", displayName: "x")
        let revived = DirectoryFavoritesStore(defaults: suite)
        XCTAssertEqual(revived.all.count, 2)
        XCTAssertEqual(revived.all.first?.path, "/Users/me/x", "最新在前")
        XCTAssertEqual(revived.all.last?.sourceID, "sftp://h:2222")
        XCTAssertTrue(revived.isFavorited(sourceID: "local", path: "/Users/me/x"))
    }

    /// 远端 tcPath 重组必须 percent-encode 往返（SFTPSource.tcPath 先例；裸拼在
    /// 含空格名上 URL(string:)==nil → 静默错路由）。本地走直连 TCPath。
    /// 变异：tcPath 改回裸拼 "\(sourceID)\(path)" → 空格路径 url 变 nil/错路由，红。
    func testTcPathRebuild() {
        let local = DirectoryFavorite(sourceID: "local", path: "/Users/me/x", displayName: "x")
        XCTAssertEqual(local.tcPath.pathString, "/Users/me/x")
        XCTAssertFalse(local.tcPath.isRemote)
        let remote = DirectoryFavorite(sourceID: "sftp://h:2222", path: "/srv/my data", displayName: "d")
        XCTAssertTrue(remote.tcPath.isRemote)
        XCTAssertEqual(remote.tcPath.pathString, "/srv/my data", "编码往返后解码还原")
        XCTAssertEqual(remote.tcPath.url.host, "h")
        XCTAssertEqual(remote.tcPath.url.port, 2222)
        let smb = DirectoryFavorite(sourceID: "smb://srv/share", path: "/docs", displayName: "s")
        XCTAssertTrue(smb.tcPath.isRemote)
        XCTAssertEqual(smb.tcPath.url.scheme, "smb")
        XCTAssertEqual(smb.tcPath.url.host, "srv")
        XCTAssertEqual(smb.tcPath.pathString, "/share/docs", "smb://server/share/path 直解")
    }
}
