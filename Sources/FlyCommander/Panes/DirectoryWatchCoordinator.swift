import Foundation
import CoreServices
import TCCore

// MARK: - 事件源接缝（协议化：真机 = FSEvents，测试 = 假工厂）

/// 一个目录的事件源（已挂起或已停止）。生命周期由 DirectoryWatchCoordinator 全权调度。
protocol DirectoryEventSource: AnyObject {
    func start()
    func stop()
}

/// 一个原始事件：被变更项的路径 + FSEvents 事件 flags。
struct DirectoryEvent {
    let path: String
    let flags: FSEventStreamEventFlags
}

/// 事件源工厂。onEvent 缺省契约 = **在主线程回调**（实现方负责 hop）。
protocol DirectoryEventSourceFactory {
    func makeSource(path: URL, onEvent: @escaping ([DirectoryEvent]) -> Void) -> DirectoryEventSource
}

// MARK: - FSEvents 真实现
//
// Spike S1/S1b 定档（2026-09-10 实测，本缩减 SDK）：
// * FSEvents 运行时全链可用：挂流→外部写/删→≤1.5s 收回调→Stop/Invalidate/Release 后零回调。
// * 本 SDK 签名两处偏差：sinceEvent 形参暴露为 FSEventStreamEventId（非 CFAbsoluteTime）；
//   FSEventStreamCreate 返回 FSEventStreamRef?（可选）。
// * kFSEventStreamEventIdSinceNow 挂流**零历史回放** → 协调器不需要「丢弃首组」逻辑。
// * 原子写（write(atomically:true)）额外冒出 .sb-* 临时文件事件（与被写文件同父目录），
//   去抖窗内合并后仍是对被监听目录刷一次，无害。
// * 实测 flag：外部 create=0x11800，delete=0x11a00（差 ItemRemoved）；监听目录自身被删
//   收到含该目录路径的事件 → 协调器刷一次，load() 吃错误路（空列表+lastError，可接受）。
// * 队列纪律（CLAUDE.md）：只用 DispatchQueue.global(qos:)，绝不动态建队列。
// * C 函数指针回调不许捕获上下文：pane 身份经 FSEventStreamContext.info 传
//   Unmanaged.passUnretained(source)；回调线程只装箱 + main.async 投递，零触碰模型。

/// 回调装箱：C 函数指针拿不到 Swift 捕获，事件先落在源对象自己的锁保护缓冲里再整批投主线程。
final class FSEventsDirectorySource: DirectoryEventSource {
    private let path: URL
    private let onEvent: ([DirectoryEvent]) -> Void
    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var boxed: [DirectoryEvent] = []
    /// CF 配对计数（@testable 锁面）：retain 回调 = CF 创建时自取 +1；release 回调 =
    /// 流彻底析构时归还。正常 stop 路净 +0。回调节流（retain:nil/release:nil）时双 0。
    private(set) var retainCallbackCount = 0
    private(set) var releaseCallbackCount = 0

    init(path: URL, onEvent: @escaping ([DirectoryEvent]) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    /// 保险丝（正常路 coordinator 总先 stop()：closeTab/换路径/stopAll）。
    /// 定档 C1 后几乎不可达：CF 的 retain +1 让对象活到流析构（release 回调）为止，
    /// 而 release 回调必然先把 stream 置 nil → stop() 自兜。留着是防御性冗余。
    deinit { stop() }

    func start() {
        precondition(stream == nil, "start 只许调一次（stop 后不许复用重启）")
        // 评审 C1（use-after-free）：Stop/Release **不等已在执行/已入队的回调块**退出，
        // 无 retain 回调时对象可在回调体仍在执行时被 deinit（实测 DEINIT 先于回调完成打印）
        // → info 成野指针。定档修法 = CF 标准配对：info 传 **passUnretained**，配
        // retain/release 回调——CF **创建时经 retain 回调自取 +1**（探针实测 count 2→3），
        // 流彻底析构（在途回调排干后）时 release 回调归还。对象寿命由流本身托住，
        // info 解引用永不悬垂。**不可**叠加 passRetained（=+2，泄漏；同为探针实测）。
        // 本缩减 SDK 把 retain/release 导入为**单参** C 闭包（CFAllocatorRetainCallBack）。
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { info -> UnsafeRawPointer? in
                guard let info else { return nil }
                let s = Unmanaged<FSEventsDirectorySource>.fromOpaque(info).takeUnretainedValue()
                s.retainCallbackCount += 1   // C 闭包零捕获，计数落在对象自身
                _ = Unmanaged<FSEventsDirectorySource>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                let s = Unmanaged<FSEventsDirectorySource>.fromOpaque(info).takeUnretainedValue()
                s.releaseCallbackCount += 1
                Unmanaged<FSEventsDirectorySource>.fromOpaque(info).release()
            },
            copyDescription: nil)
        // FileEvents=细粒度子项路径+flag；UseCFTypes=事件路径以 CFArray(NSString) 交付。
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, fsEventCallback, &context,
                                                [path.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                0.5,   // latency：内核级合帧窗
                                                flags) else {
            // 罕见失败（资源耗尽）。不手动配平引用：CF 失败路径是否已调 retain 不可证，
            // 过度释放 = 提前 deinit（比罕见有界泄漏恶劣得多）。宁漏不崩。
            return
        }
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// 供 C 回调投递：装箱事件整批 hop 主线程后交付 onEvent（协调器的全部状态只在主线程动）。
    fileprivate func deliverBoxed() {
        lock.lock()
        let events = boxed
        boxed.removeAll()
        lock.unlock()
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [onEvent] in onEvent(events) }
    }

    fileprivate func append(_ e: DirectoryEvent) {
        lock.lock(); boxed.append(e); lock.unlock()
    }
}

/// C 函数指针回调（顶层函数，零捕获）。事件装箱后统一投主线程。
private func fsEventCallback(stream: ConstFSEventStreamRef, info: UnsafeMutableRawPointer?,
                             numEvents: Int, eventPaths: UnsafeMutableRawPointer,
                             eventFlags: UnsafePointer<FSEventStreamEventFlags>,
                             eventIds: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let source = Unmanaged<FSEventsDirectorySource>.fromOpaque(info).takeUnretainedValue()
    let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
    for i in 0..<numEvents {
        source.append(DirectoryEvent(path: paths[i], flags: eventFlags[i]))
    }
    source.deliverBoxed()
}

struct FSEventsDirectorySourceFactory: DirectoryEventSourceFactory {
    func makeSource(path: URL, onEvent: @escaping ([DirectoryEvent]) -> Void) -> DirectoryEventSource {
        FSEventsDirectorySource(path: path, onEvent: onEvent)
    }
}

// MARK: - 协调器（每窗格一流：注册/换路径/注销 + 去抖 + 过滤 + 保焦点重载）

/// 目录外部变更自动刷新的中枢。生命周期单挂点 = MainViewController 的 pane.onReload：
/// navigate/setSource/断连回退/操作后刷新的终点必是 load→onReload，noteReloaded 在此
/// 三合一（注册/换路径/注销），不需要散点埋钩。
///
/// 覆盖范围 = 用户裁决（2026-09）：**所有打开标签**（含后台标签）各挂一流；
/// 判据 `pane.path.url.isFileURL`——SFTP/SMB 的 path 是 sftp://…/smb://… scheme
/// 非 fileURL → 天然排除（手动 ⌃R 兜底）。SMB 挂载点纳入留 follow-up：经
/// SMBSource.toLocal 映射本地路径挂流，回调必须走 loadAsync（同步 load 在卷睡眠时
/// 会把网络卡死转嫁主线程）。
final class DirectoryWatchCoordinator {
    /// 去抖窗：FSEvents 内核合帧（latency 0.5s）之上再并一层应用级尾沿窗。
    /// pending 期内后续事件被已排定的那次 reload 天然覆盖，直接吞掉不重排。
    /// 不需要「reload 中置 dirty 尾刷」：本协调器只盯 fileURL 目录（远端被判据排除），
    /// 本地 load 在 main 上同步执行，而事件同样投递到 main——同步执行段内事件不可能
    /// 插队，「reload 执行中到达」在主线程模型下结构上不存在。
    /// DispatchWorkItem+main.asyncAfter = PaneTableView.typeAhead 同范式。
    static let debounceWindow = 0.3

    /// /var→/private/var 这类符号链接前缀：FSEvents 回调交付**解析后真实路径**，
    /// 注册与比较必须同域（临时目录测试夹具即踩此坑）。解析失败的罕见路退回原值。
    private static func comparable(_ url: URL) -> URL {
        URL(fileURLWithPath: (url.path as NSString).resolvingSymlinksInPath).standardizedFileURL
    }

    /// 无条件刷新的兜底 flag：丢事件/需重扫根变更类——路径过滤对其不适用。
    private static let alwaysReloadFlags: FSEventStreamEventFlags =
        FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                | kFSEventStreamEventFlagUserDropped
                                | kFSEventStreamEventFlagKernelDropped
                                | kFSEventStreamEventFlagEventIdsWrapped
                                | kFSEventStreamEventFlagRootChanged)

    /// class（非 struct）：去抖状态（pending）要能在字典取出的引用上原地改——
    /// struct 从字典取到的是副本，改了等于没改。
    private final class Entry {
        let pane: FilePane
        let watchedPath: URL          // comparable() 后的真实路径
        let source: DirectoryEventSource
        var pending: DispatchWorkItem?
        init(pane: FilePane, watchedPath: URL, source: DirectoryEventSource) {
            self.pane = pane; self.watchedPath = watchedPath; self.source = source
        }
    }

    private let factory: DirectoryEventSourceFactory
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// 自激环裁定（计划 C 节）：app 自身操作后 FSEvents 迟到再触发**恰好一次**多余
    /// load(preserveFocus:true)——幂等、焦点标记保留、本地 2 万项实测 37ms。接受不抑制；
    /// 若将来要抑制，挂点在此：记录 lastSelfLoadTime 做 500ms 短路。

    init(factory: DirectoryEventSourceFactory = FSEventsDirectorySourceFactory()) {
        self.factory = factory
    }

    /// 注册/换路径/注销三合一。pane.onReload 尾挂（每次 load 完都过一遍）：
    /// 路径未变 → no-op；变了 → 停旧挂新；非 fileURL → 停旧注销。
    func noteReloaded(_ pane: FilePane) {
        let key = ObjectIdentifier(pane)
        guard pane.path.url.isFileURL else {
            removeEntry(key)   // 远端化/断连回退前的残留流必须停
            return
        }
        // /var→/private/var 这类符号链接前缀：FSEvents 回调交付的是**解析后真实路径**，
        // 注册与比较必须同域（临时目录测试夹具即踩此坑）。
        let cmp = Self.comparable(pane.path.url)
        if let entry = entries[key] {
            // 比较用 .path 串而非 URL ==：URL 等值携带活文件系统资源属性——已存在的
            // 目录 URL 带目录语义（absoluteString 尾斜杠），删后再构造退化为文件语义，
            // == 永假。「目录被外部删」+ 同路径 no-op 两条路都靠 .path 串才稳。
            if entry.watchedPath.path == cmp.path { return }   // 同路径不重挂（load 高频路）
            removeEntry(key)
        }
        let source = factory.makeSource(path: cmp) { [weak self] events in
            self?.handleEvents(paneID: key, events: events)
        }
        source.start()
        entries[key] = Entry(pane: pane, watchedPath: cmp, source: source)
    }

    /// 关标签/窗格销毁：注销该 pane 的流（挂起的去抖项一并取消）。
    func stopWatching(_ pane: FilePane) {
        removeEntry(ObjectIdentifier(pane))
    }

    func stopAll() {
        for key in Array(entries.keys) { removeEntry(key) }
    }

    private func removeEntry(_ key: ObjectIdentifier) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.pending?.cancel()
        entry.source.stop()
    }

    /// didBecomeActive 兜底：只刷**已注册流**的窗格（不扩 SFTP/SMB 面，守用户裁决）。
    /// 兜 FSEvents 队列 overflow 丢事件与「目录被删后重建」的失联窗口。
    /// 使用时刻复查（评审 C2）：注销挂在 load→onReload 尾，setSource 换远端后要等
    /// loadAsync 网络回包才走到——那个 RTT 窗口里条目仍在 entries 但 pane 已远端化。
    /// 同步 load 会把网络往返冻进主线程，故此处非 fileURL → 就地注销而不是刷。
    func refreshAllWatched() {
        for key in Array(entries.keys) {
            guard let entry = entries[key] else { continue }
            guard entry.pane.path.url.isFileURL else { removeEntry(key); continue }
            entry.pending?.cancel()
            entry.pending = nil
            entry.pane.load(preserveFocus: true)
        }
    }

    // MARK: - 事件处理（主线程）

    private func handleEvents(paneID: ObjectIdentifier, events: [DirectoryEvent]) {
        guard let entry = entries[paneID] else { return }   // 已注销（stop 竞尾的迟到批）
        if relevant(events: events, watched: entry.watchedPath) {
            scheduleReload(paneID: paneID)
        }
    }

    /// 路径过滤：FileEvents 下深层子目录变更不影响浅层列表——仅当事件项就住在本目录
    /// （或被监听目录自身，删目录/改名路）才刷。alwaysReloadFlags 无条件刷。
    /// 比较用 comparable() 后的 **.path 串**（URL == 携带活文件系统目录/文件语义，
    /// 目录被删前后构造的同一 URL 竟不相等——见 noteReloaded 内注释）。
    ///
    /// 末段不解析（评审 C3）：`resolvingSymlinksInPath` 会解析路径上**每一个**符号链接，
    /// 包括末段——目录里一个指向外部的软链 `link -> /etc/hosts` 会让 comparable() 把事件
    /// 路径改写成 /etc/hosts，父目录永不相等 → 该文件的 create/rename 永不触发刷新。
    /// 故只解**父目录**链（拿到与注册同域的目录真身），末段名原样接回。
    private func relevant(events: [DirectoryEvent], watched: URL) -> Bool {
        let watchedPath = watched.path
        for e in events {
            if e.flags & Self.alwaysReloadFlags != 0 { return true }
            let itemURL = URL(fileURLWithPath: e.path)
            let parent = Self.comparable(itemURL.deletingLastPathComponent())
            let resolved = parent.appendingPathComponent(itemURL.lastPathComponent).path
            if resolved == watchedPath { return true }
            if parent.path == watchedPath { return true }
        }
        return false
    }

    /// 保焦点重载（自动刷新的核心合同）：焦点在→精确回归、被删→clamp 同索引；
    /// 筛选/隐藏态经 recomputeVisibility 保留；load 尾部的 onReload 会再入 noteReloaded
    /// （同路径 no-op，不成环）。恒本地同步 load——判据 isFileURL 已排除远端（远端目录
    /// 不入 entries），故无需 loadAsync 分支，也不存在「reload 执行中事件插队」。
    private func scheduleReload(paneID: ObjectIdentifier) {
        guard let entry = entries[paneID], entry.pending == nil else { return }   // 去抖：pending 期吞后续批
        let work = DispatchWorkItem { [weak self] in
            guard let self, let entry = self.entries[paneID] else { return }
            entry.pending = nil
            // 使用时刻复查（评审 C2）：排期与落定之间 pane 可能已被 setSource 远端化
            // （注销滞后一个网络 RTT）——对远端源同步 load = 主线程冻结，就地注销。
            guard entry.pane.path.url.isFileURL else { self.removeEntry(paneID); return }
            entry.pane.load(preserveFocus: true)
        }
        entry.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceWindow, execute: work)
    }
}
