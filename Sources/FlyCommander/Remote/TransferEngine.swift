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
        let label: L10nKey = isCopy ? .opCopying : .opMoving
        let args = ["\(targets.count)"]
        let dstDir = dstPane.path
        let prompt = self.prompt
        let engine = self.engine
        let state = self.state
        let onMain = self.onMain
        let throttle = ThrottleState()
        if let clock = progressClock { throttle.now = clock }
        let transferSourceProvider = self.transferSourceProvider

        runInBackground { [weak self] in
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
                guard let onProgress, (1...targets.count).contains(done) else { return }
                let route: CopyRoute? = (dstSource as? SFTPSource)?.lastCopyRoute
                let info = TransferProgressInfo(name: targets[done - 1].name,
                                                fileDone: done, fileTotal: total,
                                                bytesDone: nil, bytesTotal: nil, route: route)
                // 文件完成 → 重置节流，保证下一文件的首个字节帧立即可报。
                throttle.lastByteReportTime = -ThrottleState.sentinel
                onMain { onProgress(info) }
            }
            // 字节级：节流上报；total==0（大小未知）引擎根本不会调到这里（宁缺毋假）。
            let byteProgress: (Int64, Int64) -> Void = { done, total in
                guard onProgress != nil, throttle.shouldReportByte() else { return }
                let info = TransferProgressInfo(name: "", fileDone: throttle.fileDone,
                                                fileTotal: targets.count,
                                                bytesDone: done, bytesTotal: total, route: nil)
                onMain { onProgress?(info) }
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
            for close in cleanups { close() }
            onMain { self.onFinished?(srcPane, dstPane) }
        }
    }
}
