import XCTest
import AppKit
import TCCore
@testable import FlyCommander

// MARK: - 假事件源/工厂（接缝注入：协议契约 = onEvent 在主线程回调）

private final class FakeSource: DirectoryEventSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    let path: URL
    let onEvent: ([DirectoryEvent]) -> Void
    init(path: URL, onEvent: @escaping ([DirectoryEvent]) -> Void) {
        self.path = path; self.onEvent = onEvent
    }
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    /// 测试驱动点：模拟 FSEvents 回调批（契约=主线程；测试线程即主线程）。
    func fire(paths: [String], flags: FSEventStreamEventFlags = 0) {
        onEvent(paths.map { DirectoryEvent(path: $0, flags: flags) })
    }
}

private final class FakeFactory: DirectoryEventSourceFactory {
    private(set) var made: [FakeSource] = []
    func makeSource(path: URL, onEvent: @escaping ([DirectoryEvent]) -> Void) -> DirectoryEventSource {
        let s = FakeSource(path: path, onEvent: onEvent)
        made.append(s)
        return s
    }
}

/// 嗅探源：记录 listDirectory **落在主线程**的调用次数——协调器若违约对远端化窗格
/// 同步 load，这就是可观测面（合法异步路的 listDirectory 在 pane 专用队列，不计）。
private final class SniffSource: FileSource {
    let sourceID = "sftp://h:22"
    var isRemote = true
    var supportsTransfer: Bool { false }
    private(set) var mainThreadLoads = 0
    func listDirectory(_ path: TCPath) throws -> [FileItem] {
        if Thread.isMainThread { mainThreadLoads += 1 }
        return []
    }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at path: TCPath) throws {}
    func removeItem(at path: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

/// 空源：只为造一个「非 fileURL 路径」的 pane 供注销路断言（不触真盘）。
private final class EmptySource: FileSource {
    let sourceID: String
    var isRemote: Bool
    var supportsTransfer: Bool { false }
    init(id: String, remote: Bool) { sourceID = id; isRemote = remote }
    func listDirectory(_ path: TCPath) throws -> [FileItem] { [] }
    func isDirectory(_ path: TCPath) -> Bool { false }
    func stat(_ path: TCPath) throws -> FileItem? { nil }
    func copyItem(from: TCPath, to: TCPath) throws {}
    func moveItem(from: TCPath, to: TCPath) throws {}
    func renameItem(at: TCPath, to: TCPath) throws {}
    func makeDirectory(at path: TCPath) throws {}
    func removeItem(at path: TCPath) throws {}
    func openReader(_ path: TCPath) throws -> ReadHandle { { _ in nil } }
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {}
}

// MARK: - 协调器回归（假工厂注入；真 FSEvents 语义由 AutoRefreshUITests 真窗层覆盖）
//
// 计数「重载次数」用 pane.onReload（load 尾恰好发一次，见 FilePane.swift:202），
// 而非桩源 listDirectory 计数——真 LocalFileSource + 真临时目录，事件路 fire → 去抖
// → load(preserveFocus:true) 全链真实，断言更贴生产。测试里手动驱动 noteReloaded
// （不经 VC 的 onReload 接线），故 fire 后的 load 不会再入注册，去抖计数干净。

final class DirectoryWatcherCoordinatorTests: XCTestCase {
    private var dir: URL!
    private var pane: FilePane!
    private var factory: FakeFactory!
    private var watcher: DirectoryWatchCoordinator!

    override func setUpWithError() throws {
        L10n.current = .en
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dwtest_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try write("a.txt"); try write("b.txt")
        pane = FilePane(id: .left, source: LocalFileSource(), startPath: TCPath(url: dir))
        pane.load()
        factory = FakeFactory()
        watcher = DirectoryWatchCoordinator(factory: factory)
    }

    override func tearDownWithError() throws {
        watcher.stopAll()
        try? FileManager.default.removeItem(at: dir)
        try super.tearDownWithError()
    }

    private func write(_ name: String) throws {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 挂 onReload 计数器：load() 每次（成功/失败）在尾部恰好发一次回调。
    /// 返回读取闭包；两闭包共享捕获框（Swift 对逃逸闭包捕获 var 自动装箱）。
    private func countingReloads(_ pane: FilePane) -> () -> Int {
        var n = 0
        pane.onReload = { _ in n += 1 }
        return { n }
    }

    /// 泵主队列跑完 asyncAfter(0.3) 去抖项 + 余量（load 是同步路，无二次 hop）。
    private func pumpMainQueue(settle: TimeInterval = 0.6) {
        let exp = expectation(description: "pump")
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { exp.fulfill() }
        wait(for: [exp], timeout: settle + 5)
    }

    // MARK: 注册/生命周期

    /// noteReloaded 对 fileURL 路径 → 恰一流注册（工厂造 1 + start 1 + 注册路径=解链后目录）。
    /// 变异：删 noteReloaded 的挂流三行 → made.count 0 红。
    func testNoteReloadedRegistersOneStream() {
        watcher.noteReloaded(pane)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.made[0].startCount, 1)
        // 注册路径 = comparable(dir)（临时目录 /var→/private/var 解链后同域）。
        XCTAssertEqual(factory.made[0].path.standardizedFileURL.path,
                       (dir.path as NSString).resolvingSymlinksInPath)
    }

    /// 非 fileURL（SFTP/SMB scheme 路径）→ 零挂流（用户裁决：远端纯手动 ⌃R）。
    /// 变异：判据 `isFileURL` 换成 `!source.isRemote` 时，SMB stub（isRemote=false 但
    /// path=smb://…）会入流——path 判据本身锁死第二层，此用例锁第一层 sftp scheme。
    func testRemoteSchemePathGetsNoStream() {
        let remote = FilePane(id: .left, source: EmptySource(id: "sftp://h:22", remote: true),
                              startPath: TCPath("sftp://h:22/srv"))
        remote.load()
        watcher.noteReloaded(remote)
        XCTAssertTrue(factory.made.isEmpty, "远端 scheme 路径不得挂流")
    }

    /// 换路径：旧流恰一次 stop、新流恰一次 start（合计 2 造/1 停/2 起）。
    /// 变异：把「路径变化 → removeEntry」短路删掉（直接覆盖 entries[key]）→ 旧流 stopCount 0 红。
    func testPathChangeStopsOldStartsNew() throws {
        watcher.noteReloaded(pane)
        let dir2 = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        pane.navigate(to: TCPath(url: dir2))   // 本地同步 navigate 改 path（load 不发 noteReloaded，未接 VC）
        watcher.noteReloaded(pane)
        XCTAssertEqual(factory.made.count, 2, "换路径应再造一流")
        XCTAssertEqual(factory.made[0].stopCount, 1, "旧流必须停")
        XCTAssertEqual(factory.made[1].startCount, 1)
    }

    /// 同路径重复 noteReloaded（load 高频路：每次操作后刷新都过这里）→ 不重挂不重停。
    /// 变异：删 `watchedPath == cmp → return` 短路 → made.count 3 红。
    func testSamePathIsNoop() {
        watcher.noteReloaded(pane)
        watcher.noteReloaded(pane)
        watcher.noteReloaded(pane)
        XCTAssertEqual(factory.made.count, 1)
        XCTAssertEqual(factory.made[0].stopCount, 0)
    }

    /// 关标签 → stopWatching：该 pane 流停、注册除名；随后事件批被除名守卫吞掉。
    /// 变异：删 stopWatching 的 removeEntry → stopCount 0 红。（注销后事件路的双保险
    /// 在 scheduleReload 的 entries 复查——单删 handleEvents 首道守卫被它兜住，不独立红，
    /// 两条守卫是有意的纵深防御，评审锚注释订正 2026-09-10。）
    func testStopWatchingRemovesAndIgnoresLateBatches() throws {
        watcher.noteReloaded(pane)
        watcher.stopWatching(pane)
        XCTAssertEqual(factory.made[0].stopCount, 1)
        let reloads = countingReloads(pane)
        try write("late.txt")
        factory.made[0].fire(paths: [dir.appendingPathComponent("late.txt").path])
        pumpMainQueue()
        XCTAssertEqual(reloads(), 0, "注销后的事件批不得再触发重载")
    }

    /// setSource 换到远端：pane.path 变非 fileURL → noteReloaded 注销旧流。
    /// 变异：删 noteReloaded 的 !isFileURL→removeEntry 分支 → 旧流滞留（stopCount 0 红）。
    func testSwitchingPaneToRemoteUnregisters() {
        watcher.noteReloaded(pane)
        pane.setSource(EmptySource(id: "sftp://h:22", remote: true), andPath: TCPath("sftp://h:22/srv"))
        watcher.noteReloaded(pane)   // path 已同步为 sftp（setSource 内 path= 先于 loadAsync）
        XCTAssertEqual(factory.made.count, 1, "远端化不再造新流")
        XCTAssertEqual(factory.made[0].stopCount, 1, "本地旧流必须停")
    }

    // MARK: 事件 → 去抖重载

    /// 相关事件（本目录子项）→ 去抖窗后恰好一次保焦点重载：新文件进列表、焦点项不变。
    /// 变异：scheduleReload 的 load 改 preserveFocus:false → 焦点断言红。
    func testRelevantEventTriggersDebouncedFocusPreservingReload() throws {
        watcher.noteReloaded(pane)
        pane.revealItem(id: pane.selection.items[1])     // 焦点到 b.txt
        let focusBefore = pane.selection.focusID
        XCTAssertNotNil(focusBefore)
        let reloads = countingReloads(pane)
        try write("new.txt")                             // 模拟外部进程写盘

        factory.made[0].fire(paths: [dir.appendingPathComponent("new.txt").path])
        pumpMainQueue()

        XCTAssertEqual(reloads(), 1, "恰一次去抖重载")
        XCTAssertTrue(pane.page?.items.contains { $0.name == "new.txt" } ?? false,
                      "事件去抖后须重载出新文件")
        XCTAssertEqual(pane.selection.focusID, focusBefore, "自动刷新合同：焦点原样保留")
    }

    /// 去抖合并：一个去抖窗内连 fire 5 批 → 恰一次重载。
    /// 变异：scheduleReload 删 `entry.pending == nil` 守卫（每批各排一次 asyncAfter）
    /// → reloads() 5 红。
    func testBurstCollapsesToOneReload() throws {
        watcher.noteReloaded(pane)
        let reloads = countingReloads(pane)
        try write("x1.txt"); try write("x2.txt")
        for _ in 0..<5 {
            factory.made[0].fire(paths: [dir.appendingPathComponent("x1.txt").path])
        }
        pumpMainQueue()
        XCTAssertEqual(reloads(), 1, "5 批事件须合并成恰一次重载")
    }

    /// 无关事件（深层孙目录子项）→ 零重载（FileEvents 下深层变更不影响浅层列表）。
    /// 变异：relevant 的父目录比较写成恒真 → reloads() 1 红。
    func testDeepChildEventsAreIgnored() throws {
        watcher.noteReloaded(pane)
        let reloads = countingReloads(pane)
        let deep = dir.appendingPathComponent("sub").appendingPathComponent("deep.txt")
        factory.made[0].fire(paths: [deep.path])
        pumpMainQueue()
        XCTAssertEqual(reloads(), 0, "深层变更不该刷浅层列表")
    }

    /// 兜底 flag（RootChanged 等）：即使路径无关也无条件刷。
    /// 变异：alwaysReloadFlags 漏 RootChanged → reloads() 0 红。
    func testOverflowFlagsReloadRegardlessOfPath() throws {
        watcher.noteReloaded(pane)
        let reloads = countingReloads(pane)
        let deep = dir.appendingPathComponent("sub").appendingPathComponent("deep.txt")
        factory.made[0].fire(paths: [deep.path],
                             flags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged))
        pumpMainQueue()
        XCTAssertEqual(reloads(), 1, "RootChanged 须无条件刷")
    }

    /// 监听目录自身被删：事件路径==被监听目录 → 相关 → 刷一次吃 load 错误路（空列表）。
    /// 变异：relevant 删 `item == watched` 比较 → 不刷，reload 计数 0 红。
    func testWatchedDirDeletedReloadsToEmpty() throws {
        watcher.noteReloaded(pane)   // pane 是 LocalFileSource 真目录
        let reloads = countingReloads(pane)
        try write("victim.txt")
        try FileManager.default.removeItem(at: dir)   // 外部删掉被监听目录本体
        factory.made[0].fire(paths: [dir.path],
                             flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRemoved
                                                            | kFSEventStreamEventFlagItemIsDir))
        pumpMainQueue()
        XCTAssertEqual(reloads(), 1, "目录被删 → 刷一次")
        XCTAssertEqual(pane.visibleCount, 0, "错误路：列表清空")
    }

    /// didBecomeActive 兜底：refreshAllWatched 刷已注册流；挂起的去抖项被取消不双刷；
    /// 未注册的 pane 零接触。
    /// 变异：refreshAllWatched 删 load 行 → 兜底 reloads() 0 红；删 pending.cancel → 兜底
    /// 后再落一次去抖项 reloads() 2 红。
    func testRefreshAllWatchedReloadsRegisteredOnly() throws {
        watcher.noteReloaded(pane)
        let reloads = countingReloads(pane)
        // 未注册的第二窗格：兜底不得触碰它。
        let dir2 = dir.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)
        let unregistered = FilePane(id: .right, source: LocalFileSource(), startPath: TCPath(url: dir2))
        unregistered.load()
        let unregisteredReloads = countingReloads(unregistered)

        try write("whileaway.txt")   // 离线期间外部新增（overflow 丢事件的模拟）
        // 先造一个挂起未落的去抖项，验证兜底会取消它（不双刷）。
        factory.made[0].fire(paths: [dir.appendingPathComponent("z.txt").path])
        watcher.refreshAllWatched()
        pumpMainQueue()

        XCTAssertEqual(reloads(), 1, "兜底恰一次（挂起项被取消）")
        XCTAssertTrue(pane.page?.items.contains { $0.name == "whileaway.txt" } ?? false,
                      "兜底刷须让离线期间的新文件现身")
        XCTAssertEqual(unregisteredReloads(), 0, "未注册窗格零接触")
    }

    // MARK: - 评审回归锁（C1 寿命 / C2 使用点复查 / C3 末段符号链接）

    /// C1（use-after-free）：info 必须走 passUnretained + retain/release 回调——CF 创建时
    /// 经 retain 回调自取 +1，流彻底析构时经 release 回调**异步**归还（实测：stop() 返回
    /// 时归还尚未发生，须在 ≤3s 窗内轮询落定）。锁面 = 回调被真调用且 1:1 配对。
    /// 泄漏侧说明：passRetained 误用的额外 +1 不经过回调（Unmanaged 本地自持），回调
    /// 计数**结构上抓不到**该误用——此路由 spike 探针实证定档（create 时 retain 回调
    /// count 2→3；误配 = +2 泄漏），本用例锁「回调存在且配对」这一可观测半面。
    /// 变异：retain/release 改回 nil → 创建时 retainCallbackCount 0 红。
    func testSourceRetainsViaContextCallbacks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dwret_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FSEventsDirectorySource(path: dir) { _ in }
        source.start()
        XCTAssertEqual(source.retainCallbackCount, 1, "CF 创建时必须经 retain 回调持 +1")
        source.stop()
        let deadline = Date().addingTimeInterval(3)
        while source.releaseCallbackCount == 0 && Date() < deadline { usleep(20_000) }
        XCTAssertEqual(source.releaseCallbackCount, 1,
                       "stop 后流析构必须经 release 回调归还（CF 异步，≤3s 轮询窗）")
        XCTAssertEqual(source.releaseCallbackCount, source.retainCallbackCount,
                       "回调 1:1 配对（净 +0）")
    }

    /// C2：注销滞后窗口（setSource 远端化 → loadAsync 回包前）的竞态锁。生产时序：
    /// path/source **同步**变远端、onReload（=noteReloaded 注销路）要等 loadAsync 回包——
    /// 本测试的 onReload 是纯计数闭包（**不**转 noteReloaded），注销永不到来 = 窗口常开，
    /// 恰好复现「条目在册、pane 现状已远端化」的危险态。
    /// 违约的可观测面 = SniffSource.mainThreadLoads：协调器若违约对远端化窗格做同步
    /// load，listDirectory 就落在主线程（合法路 loadAsync 在专用队列）。
    /// 变异：删 work 体/refreshAllWatched 的 isFileURL 复查 → mainThreadLoads 1 +
    /// stopCount 0 双红；复挂在位 → 0 主线程 load、流恰一次就地注销。
    func testSwitchedToRemoteIsDroppedAtUseTime() throws {
        watcher.noteReloaded(pane)                 // 流已挂（本地夹具目录）

        // 事件先排出去抖项 → 随后远端化（复现「排期在窗口前、落定在窗口内」）。
        factory.made[0].fire(paths: [dir.appendingPathComponent("ghost.txt").path])
        let remote = SniffSource()
        pane.setSource(remote, andPath: TCPath("sftp://h:22/srv"))
        XCTAssertFalse(pane.path.url.isFileURL, "前置：path 已同步远端化")
        pumpMainQueue()                            // 去抖落定 → 应就地注销
        XCTAssertEqual(remote.mainThreadLoads, 0, "事件路不得对远端化窗格同步 load（主线程冻结源）")
        XCTAssertEqual(factory.made[0].stopCount, 1, "使用时刻发现远端化须就地注销")

        // 兜底路同款缺口（refreshAllWatched 独立使用点）：新 pane 挂流后远端化 → 兜底
        // 只注销不刷。
        let pane2 = FilePane(id: .right, source: LocalFileSource(), startPath: TCPath(url: dir))
        pane2.load()
        watcher.noteReloaded(pane2)
        XCTAssertEqual(factory.made.count, 2, "前置：pane2 挂流")
        let remote2 = SniffSource()
        pane2.setSource(remote2, andPath: TCPath("sftp://h:22/srv2"))
        watcher.refreshAllWatched()                // inline 主线程：此刻无同步 load 就永远没有
        XCTAssertEqual(remote2.mainThreadLoads, 0, "兜底不得同步 listDirectory 远端源")
        XCTAssertEqual(factory.made[1].stopCount, 1, "兜底发现远端化也须就地注销")
    }

    /// C3：被监听目录里**指向外部的符号链接**的事件（create/rename 出软链）须触发刷新。
    /// 旧逻辑 comparable() 整条解析会把 link→/etc/hosts 带出 watched 域 → 恒不刷（实测）。
    /// 变异：relevant 改回整条 comparable → reloads() 0 红。
    func testSymlinkChildEventsStillTriggerReload() throws {
        watcher.noteReloaded(pane)
        let reloads = countingReloads(pane)
        let link = dir.appendingPathComponent("outlink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")

        factory.made[0].fire(paths: [link.path])
        pumpMainQueue()
        XCTAssertEqual(reloads(), 1, "指向外部的软链 create 须触发刷新（末段不得解析）")
        try? FileManager.default.removeItem(at: link)
    }

    /// 裁决①「覆盖所有打开标签（含后台标签）」锁：全部 pane（含非活动侧与落后台的标签）
    /// 都经真 onReload 挂点持有自己的流。
    /// 变异：onReload 挂点加「仅活动窗格」条件 → 非活动侧/后台标签无流 → 计数红。
    func testAllPanesIncludingInactiveRegistered() throws {
        let (vc, fc) = try makeWiredVC()
        defer { vc.directoryWatcher.stopAll() }
        // loadView 后：左活动 + 右非活动各有流（右侧 pane.load() 同样过 onReload→noteReloaded）。
        XCTAssertEqual(fc.made.count, 2, "左右两侧（含非活动）各一流")
        let resolved = (dir.path as NSString).resolvingSymlinksInPath
        XCTAssertEqual(Set(fc.made.map { $0.path.path }), [resolved], "夹具同目录 → 流路径一致")

        // 左活动侧再开标签 C（真 menuNewTab 路，add 即激活）→ 原左标签落**后台**。
        vc.menuNewTab(nil)
        XCTAssertEqual(fc.made.count, 3, "新标签挂第三流")
        let backgrounded = vc.workspace.leftTabs.panes[0]   // 已落后台的原左标签
        let before = fc.made.count
        backgrounded.load()                                 // 后台刷新走真 onReload 链
        XCTAssertEqual(fc.made.count, before, "后台标签同路径 no-op：不重挂也不掉流")

        // 端到端覆盖实证：给后台标签自己的流灌事件 → 后台窗格被自动刷新
        // （「仅活动标签挂流」的变异下：后台无流 → 事件无处来 → page 永不含新文件红）。
        try "x".write(to: dir.appendingPathComponent("bgnew.txt"), atomically: true, encoding: .utf8)
        fc.made[0].fire(paths: [dir.appendingPathComponent("bgnew.txt").path])
        pumpMainQueue()
        XCTAssertTrue(backgrounded.page?.items.contains { $0.name == "bgnew.txt" } ?? false,
                      "后台标签须被其自有流自动刷新（裁决①覆盖所有打开标签）")
    }

    /// URL== 回归锁（spec 坑1）：被监听目录被删后，noteReloaded 必须以 **.path 串**判
    /// 同路径 no-op——URL == 携带活文件系统语义（删前/删后构造同路径 URL 竟不相等），
    /// 用 == 会让「目录被删→load 错误路→onReload 再入」重挂流永不停。
    /// 变异：noteReloaded 的比较改回 `entry.watchedPath == cmp` → 换路径计数 2 红。
    /// （行为面 testWatchedDirDeletedReloadsToEmpty 用手动 fire 绕过了再入路，
    /// 本用例显式走「删目录→noteReloaded」这条生产形态。）
    func testNoteReloadedAfterDirDeletedIsNoop() throws {
        watcher.noteReloaded(pane)
        try FileManager.default.removeItem(at: dir)      // 目录被外部删（pane.path 不变）
        pane.load()                                       // 错误路：空列表（无 VC 接线，不发 noteReloaded）
        watcher.noteReloaded(pane)                        // 生产里此刻正被 onReload 驱动
        XCTAssertEqual(factory.made.count, 1, "删后同路径必须 no-op（URL== 在此为 false→会重挂）")
        XCTAssertEqual(factory.made[0].stopCount, 0, "no-op 不得停旧流")
    }

    // MARK: - 接线锁（VC 生命周期单挂点 + closeTab，走真 loadView 链）

    /// `_ = vc.view` 搭好后：两侧初生窗格的 load→onReload→noteReloaded 链已把流注册上。
    /// 变异：删 wirePaneCallbacks 里 `directoryWatcher.noteReloaded(p)` → made 不含夹具路径红。
    func testVCOnReloadChainRegistersStreams() throws {
        let (vc, fc) = try makeWiredVC()
        defer { vc.directoryWatcher.stopAll() }
        XCTAssertGreaterThanOrEqual(fc.made.count, 1, "loadView 初始 load 链须挂流")
        let paths = fc.made.map { $0.path.path }
        XCTAssertTrue(paths.contains((dir.path as NSString).resolvingSymlinksInPath),
                      "流路径须是夹具目录（解链后），got: \(paths)")
    }

    /// 关标签 → 被关 pane 的流恰一次 stop。
    /// 变异：删 closeTab 的 stopWatching 行 → 被关标签流 stopCount 0 红。
    func testCloseTabStopsStreamOfRemovedPane() throws {
        let (vc, fc) = try makeWiredVC()
        defer { vc.directoryWatcher.stopAll() }
        let before = fc.made.count
        vc.menuNewTab(nil)                 // 活动侧新标签 → wire + load → noteReloaded 挂流
        XCTAssertGreaterThan(fc.made.count, before, "前置：新标签挂上了流")
        let last = fc.made.last!
        vc.menuCloseTab(nil)               // 关掉活动标签（=新标签，add 即激活）
        XCTAssertEqual(last.stopCount, 1, "关标签须注销其流")
    }

    /// 用假工厂搭一个已过 loadView 的 VC（左右都落夹具目录）。
    private func makeWiredVC() throws -> (MainViewController, FakeFactory) {
        let suiteName = "fly.wirewatch.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = SessionStore(defaults: suite)
        store.saveIfChanged(SessionSnapshot(version: 1, leftPath: dir.path,
                                            rightPath: dir.path, active: "left"))
        let fc = FakeFactory()
        let vc = MainViewController(sessionStore: store,
                                    favoritesStore: DirectoryFavoritesStore(defaults: suite),
                                    watcherFactory: fc)
        _ = vc.view
        return (vc, fc)
    }
}
