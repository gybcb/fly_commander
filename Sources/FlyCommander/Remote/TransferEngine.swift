import Foundation
import TCCore

/// 传输速度估算（滑动窗口，纯函数，零 AppKit——可在 SPM 单测直调）。
/// 样本 = (时刻, **全程累计已传输字节**)。取时间跨度 ≥ minWindow 的最新尾窗口求平均字节/秒。
/// 宁缺毋假：样本 <2 或尾窗口跨度 <minWindow → nil（样本太少给个乱跳的速度不如不显示，
/// 尤其大文件开头几 KB 的瞬时值会骗人）。调用方（UI 面板）负责裁剪样本尾部。
enum TransferSpeed {
    static func estimate(samples: [(t: TimeInterval, bytes: Int64)],
                         minWindow: TimeInterval = 0.5) -> Double? {
        guard samples.count >= 2, let last = samples.last else { return nil }
        // 从尾往前找到跨度刚够 minWindow 的最早样本（保持窗口尽量小→反应快，又不太抖）。
        var first = samples.first!
        for s in samples.reversed() {
            if last.t - s.t >= minWindow { first = s; break }
        }
        let dt = last.t - first.t
        guard dt >= minWindow else { return nil }          // 整体跨度不足→宁缺毋假
        let db = Double(last.bytes - first.bytes)
        guard db >= 0, dt > 0 else { return nil }
        return db / dt
    }
}

/// 直传接缝 per-run 令牌（belt-and-braces）：run() 主线程段 next() 取号，接缝闭包
/// （makeDirectSeam 工厂造）捕获当值；闭包首行比对 current()，不等 → `.unavailable("stale-seam")`。
/// **它不是安全机制**（终审波 2 裁定）：引擎逐条目读的是 directCrossTransfer **当前值**
/// （OperationEngine.askDirect），被安装的闭包永远是最新装配者 → 自比恒真；重叠时
/// 引擎调 run2 闭包跑 run1 条目这条路它挡不住。真正的安全 = run() 的 running-flag
/// 串行门（在飞 = 第二 run 整个拒收，并发 run 不存在）。令牌只挡「更晚 run 已取号
/// 但还没装接缝」的无害窗口（纯失加速）+ 未来 gate 回归的兜底。
/// 写=主线程，读=后台线程 → NSLock 护栏（同 SFTPConnection.lastCopyRoute 类盒纪律）。
final class DirectSeamTokenBox {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); value += 1; let v = value; lock.unlock(); return v }
    func current() -> Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// 直传当前文件名盒（B5）：接缝闭包写（rsync --progress 文件名行经 onFile 抵达）、
/// byteProgress 闭包读后经 directName 转进帧的 name 字段。与 ThrottleState 同纪律：
/// 两个闭包都在同一后台传输块内顺序访问，无并发。
final class DirectNameBox {
    var name: String?
}

/// 跨源（含远端）传输执行器（app 层，T6）。
///
/// 主线程调用 run() 后，真正的传输（engine.performCopy/performMove）在后台执行，
/// 主线程不阻塞、UI 不冻结；进度/完成/失败经 state 回调回主线程；传输结束经 onFinished 回主线程刷新窗格。
///
/// 线程边界全部可注入（单测可换同步实现，避免主线程阻塞死锁）：
/// - runInBackground：默认 `DispatchQueue.global(qos: .userInitiated).async`（系统预建队列，
///   **不新建** DispatchQueue——本 SDK 下动态建队会在 async 运行时启动后端错误）。
/// - onMain：默认跳回主线程（已在主线程则直接执行）。
/// - prompt：原样透传给引擎（其线程职责由注入者自己承担；app 侧包装成主线程 NSAlert）。
final class TransferEngine {
    /// 回主线程的进度/状态回调。
    var state: ((OperationState) -> Void)?
    /// 冲突询问，原样传给 OperationEngine。
    var prompt: ConflictPrompt?
    /// 传输结束（无论成败）回主线程的收尾（刷新窗格等），带源/目标窗格。
    var onFinished: ((_ srcPane: FilePane, _ dstPane: FilePane) -> Void)?

    /// 后台执行器（单测可换同步实现）。
    var runInBackground: (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) }
    /// 回主线程执行器（单测可换同步实现）。
    var onMain: (@escaping () -> Void) -> Void = {
        if Thread.isMainThread { $0() } else { DispatchQueue.main.async(execute: $0) }
    }
    /// 进度节流时钟（单测注入假时钟；nil = CFAbsoluteTimeGetCurrent）。
    var progressClock: (() -> TimeInterval)?
    /// 传输连接工厂（单测注入替身）：入参 = 窗格浏览源；返回值 = 替身源 + **收尾清理闭包**
    /// （run 结束无论成败调用；无清理需求返回 {}）。返回 nil = 不替换（回落共享源）。
    /// 生产实现：SFTP 经 ConnectionStore 开独立第二连接；FTP 直接拿浏览源的 config
    /// （含内存中密码）另建一条懒连 FTPSource——FTP 单控制连接不能多路复用，
    /// 传输整程独占浏览连接会让传输期间该窗格的浏览/刷新全部排队（FTPConnection 的
    /// 传输租约）；非 SFTP/FTP 恒 nil。
    var transferSourceProvider: (_ browse: FileSource) -> (FileSource, () -> Void)? = { browse in
        if let sftp = browse as? SFTPSource,
           let ts = ConnectionStore.shared.transferSource(for: sftp.sourceID) {
            return (ts, { ts.closeConnection() })
        }
        if let ftp = browse as? FTPSource {
            // 懒连（首次操作才握手）；同源判定是 sourceID 字符串相等，config 逐字复制 → 串一致。
            let ts = FTPSource(config: ftp.config)
            return (ts, { ts.closeConnection() })
        }
        return nil
    }

    let engine: OperationEngine
    /// **串行门（终审波 2 裁定 = B4 的真安全机制）**：在飞传输存在时，run() 直接拒收。
    /// 事故根因 = 两个 run 同时在飞：engine.directCrossTransfer 是**共享实例上的单个 var**，
    /// run2 装配后引擎（OperationEngine.askDirect 逐条目读当前值）就会拿 run2 的
    /// ssrc/peer 去推 run1 的条目 → 错服务器静默写入 + move 删错源。接缝令牌挡不住
    /// （被装者自比恒真，见 DirectSeamTokenBox 注）→ 唯一根治 = 并发 run 不存在。
    /// 顺带治掉既有怪态：重叠 run 互相覆盖面板与 transferPanelActive（主 VC 无闸门）。
    /// **用户可见行为变化（有意，非回归）**：传输进行中再按 F5/F6 不再起第二个传输。
    /// 写=主线程（run 头部）/ 后台块尾，读=主线程 → NSLock（本类既有盒纪律）。
    private let runningLock = NSLock()
    private var runningFlag = false
    /// 直传接缝 per-run 令牌（B4，语义见 DirectSeamTokenBox 注）。internal：锁直读计数。
    let seamToken = DirectSeamTokenBox()

    /// 串行门状态（主 VC 上屏前判 + 单测断言取/放成对不卡死）。
    var isTransferRunning: Bool {
        runningLock.lock(); defer { runningLock.unlock() }; return runningFlag
    }
    private func claimRunning() -> Bool {
        runningLock.lock(); defer { runningLock.unlock() }
        if runningFlag { return false }
        runningFlag = true
        return true
    }
    private func releaseRunning() {
        runningLock.lock(); runningFlag = false; runningLock.unlock()
    }

    init(engine: OperationEngine = OperationEngine()) {
        self.engine = engine
    }

    /// 把任意 ConflictPrompt 提升到主线程执行（后台线程 sync 回主线程）。
    /// 引擎只在 runInBackground 块内调用 prompt（后台线程）；已在主线程则直行，
    /// 单测注入同步 runInBackground 时不会自锁。
    static func promptOnMain(_ raw: @escaping ConflictPrompt) -> ConflictPrompt {
        { s, d in
            if Thread.isMainThread { return raw(s, d) }
            return DispatchQueue.main.sync { raw(s, d) }
        }
    }

    // MARK: - T2 进度契约

    /// 逐文件传输进度信息（onProgress 回调参数）。
    /// name = 刚完成的文件名（字节级帧为空串——UI 保留上一帧的 name）；
    /// bytesDone/bytesTotal = 当前文件内已传输/总字节（仅跨源流式有值；
    ///   同源 copyItem / exec cp 是黑盒，文件级帧里为 nil）；
    /// route = 刚完成文件的实际传输路径（服务器端 cp / 本机中转+原因），非 SFTP 目标恒 nil。
    struct TransferProgressInfo {
        let name: String
        let fileDone: Int
        let fileTotal: Int
        let bytesDone: Int64?
        let bytesTotal: Int64?
        let route: CopyRoute?
    }

    /// 字节级上报节流间隔（秒）。文件级上报（每文件完成）不节流。
    static let progressThrottleInterval: TimeInterval = 0.05

    /// 节流状态盒（引用类型，跨闭包共享）。仅后台线程单块访问，无并发。
    /// internal：单测直接构造验证节流/重置语义。
    final class ThrottleState {
        var lastByteReportTime: TimeInterval = -ThrottleState.sentinel
        /// 已完成文件数（文件级回调写入；字节帧借用，UI 可同屏显示「第 N/M 个 + 字节%」）。
        var fileDone: Int = 0
        var now: () -> TimeInterval = { CFAbsoluteTimeGetCurrent() }
        /// 初值/文件完成重置用的哨兵（比任何真实时钟都小 → 下一报必达）。
        static let sentinel: TimeInterval = 1e18

        /// 字节帧上报判定：到间隔才报（并更新时间戳），否则吞掉。
        func shouldReportByte() -> Bool {
            let t = now()
            guard t - lastByteReportTime >= TransferEngine.progressThrottleInterval else { return false }
            lastByteReportTime = t
            return true
        }
    }

    /// 字节帧构造（文件级/路由字段由调用方语义决定：字节帧默认无名、无 route）。
    /// name 默认 ""（pump 路字节帧无名——面板沿用上一帧）；直传路 B5 传入
    /// `directName` 的产物（rsync --progress 文件名行，spec 决策 #2）。
    /// **total==0 → bytesTotal=nil**：直传路目录条目无预扫描、总量未知（接缝合同
    /// 「第二参 0=总量未知」），面板 `total > 0` 判定消费的是 nil——0 会穿进
    /// 「有总量」分支渲染 0/0。变异证伪见 TransferPanelDirectRouteTests。
    static func byteFrame(done: Int64, total: Int64, fileDone: Int, fileTotal: Int, name: String = "")
        -> TransferProgressInfo {
        TransferProgressInfo(name: name, fileDone: fileDone, fileTotal: fileTotal,
                             bytesDone: done, bytesTotal: total > 0 ? total : nil, route: nil)
    }

    /// 直传名字框 → 帧名（纯函数，spec 决策 #2「当前文件名取 --progress 文件名行」）。
    /// nil（本周期无新文件名行）→ ""（面板沿用上一帧）。变异证伪见
    /// DirectRsyncTests.testParserFileNameReachesFrameName。
    static func directName(from box: DirectNameBox) -> String { box.name ?? "" }

    /// 直传接缝的启用判定（纯函数，可单测）：两端皆 SFTP + 不同服务器 + 源端 keyFile
    /// 认证（密码认证先天无 A→B 信任，A 上 ssh 必然要口令）才可能；否则不挂接缝
    /// = 引擎零调用。锁在 TransferPanelDirectRouteTests.testSeamGateTable。
    static func directSeamSources(src: FileSource, dst: FileSource)
        -> (ssrc: SFTPSource, sdst: SFTPSource)? {
        guard let ssrc = src as? SFTPSource, let sdst = dst as? SFTPSource,
              ssrc.sourceID != sdst.sourceID, ssrc.supportsDirectCross
        else { return nil }
        return (ssrc, sdst)
    }

    /// 接缝单次调用的参数装配（纯函数，可单测）。
    /// dstPath 直接用 destDir —— 接缝合同里它**已是全目标路径**（Task 1
    /// testSeamReceivesJoinedDest），此处再拼一次名 = 「src 尾斜杠吞掉路径名」类坑。
    /// totalHint：目录无预扫描 = 0（不定量），文件 = size。
    static func directSeamArgs(ssrc: SFTPSource, sdst: SFTPSource, item: FileItem, destDir: TCPath)
        -> (item: DirectRsync.ItemTarget, peer: DirectRsync.Peer, totalHint: Int64) {
        (DirectRsync.ItemTarget(remotePath: item.path.pathString,
                                dstPath: destDir.pathString,
                                isDirectory: item.isDirectory),
         // peer = **目标**服务器：命令构造器把它拼成 rsync 的 `user@host:` 推送目的地。
         sdst.peer,
         item.isDirectory ? 0 : item.size)
    }

    /// 接缝闭包装配（B4/B5 可单测）：run() 传入真实 rsync 执行器；单测注入假执行器
    /// 直测令牌路（stale 分支在触连接**之前**返回，假执行器可证「被顶掉的闭包零触达」）。
    /// rsync 参数序 = (条目, peer, totalHint, 字节帧, 文件名, 取消旗)。
    static func makeDirectSeam(
        ssrc: SFTPSource, sdst: SFTPSource, cancel: CancelFlag, nameBox: DirectNameBox,
        tokenBox: DirectSeamTokenBox, myToken: Int,
        rsync: @escaping (DirectRsync.ItemTarget, DirectRsync.Peer, Int64?,
                          ((Int64, Int64) -> Void)?, @escaping (String) -> Void, CancelFlag) throws -> DirectOutcome
    ) -> (FileItem, TCPath, ((Int64, Int64) -> Void)?) throws -> DirectOutcome {
        { item, destDir, bp in
            guard tokenBox.current() == myToken else { return .unavailable("stale-seam") }
            let a = Self.directSeamArgs(ssrc: ssrc, sdst: sdst, item: item, destDir: destDir)
            let out = try rsync(a.item, a.peer, a.totalHint, bp, { n in nameBox.name = n }, cancel)
            // 路由镜像（两条都抄）：rsync 写在 src 连接，面板读 dst——黄点场景
            // （needsAuth/rsyncMissing 回退）全靠这一行。抛错路不经过这里（面板走错误态）。
            sdst.mirrorRoute(ssrc.lastCopyRoute ?? .relayed(.channelGone))
            return out
        }
    }

    /// 条目边界帧（N-a 锁可见面）：**进条目边界第一件事清直传名字盒**（盒是「当前条目
    /// 的 rsync 内文件名」——条目 1 直传成功写名后条目 2 落 pump 时，不清 = 条目 2 的
    /// pump 字节帧携带条目 1 的文件名，面板错名直到条目 2 完成帧），再构造文件完成帧。
    /// 生产 fileProgress 与本函数调用方共享这唯一实现（镜像锁=真代码，非抄写形状）。
    static func fileLevelFrame(nameBox: DirectNameBox, targets: [FileItem],
                               done: Int, total: Int, route: CopyRoute?) -> TransferProgressInfo {
        nameBox.name = nil
        let name = (1...targets.count).contains(done) ? targets[done - 1].name : ""
        return TransferProgressInfo(name: name, fileDone: done, fileTotal: total,
                                    bytesDone: nil, bytesTotal: nil, route: route)
    }

    /// 兼容入口：无取消/无逐文件进度（既有工具栏语义原样保留）。
    func run(_ isCopy: Bool, _ srcPane: FilePane, _ dstPane: FilePane) {
        run(isCopy, srcPane, dstPane, cancel: CancelFlag(), onProgress: nil)
    }

    /// 复制/移动活动窗格项到另一窗格。targets 为空则直接返回。
    ///
    /// T2 能力（**per-run 参数，不加常驻 var**——常驻回调会被后续传输互相覆盖）：
    /// - `cancel`：跨线程取消标志，透传给引擎（UI 按钮置位；生效边界见 OperationEngine 注释）。
    /// - `onProgress`：逐文件进度 + CopyRoute；字节级 50ms 节流、文件级必报；
    ///   经 onMain 投递（生产=主线程；单测=同步）。
    /// - 传输源替换：SFTP 端经 ConnectionStore.transferSource 开**独立第二连接**——
    ///   copyFile 全程持浏览源的 NSLock，复用同连接则目标窗格 listDirectory/stat
    ///   排队到传输结束（真机「目标不能浏览」根因）。多付一次 SSH 握手 = 有意的隔离代价。
    ///   建连挪在后台块内（握手数百 ms 不冻主线程）；取不到（Keychain 无 secret/建连失败）
    ///   → 回落共享浏览源 = 旧行为。同源判定是 sourceID **字符串**相等
    ///   （OperationEngine），两实例仍走 cp 快路径。
    func run(_ isCopy: Bool, _ srcPane: FilePane, _ dstPane: FilePane,
             cancel: CancelFlag,
             onProgress: ((TransferProgressInfo) -> Void)?) {
        let targets = srcPane.operationTargets
        guard !targets.isEmpty else { return }
        // 串行门（safety，见 runningFlag 注）：在飞 = 直接拒收本 run，绝不起第二个传输。
        // 拒收路不得碰 state/onFinished（它们驱动面板生命周期，由装配者按
        // isTransferRunning 先行判定；本处静默返回 = 主 VC 已 guard 过，双保险）。
        guard claimRunning() else { return }
        // per-run 令牌取号（belt-and-braces，非安全机制，见 DirectSeamTokenBox 注）。
        let myToken = seamToken.next()
        let label: L10nKey = isCopy ? .opCopying : .opMoving
        let args = ["\(targets.count)"]
        let dstDir = dstPane.path
        let prompt = self.prompt
        let engine = self.engine
        let state = self.state
        let onMain = self.onMain
        let throttle = ThrottleState()
        let nameBox = DirectNameBox()   // 直传当前文件名（B5），同 ThrottleState 盒纪律
        if let clock = progressClock { throttle.now = clock }
        let transferSourceProvider = self.transferSourceProvider

        runInBackground { [weak self] in
            // self 提前释放 = 引擎整个消失，门随宿主无关（不存在「还有后续 run」的持有者）。
            guard let self else { return }
            // 传输源替换在后台线程建连（含 SSH 握手），不冻主线程。
            // 同源判定 = sourceID 字符串相等；同源的两端共用**同一条**替身连接
            // （cp 快路径要求同一实例：同锁 + lastCopyRoute 读写同源，且省一次握手）。
            var cleanups: [() -> Void] = []
            var srcSource: FileSource = srcPane.source
            var dstSource: FileSource = dstPane.source
            let srcSub = transferSourceProvider(srcPane.source)
            if let (ts, close) = srcSub { srcSource = ts; cleanups.append(close) }
            if dstPane.source.sourceID != srcPane.source.sourceID {
                // 跨服务器：目标端另开一条独立连接。
                if let (td, close) = transferSourceProvider(dstPane.source) {
                    dstSource = td; cleanups.append(close)
                }
            } else if let (ts, _) = srcSub {
                dstSource = ts   // 同源：两端共用 srcSub（清理已在上面登记一次）
            }

            // 文件级：工具栏百分比（既有语义）+ onProgress（必报，不节流）。
            let fileProgress: (Int, Int) -> Void = { done, total in
                onMain { state?(.running(label: label, args: args,
                                         progress: total == 0 ? 0 : Double(done) / Double(total))) }
                throttle.fileDone = done
                // N-a 清盒在 fileLevelFrame 内（与单测锁同一实现）。
                let route: CopyRoute? = (dstSource as? SFTPSource)?.lastCopyRoute
                let info = TransferEngine.fileLevelFrame(nameBox: nameBox, targets: targets,
                                                         done: done, total: total, route: route)
                guard onProgress != nil else { return }
                // 文件完成 → 重置节流，保证下一文件的首个字节帧立即可报。
                throttle.lastByteReportTime = -ThrottleState.sentinel
                onMain { onProgress?(info) }
            }
            // 字节级：节流上报。
            let byteProgress: (Int64, Int64) -> Void = { done, total in
                guard onProgress != nil, throttle.shouldReportByte() else { return }
                let info = TransferEngine.byteFrame(done: done, total: total,
                                                    fileDone: throttle.fileDone,
                                                    fileTotal: targets.count,
                                                    name: TransferEngine.directName(from: nameBox))
                onMain { onProgress?(info) }
            }

            // 跨服务器直传接缝（Task 4）：启用判定与参数装配在纯静态里
            // （directSeamSources/directSeamArgs，peer 方向性由单测直锁）。
            // **每次 run 无条件重赋**（gate 不过显式置 nil）：engine 是共享实例，
            // 接缝是它身上的单个 var —— 装配者必须负责它的全部生命周期。
            // 重叠 run 的错服务器写入事故由 run() 头部的**串行门**根治（并发 run
            // 不存在 = 共享接缝永远只有一个主人；见 runningFlag 注）；令牌是 belt-and-braces
            // （见 DirectSeamTokenBox 注，非安全机制）。
            if let (ssrc, sdst) = Self.directSeamSources(src: srcSource, dst: dstSource) {
                engine.directCrossTransfer = Self.makeDirectSeam(
                    ssrc: ssrc, sdst: sdst, cancel: cancel, nameBox: nameBox,
                    tokenBox: seamToken, myToken: myToken)
                { it, p, h, b, f, c in
                    try ssrc.runDirectRsync(item: it, peer: p, totalHint: h,
                                            byteProgress: b, onFile: f, cancel: c)
                }
            } else {
                engine.directCrossTransfer = nil
            }

            onMain { state?(.running(label: label, args: args, progress: 0)) }
            var warnings: [(String, TCError)] = []
            do {
                if isCopy {
                    try engine.performCopy(targets, to: dstDir, srcSource: srcSource, dstSource: dstSource,
                                            prompt: prompt, progress: fileProgress,
                                            byteProgress: byteProgress, cancel: cancel)
                } else {
                    try engine.performMove(targets, to: dstDir, srcSource: srcSource, dstSource: dstSource,
                                            prompt: prompt, progress: fileProgress,
                                            byteProgress: byteProgress, cancel: cancel,
                                            onWarning: { warnings.append(($0, $1)) })
                }
                // 警告成品串（"源端残留：X（…）"）在本层（持 L10n 的 AppKit 边界）组装，
                // 与 CommandRouter 的 warnFormatter 注入同级；放进 onMain 块内，
                // 保证 L10n 表只在主线程读（语言切换也在主线程）。
                onMain {
                    let lines = warnings.map { L10n.t(.warnSourceLeftover, $0.0, tcErrorDisplay($0.1)) }
                    state?(.done(label: label, args: args, warningLines: lines))
                }
            } catch let e as TCError {
                onMain { state?(e == .cancelled ? .idle : .failed(e)) }
            } catch {
                onMain { state?(.failed(.unknown(error.localizedDescription))) }
            }
            // 临时传输连接：成功/失败/取消一律关闭（生命周期 = 一次传输）。
            // 接缝同时置 nil：闭包捕获本 run 的连接，留着会被下一次 run 的引擎调用
            // （连接已关 → 未定义行为）。
            engine.directCrossTransfer = nil
            for close in cleanups { close() }
            // 串行门收口：与 run() 头部的 claimRunning 成对（成功/失败/取消三路都到齐，
            // 无提前 return 路 → 门不会卡死）。
            releaseRunning()
            onMain { self.onFinished?(srcPane, dstPane) }
        }
    }
}
