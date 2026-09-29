import Foundation
import TCCore
import Traversio

/// SFTP 连接配置（运行时，含凭据）。认证支持密码与 OpenSSH 私钥文件（可带 passphrase）。
/// **不可持久化**：密码/passphrase 只存在于内存；持久化走 SFTPConnectionRecord（不含密钥）。
public struct SFTPConnectionConfig: Equatable {
    public enum Auth: Equatable {
        case password(String)
        case keyFile(path: String, passphrase: String? = nil)

        /// AuthKind（持久化层用），由运行时认证类型映射。
        var keyKind: SFTPConnectionRecord.AuthKind {
            switch self {
            case .password: return .password
            case .keyFile:  return .keyFile
            }
        }
        /// keyFile 认证时的私钥路径（password 认证时为 nil）。
        var keyPath: String? {
            if case .keyFile(let path, _) = self { return path }
            return nil
        }
    }

    public let host: String
    public let port: UInt16
    public let username: String
    public let auth: Auth

    public init(host: String, port: UInt16 = 22, username: String, auth: Auth) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }

    /// 数据源标识（同源判定用），与 SFTPSource.sourceID 一致。
    public var sourceID: String {
        var s = "sftp://\(host)"
        if port != 22 { s += ":\(port)" }
        return s
    }

    /// 凭据账号（Keychain 键）：host:port:username。
    public var credentialAccount: String { "\(host):\(port):\(username)" }
}

/// 主机密钥 TOFU 存储（自管 UserDefaults，与系统 known_hosts 无关）。
final class SFTPHostKeyStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func policy() -> SSHHostKeyPolicy {
        SSHHostKeyPolicy.trustOnFirstUse(
            lookup: { host, port in
                let key = "sftp://\(host):\(port)"
                guard let data = self.defaults.data(forKey: key) else { return nil }
                return try SSHTrustedHostKey(rawRepresentation: [UInt8](data))
            },
            store: { request in
                let key = "sftp://\(request.endpointHost):\(request.endpointPort)"
                self.defaults.set(Data(request.trustedHostKey.rawRepresentation), forKey: key)
            }
        )
    }
}

/// Traversio 连接的薄封装：连接/断开成对释放；async→sync 桥接在此。
///
/// 并发设计（重要）：
/// - 序列化用 NSLock，**全程不创建 DispatchQueue**。
///   本环境（Xcode 26.6 缩减 SDK）下，Swift Concurrency 运行时启动后
///   再创建 DispatchQueue 会在泛型元数据缓存里段错误（_swift_getGenericMetadata），
///   故桥接只用 Task + DispatchSemaphore（C API，无泛型元数据）。
/// - 主线程调用方会阻塞（runloop 冻结）——应用侧一律走 loadQueue/后台队列，
///   仅测试允许主线程调用。
final class SFTPConnection {
    private let sftp: SFTPClient
    private let conn: SSHConnection
    private let lock = NSLock()
    private var closed = false
    /// 服务器 cp 是否支持 -a（连接级缓存：nil=未知，false=BSD 方言用 -Rp）。
    /// 类盒先例 = CPSupport/PrefetchReader：@Sendable 闭包捕获类常量、锁内改属性。
    private let cpFlags = CPSupport()
    /// 传输在途峰值观测盒（DEBUG 鉴别力锁用，见 PipelinedTransferTests）。
    /// 读路预取窗 / 写路并发窗各自记录历史最大在途请求数；旧串行实现恒 1。
    let transferPeaks = PumpPeaks()
    /// 上一次复制实际走过的路径。写纪律：**后台传输线程**（copyFile 在 lock 内写；
    /// runDirectRsync/setRoute 在接缝闭包里写——接缝本就只被 performCopy/performMove
    /// 的后台块调用，与 lock 无涉）。读取（lastCopyRoute）无锁——UI 只经
    /// TransferEngine 的文件级帧拿值，竞态仅影响展示时机，不影响正确性。
    /// 供 TransferEngine 逐文件上报 CopyRoute，让 UI 显示「服务器端复制 / 本机中转（原因）」。
    /// **初值 nil = 还没走过任何复制 = 路由未知**（面板据此隐藏路由行）。旧初值
    /// `.relayed(.channelGone)` 会在「接缝 gate 过但条目被目标同名守卫挡下走 pump」
    /// 这类无写点场景露出 = 「命令通道异常」谎话上屏。未知就该显示未知。
    private(set) var lastCopyRoute: CopyRoute?

    init(config: SFTPConnectionConfig, store: SFTPHostKeyStore) throws {
        let authMethod: SSHAuthenticationMethod
        switch config.auth {
        case .password(let password):
            authMethod = .password(password)
        case .keyFile(let path, let passphrase):
            authMethod = try .privateKeyPEM(contentsOfFile: path, passphrase: passphrase)
        }
        let configuration = SSHClientConfiguration(
            host: config.host,
            port: config.port,
            username: config.username,
            authentication: authMethod,
            hostKeyPolicy: store.policy()
        )
        // connect + openSFTP 在同一 async 块里；失败时成对释放。
        let pair = try awaitBlocking { () -> (SSHConnection, SFTPClient) in
            let connection = try await SSHClient.connect(configuration: configuration)
            do {
                let s = try await connection.openSFTP()
                return (connection, s)
            } catch {
                await connection.close()
                throw error
            }
        }
        self.conn = pair.0
        self.sftp = pair.1
    }

    /// 串行执行一个 async 操作（NSLock 保护 SFTPClient 单线程访问）。
    func performSync<T>(_ op: @escaping @Sendable (SFTPClient) async throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try awaitBlocking { try await op(self.sftp) }
    }

    /// 打开读句柄并桥接；返回同步闭包，每次调用独立持锁，
    /// 句柄随最后一次调用（读到 EOF 或出错）关闭。
    ///
    /// 读路 = **预取窗口流水线**（提速核心）。旧实现每调一次闭包 = 一个完整
    /// READ 往返，拿到才轮到写 → 每块 2 个 RTT 串行。现改为：首次一次性在 src
    /// 连接的 actor 上挂 `SFTPTransfer.window` 个 offset 递增的在途 READ Task，
    /// 之后每次调用 await 队首、pop、续发一个补满窗口。被 await 的 Task 在
    /// **闭包返回后的写往返期间继续在后台跑** → 读与写跨窗重叠。
    ///
    /// 正确性锚点：Traversio `SSHSFTPClient` 是 actor，同句柄多在途 READ 是其自带
    /// `readFileWithConsumedRequests` 的同款用法（sendReadRequest×K 后按序 receive）；
    /// `read(at:)` 显式 offset → 乱序完成不影响按序吐数据（队首恒 = 最小未回收 offset）。
    func openReader(_ path: String) throws -> (Int) throws -> Data? {
        let handle: SFTPFileHandle = try performSync { try await $0.openFile(path, flags: [.read]) }
        // 全部窗口状态在类盒内，闭包只捕获不可变引用；变更全在 src NSLock 临界区内。
        let box = PrefetchReader(handle: handle, peaks: transferPeaks)
        return { want in
            try self.performSync { _ in try await box.next(want: want) }
        }
    }

    /// 流式写：write 闭包拉数据，空 Data 结束。整个泵送期间持锁。
    ///
    /// 写路 = **并发窗口流水线**（提速核心）。旧实现 `await handle.write` 逐块串行
    /// 阻塞 → 每块等一个完整 WRITE 往返。现改为：窗口有空位且未 EOF 时同步拉一块、
    /// 发一个 offset 定向 `write(_:at:)` Task 入窗（不 await）；窗口满才 await 队首。
    /// 在途写 Task 在 actor 上并发 → 多个 WRITE 同时在飞。
    ///
    /// 正确性锚点：`write(_:at:)` 显式 offset（非游标版）→ 各块写区间互不重叠，
    /// 完成顺序无关；FIFO 入队仅约束「等谁腾窗口」，不约束落盘序（offset 已定）。
    /// 拉数据闭包（进 src 锁）在窗口空位时同步发出 → 读写天然跨窗重叠。
    func streamWrite(_ path: String, totalBytes: Int64?,
                     write: @escaping () throws -> Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try awaitBlocking {
            let handle = try await self.sftp.openFile(path, flags: [.write, .create, .truncate])
            let window = WriteWindow(handle: handle, peaks: self.transferPeaks)
            do {
                // 同步拉数据闭包桥进 async 合同（唯一非真 async 的调用点）。
                try await window.pump { try write() }
            } catch {
                // cancelRemaining=true 路吞次生错误（抛的是原始错误）→ try?。
                try? await window.drain(cancelRemaining: true)
                try? await handle.close()
                throw error   // 原样上抛，由 SFTPSource.map 统一映射为 TCError
            }
            // 正常收尾：EOF 已在 pump 内触发（write() 返回空 Data），此处只需排干在途写。
            try await window.drain(cancelRemaining: false)
            try? await handle.close()
        }
    }

    /// 同源（同一 SFTP 连接）复制：**优先服务器端 exec `cp`**（字节不出服务器，且
    /// cp -a 天然支持目录、保留权限/时间戳/符号链接）；exec 通道被拒（chroot-only /
    /// ForceCommand=internal-sftp 账号）时**静默回退**旧双句柄 pump（字节走
    /// 服务器→本机→服务器，仅普通文件，目录会报错——维持 pump 时代语义）。
    ///
    /// 不变量：调用前 OperationEngine.resolveConflict 对「覆盖」已先 removeItem(dst)，
    /// 故 cp 永远面对不存在的目标——无需 -f，也无「目录拷进已存在目录」歧义。
    ///
    /// 失败分类（设计已核实 Traversio 行为）：
    /// - execute **抛错** = exec 通道级失败（未建立）→ 回退 pump；
    /// - 返回 exitStatus == nil = 通道异常关闭 → 回退 pump；
    /// - 返回非零 = cp 命令真失败（权限/磁盘满等）→ 带 stderr 抛错**不回退**
    ///   （pump 会撞同一堵墙，回退只会把清晰诊断洗成含糊错误）。
    ///
    /// 语义分叉（有意）：同源（服务器端 cp）保留符号链接/权限/时间戳，
    /// 跨源（客户端中转 pump）不保留——保真度以服务器端为基准。
    ///
    /// 回退可见化：每次复制把**实际路径与原因**写进 lastCopyRoute（锁内），
    /// 供 UI 显示「服务器端复制 / 本机中转（原因）」。pump 不是失败——它是
    /// 受限服务器上的正解路径，只是字节过本机；用户有权知道是哪条。
    func copyFile(from src: String, to dst: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try awaitBlocking {
            // 阶段 1：exec cp。cpFlags.supportsA 是连接级缓存：不同服务器 cp 方言不同
            // （GNU 有 -a；BSD/macOS 只有 -Rp），首次撞 unknown option 后换 flag 重试。
            let useA = self.cpFlags.supportsA != false
            var outcome = await self.runCp(src: src, dst: dst, useA: useA)
            if case .relay(.unsupportedFlags) = outcome, useA {
                self.cpFlags.supportsA = false
                outcome = await self.runCp(src: src, dst: dst, useA: false)
            }
            let relayReason: RelayReason
            switch outcome {
            case .ok:
                self.lastCopyRoute = .serverSide
                return
            case .fail(let msg):
                // 命令级失败：不回退（pump 会撞同一错误且诊断更差）。
                throw TCError.unknown("cp: \(msg)")
            case .relay(let reason):
                relayReason = reason
            }

            // 阶段 2：回退 pump（同源双句柄，读窗+写窗流水线）。单连接单锁，
            // reader/writer 两 Task 都挂在同一 actor 上并发（同 transferSource 独享）。
            self.lastCopyRoute = .relayed(relayReason)
            let readerHandle = try await self.sftp.openFile(src, flags: [.read])
            let writerHandle = try await self.sftp.openFile(dst, flags: [.write, .create, .truncate])
            let reader = PrefetchReader(handle: readerHandle, peaks: self.transferPeaks)
            let writer = WriteWindow(handle: writerHandle, peaks: self.transferPeaks)
            do {
                // pull 同步语义：每次从读窗要一块，nil(EOF) → 空 Data 结束写窗。
                try await writer.pump {
                    guard let chunk = try await reader.next(want: SFTPTransfer.chunkSize),
                          !chunk.isEmpty else { return Data() }
                    return chunk
                }
            } catch {
                try? await writer.drain(cancelRemaining: true)
                try? await readerHandle.close()
                try? await writerHandle.close()
                throw error
            }
            try await writer.drain(cancelRemaining: false)
            try? await readerHandle.close()
            try? await writerHandle.close()
        }
    }

    /// 在 copyFile 的锁内执行一次远程 cp 并分类结果。**调用方必须已持 lock**。
    /// execute 抛错分类逻辑委托 ServerSideCopy.relayReason(for:)：
    /// - exec 通道被服务器拒绝（ForceCommand=internal-sftp / chroot-only）→ relay(.execRejected)；
    /// - 其余 throw（连接断/超时/通道关闭等）→ relay(.channelGone)。
    private func runCp(src: String, dst: String, useA: Bool) async -> ServerSideCopy.Result {
        do {
            let r = try await self.conn.execute(ServerSideCopy.command(src: src, dst: dst, useA: useA))
            return ServerSideCopy.classify(exitStatus: r.exitStatus, stderr: ServerSideCopy.stderrText(r))
        } catch {
            return .relay(ServerSideCopy.relayReason(for: error))
        }
    }

    /// 跨服务器直传：本连接（A）上 exec rsync 推到 peer（B）。**不持 SFTP lock**
    /// （exec 通道独立于 sftp 子系统；持锁会把目标窗格浏览挡到 rsync 结束——
    /// copyFile 持锁是两阶段秒级操作，rsync 可分钟级，语义不同）。
    /// 认证前提：A→B 密钥信任在场；B 需要口令 → 命令里的 -oBatchMode=yes 立即失败。
    /// 调用方（TransferEngine 接缝）保证在后台线程。
    ///
    /// 路由回传约定（重要）：本方法把结果写进**本（src）连接**的 lastCopyRoute，
    /// 但面板 fileProgress 读的是**目标**源的路由 → 调用方拿到返回值后必须
    /// `dst.mirrorRoute(src.lastCopyRoute)`，且 `.handled` 与 `.unavailable` **两条都镜像**
    /// （回退路的黄点就靠 unavailable 这条）。抛错路不镜像（面板走错误态）。
    func runDirectRsync(item: DirectRsync.ItemTarget, peer: DirectRsync.Peer,
                        totalHint: Int64?,
                        byteProgress: ((Int64, Int64) -> Void)?,
                        onFile: ((String) -> Void)? = nil,
                        cancel: CancelFlag?) throws -> DirectOutcome {
        try awaitBlocking { () -> DirectOutcome in
            let session: SSHSession
            do { session = try await self.conn.openExec(DirectRsync.command(item: item, peer: peer)) }
            catch {
                // 通道级失败也要写路由（终审 B3，见 channelIssue 注）：接缝随后把本连接
                // lastCopyRoute 镜像给 dst，不写 = 镜像上一条 → 假绿点。
                let issue = Self.channelIssue(error)
                self.lastCopyRoute = issue.route
                return issue.outcome
            }
            defer { Task { try? await session.close() } }  // 结束/取消统一关通道 → 远端 rsync 收 SIGHUP
            let parser = RsyncProgressParser()
            var stderrBuf = Data()
            var exit: UInt32?
            var cancelled = false
            while true {
                if cancel?.isCancelled == true { cancelled = true; break }
                // nextEvent 真抛 = 通道级异常 → 转 .unavailable（与 copyFile 的 execute
                // 抛错同政策：能力/通道问题回退 pump，不当传输失败）。
                // 已知限制（终审 N4 carry）：取消只在事件边界生效，rsync 静默
                // （无数据/无 exit）时延迟无上界——与 exec cp「等当前文件自然完成」同档。
                let ev: SSHSessionEvent?
                do { ev = try await session.nextEvent() }
                catch {
                    let issue = Self.channelIssue(error)   // 同上（B3）：不写 = 镜像假绿
                    self.lastCopyRoute = issue.route
                    return issue.outcome
                }
                guard let ev else { break }   // nil = 通道关
                switch ev {
                case .standardOutput(let b): parser.feed(String(decoding: b, as: UTF8.self))
                case .standardError(let b):
                    stderrBuf.append(contentsOf: b)
                    parser.feed(String(decoding: b, as: UTF8.self))
                case .exitStatus(let s): exit = s
                case .exitSignal, .endOfFile: break
                }
                // 进度桥（合同：`.unavailable` 必须零字节帧）：只在解析出真实
                // 进度行后才转帧——认证失败/rsync 缺失等「一字节未动」的回退路全程
                // 静默。帧的**范围**由 progressFrame 按条目类型定（终审 B2：逐条目
                // 合同，目录不得拿当前文件 total 当分母）；parser 每条目新建 →
                // fileBytesDone 天然 = 本条目已传。名字（spec 决策 #2）= 本事件周期
                // 内被数值行消费掉的文件名，拉取后清空（面板空名沿用上一帧）。
                if parser.fileBytesDone > 0 {
                    // 名字先拉后发帧：帧名 = 本事件周期被数值行消费掉的文件名
                    // （spec 决策 #2；pump 路字节帧无名 = 面板沿用上一帧）。
                    let name = parser.consumedFileName
                    if let name { onFile?(name) }
                    parser.consumedFileName = nil
                    // 零字节帧闸门（Task 4 合同）：`.unavailable` 必须零帧——只在
                    // 解析出真实进度后才转帧（认证失败/rsync 缺失等全程静默）。
                    if let bp = byteProgress {
                        let f = DirectRsync.progressFrame(isDirectory: item.isDirectory,
                                                         entryDone: parser.fileBytesDone,
                                                         totalHint: totalHint)
                        bp(f.done, f.total)
                    }
                }
            }
            // 取消：上抛不回退（defer 已关通道，rsync 收 SIGHUP；非 --partial →
            // rsync 自弃 .*.tmp，目标不留半截）。
            if cancelled { throw TCError.cancelled }
            switch DirectRsync.classify(exitStatus: exit,
                                        stderr: String(decoding: stderrBuf, as: UTF8.self)) {
            case .ok:
                self.lastCopyRoute = .directCrossHost
                return .handled(bytesTransferred: parser.fileBytesDone)
            case .fail(let msg):
                throw TCError.unknown("rsync: \(msg)")
            case .relay(let reason):
                self.lastCopyRoute = .relayed(reason)
                return .unavailable(reason.diagnosticCode)
            }
        }
    }

    /// 通道级异常 → (路由, 接缝返回值)（终审 B3）：**两条异常路（openExec 抛 /
    /// nextEvent 抛）必须写路由**——lastCopyRoute 是连接级持久态，不覆盖 = 面板
    /// 镜像**上一条**（可能 .directCrossHost）→ 假绿点，违 spec 唯一硬承诺
    /// （绿=字节不出本机）。真 SSHSession 无法伪造（Traversio 具体类型），
    /// 本函数 = 两条 catch 共享的分类面，单测直锁；`lastCopyRoute = 路由` 这条
    /// 赋值语句本身靠 belt-and-braces：接缝镜像的 nil 兜底恒黄不假绿。
    static func channelIssue(_ error: Error) -> (route: CopyRoute, outcome: DirectOutcome) {
        let reason = ServerSideCopy.relayReason(for: error)
        return (.relayed(reason), .unavailable(reason.diagnosticCode))
    }

    /// 面板路由镜像写入（接缝用）：把 src 连接算出的 CopyRoute 抄给本连接，
    /// 使 TransferEngine 对**目标**源 lastCopyRoute 的读取看到直传真值。
    func setRoute(_ route: CopyRoute) { self.lastCopyRoute = route }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        let s = sftp, c = conn
        Task {
            try? await s.close()
            await c.close()
        }
    }

    deinit {
        let s = sftp, c = conn
        Task {
            try? await s.close()
            await c.close()
        }
    }
}

// MARK: - 服务器端复制命令（纯函数，可单测）

/// 本次复制**实际走过的路径**（回退可见化用，SFTPConnection.lastCopyRoute）。
/// pump 不是失败——是受限服务器上的正解，只是字节过本机；用户有权知道是哪条。
/// public：经 SFTPSource.lastCopyRoute → TransferProgressInfo.route 抵达 UI 层。
public enum CopyRoute: Equatable {
    case serverSide               // exec cp 成功（字节不出服务器）
    case directCrossHost          // 跨服务器 rsync 直传（字节不出服务器对）
    case relayed(RelayReason)     // 本机中转（回退 pump），带原因
}

/// 回退到本机中转 pump 的原因分类。
public enum RelayReason: Equatable {
    case execRejected        // exec 通道被服务器拒绝（ForceCommand=internal-sftp / chroot-only）
    case cpMissing           // 服务器无 cp（exit 127）
    case unsupportedFlags    // -a/-Rp 都不认（罕见 cp 方言），重试后仍不行
    case channelGone         // 通道级异常：无 exit 状态 / 空 stderr / execute 其它抛错
    case needsAuth           // 双机免密信任未建立（或 B 端密码认证）
    case rsyncMissing        // 源服务器无 rsync（exit 127）
}

extension RelayReason {
    /// 稳定英文诊断码：仅作 DirectOutcome.unavailable(String) 的透传诊断
    /// （日志/断言用）。UI 文案走 CopyRoute 枚举，绝不对此串做 round-trip。
    var diagnosticCode: String {
        switch self {
        case .needsAuth:        return "needsAuth"
        case .rsyncMissing:     return "rsyncMissing"
        case .execRejected:     return "execRejected"
        case .channelGone:      return "channelGone"
        case .cpMissing:        return "cpMissing"
        case .unsupportedFlags: return "unsupportedFlags"
        }
    }
}

enum ServerSideCopy {
    /// classify/runCp 的结果：成功 / cp 命令级失败（带 stderr，不回退）/ 回退 pump（带原因）。
    enum Result: Equatable {
        case ok
        case fail(String)
        case relay(RelayReason)
    }

    /// POSIX 单引号引用：整体包 '…'，内部单引号转成 '\''。
    /// 单引号内 $ ` \ 等全部字面化——恶意/畸形文件名（服务器可返回任意名）的注入面就此封死。
    static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// -a = -dR --preserve=all（GNU/BusyBox）；-Rp 是 BSD 等价（无 xattr 保留）。
    /// `--` 终止选项：路径以 - 开头时不被当 flag。
    static func command(src: String, dst: String, useA: Bool) -> String {
        "cp \(useA ? "-a" : "-Rp") -- \(shellQuote(src)) \(shellQuote(dst))"
    }

    static func stderrText(_ r: SSHExecResult) -> String {
        String(decoding: r.standardError, as: UTF8.self)
    }

    /// exitStatus → 分类：
    /// - 0 → ok；
    /// - 127（cp 不存在）→ relay(.cpMissing)：服务器能力缺失，pump 还能干活；
    /// - nil（通道未报状态）或非零但 stderr 为空（受限 shell 把话说到 stdout 等）→
    ///   relay(.channelGone)：无有效诊断可保留，交 pump 兜底；
    /// - 非零且 stderr 报「不认 flag」→ relay(.unsupportedFlags)（上层换 -Rp 重试一次）；
    /// - 其余非零 → fail（命令真失败，不回退——pump 会撞同一错误且洗掉诊断）。
    static func classify(exitStatus: UInt32?, stderr: String) -> Result {
        guard let status = exitStatus else { return .relay(.channelGone) }
        if status == 0 { return .ok }
        if status == 127 { return .relay(.cpMissing) }
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { return .relay(.channelGone) }
        if (status == 1 || status == 64)
            && (msg.contains("invalid option") || msg.contains("illegal option")) {
            return .relay(.unsupportedFlags)
        }
        return .fail(msg)
    }

    /// execute 抛出的错误 → 回退原因。区分「服务器明确不让跑命令」与「连接/通道死了」：
    /// - .requestFailed / .unsupportedRequest：Traversio 把 SSHConnectionError.channelRequestFailed
    ///   映射成 code==.requestFailed（ForceCommand=internal-sftp / chroot-only 拒绝 exec 通道请求
    ///   ——正是本机有流量的现场），归 execRejected（这不是故障，是服务器策略）；
    /// - .channelOpenFailed：连 session 通道都不给开（最受限服务器），同归 execRejected；
    /// - 其余（transportClosed/remoteDisconnect/timeout/POSIX…）：连接级异常，归 channelGone。
    /// 判据经 Traversio SSHClientOperationDiagnostics.wrapConnectionOperationFailure 核对。
    static func relayReason(for error: Error) -> RelayReason {
        guard case SSHClientError.operationFailed(let f)? = error as? SSHClientError else {
            return .channelGone
        }
        switch f.code {
        case .requestFailed, .unsupportedRequest, .channelOpenFailed:
            return .execRejected
        default:
            return .channelGone
        }
    }
}

// MARK: - 泵送流水线（读预取窗 + 写并发窗）

/// 跨源/回退 pump 的块大小与并发窗口（读、写各一套，共用常量）。
/// chunkSize=256KB = Traversio 包上限（SSHSFTPMessageCodec.defaultMaximumPacketLength），
/// READ 侧被 effectiveReadLength 自动钳制，WRITE 侧超长由 writeFile 内部顺序分片。
/// window=4 → 读写各最多 4 个在途请求（≈1MB 在途 ×2）。
enum SFTPTransfer {
    static let chunkSize = 256 * 1024
    static let window = 4
}

/// 在途峰值观测盒（PipelinedTransferTests 鉴别力锁；更新点只在两窗入队处，
/// 成本 = 每块一次 NSLock，可忽略）。所有窗状态变更本就串行于各自锁内，
/// 但观测盒跨连接/测试线程读写 → 自带锁。
final class PumpPeaks: @unchecked Sendable {
    private let lock = NSLock()
    private var read = 0
    private var write = 0

    func noteRead(_ inflight: Int) {
        lock.lock(); if inflight > read { read = inflight }; lock.unlock()
    }
    func noteWrite(_ inflight: Int) {
        lock.lock(); if inflight > write { write = inflight }; lock.unlock()
    }
    var maxReadInflight: Int { lock.lock(); defer { lock.unlock() }; return read }
    var maxWriteInflight: Int { lock.lock(); defer { lock.unlock() }; return write }
    func reset() { lock.lock(); read = 0; write = 0; lock.unlock() }
}

/// openReader 的预取读窗。**全部状态变更只发生在 src 连接 NSLock 临界区内**
/// （openReader 闭包的 performSync 里，或 copyFile 阶段 2 的单次持锁块里）——
/// 类盒 + @unchecked Sendable 的先例 = CPSupport。
///
/// **为什么需要「发现式块长」**（实测，非臆测）：OpenSSH sftp-server 把 READ 请求钳到
/// 自己的上限 —— 探针实测请求 262144 返回 **261120**，即**每一块都是短读**。若按
/// 「返回长度 < 请求长度 = 短读」判退化，流水线在首块即被打回串行 = 提速全废。
/// 故首块单发**探明有效块长**（stride），之后按 stride 定长预取 → 满块恒等长、
/// 偏移天然对齐；真短读（count < stride，只出现在接近 EOF）才弃在途退化串行。
final class PrefetchReader: @unchecked Sendable {
    private struct Entry { let offset: UInt64; let task: Task<[UInt8]?, Error> }
    private enum Phase { case discovering, pipelined, serial }

    private let handle: SFTPFileHandle
    private let peaks: PumpPeaks?
    private var queue: [Entry] = []
    /// 唯一真相 = 消费者下一次拿到的字节起点（随**实际**返回长度推进）。
    /// 预取偏移全部从它派生 —— 按请求长度推进游标会跳字节（对齐 Traversio
    /// readFileWithConcurrentRequests 的 nextOffsetToAppend 语义）。
    private var byteCursor: UInt64 = 0
    private var scheduledFrontier: UInt64 = 0   // 已投机发到的偏移（= 下一预取起点）
    private var phase: Phase = .discovering
    private var stride: UInt32 = 0               // 探明的有效块长（满块等长判据）
    private var finished = false

    init(handle: SFTPFileHandle, peaks: PumpPeaks?) {
        self.handle = handle
        self.peaks = peaks
    }

    /// 取下一块（合同 = ReadHandle：nil=EOF，之后再调恒 nil；EOF/出错均已关句柄）。
    /// async：await 队首 Task 期间，其余在途 READ 在 actor 上继续跑。
    func next(want: Int) async throws -> Data? {
        if finished { return nil }
        switch phase {
        case .discovering: return try await discover(want: want)
        case .serial:      return try await readOne(offset: byteCursor, length: stride)
        case .pipelined:   return try await pipelined()
        }
    }

    /// 首块：单发探明服务器实际给的块长 → 定为 stride → 转流水线。
    private func discover(want: Int) async throws -> Data? {
        let len = UInt32(max(1, min(SFTPTransfer.chunkSize,
                                    want > 0 ? want : SFTPTransfer.chunkSize)))
        guard let data = try await readOne(offset: byteCursor, length: len) else { return nil }
        stride = UInt32(data.count)          // 实际满块长（可能 < 请求，如 261120）
        phase = .pipelined
        scheduledFrontier = byteCursor
        return data
    }

    private func pipelined() async throws -> Data? {
        while queue.count < SFTPTransfer.window {
            schedule(offset: scheduledFrontier, length: stride)
            scheduledFrontier += UInt64(stride)
        }
        peaks?.noteRead(queue.count)
        guard !queue.isEmpty else {
            finished = true
            try? await handle.close()
            return nil
        }

        let head = queue.removeFirst()
        let bytes: [UInt8]?
        do {
            bytes = try await head.task.value
        } catch {
            await drainInflight()
            finished = true
            try? await handle.close()
            throw error   // 原样上抛（错误映射在 SFTPSource.mapped）
        }
        // 不变量：投机窗口连续无洞 → 队首恒 = 最小未回收偏移。错位 = 结构性 bug，
        // 宁可崩也别静默产出错文件。
        precondition(head.offset == byteCursor,
                     "读窗队首偏移 \(head.offset) != 消费游标 \(byteCursor)")
        guard let bytes, !bytes.isEmpty else {
            // EOF（显式 nil 或空块）：排干在途（各自也应回 nil/空；出错忽略），关句柄。
            await drainInflight()
            finished = true
            try? await handle.close()
            return nil
        }
        byteCursor = head.offset + UInt64(bytes.count)
        if bytes.count < Int(stride) {
            // 真短读（< 探明的有效块长）= 接近 EOF：投机窗口按 stride 排的已错位 →
            // 弃在途、退化单发，从 byteCursor（真实位置）串行续读到 EOF。
            await drainInflight()
            phase = .serial
            scheduledFrontier = byteCursor
        }
        return Data(bytes)
    }

    /// 单发路径（发现阶段 / 短读退化后）：一次一块、游标按实际推进；nil=EOF 且关句柄。
    private func readOne(offset: UInt64, length: UInt32) async throws -> Data? {
        let h = handle
        let bytes: [UInt8]?
        do { bytes = try await h.read(at: offset, length: length) }
        catch { finished = true; try? await h.close(); throw error }
        guard let bytes, !bytes.isEmpty else {
            finished = true
            try? await handle.close()
            return nil
        }
        byteCursor = offset + UInt64(bytes.count)
        return Data(bytes)
    }

    private func schedule(offset: UInt64, length: UInt32) {
        let h = handle
        queue.append(Entry(offset: offset, task: Task { try await h.read(at: offset, length: length) }))
    }

    private func drainInflight() async {
        for e in queue { _ = try? await e.task.value }
        queue.removeAll()
    }
}

/// streamWrite / copyFile 阶段 2 的并发写窗。状态变更只在持有 dst 锁的
/// 单一 awaitBlocking 任务内进行 → 类盒无内部锁（@unchecked 理由同 PrefetchReader）。
///
/// `write(_:at:)` 显式 offset：各块区间互不重叠 → 完成顺序无关，FIFO 只界定
/// 「等谁腾窗口」。超长块由 Traversio writeFile 内部顺序分片（合同不变）。
final class WriteWindow: @unchecked Sendable {
    private struct Entry { let task: Task<Void, Error> }

    private let handle: SFTPFileHandle
    private let peaks: PumpPeaks?
    private var queue: [Entry] = []
    private var offset: UInt64 = 0

    init(handle: SFTPFileHandle, peaks: PumpPeaks?) {
        self.handle = handle
        self.peaks = peaks
    }

    /// 泵送主循环：窗口有空位且未 EOF → 同步拉一块入窗；窗口满 → await 队首。
    /// pull 抛错（含取消）/ 写 Task 抛错 → 原样上抛给调用方（其负责 drain+close）。
    func pump(_ pull: @escaping @Sendable () async throws -> Data) async throws {
        var eof = false
        while !eof || !queue.isEmpty {
            while !eof && queue.count < SFTPTransfer.window {
                let chunk = try await pull()
                if chunk.isEmpty { eof = true; break }
                let off = offset
                offset += UInt64(chunk.count)
                let bytes = [UInt8](chunk)
                let h = handle
                queue.append(Entry(task: Task { try await h.write(bytes, at: off) }))
                peaks?.noteWrite(queue.count)
            }
            if !queue.isEmpty {
                let head = queue.removeFirst()
                try await head.task.value
            }
        }
    }

    /// 排干全部在途写。cancelRemaining=false（EOF 正常收尾）时，任一在途写错误
    /// 上抛（半截文件绝不能静默成功）；true（异常路径收尾）时吞掉次生错误，
    /// 由调用方抛原始错误。
    func drain(cancelRemaining: Bool) async throws {
        var firstError: Error?
        for e in queue {
            do { _ = try await e.task.value }
            catch { if firstError == nil { firstError = error } }
        }
        queue.removeAll()
        if let firstError, !cancelRemaining { throw firstError }
    }
}

/// cp -a 支持缓存。类盒（同 PrefetchReader 模式）：@Sendable 闭包只捕获不可变引用，
/// 属性变更全部发生在 lock 临界区内，无并发。
final class CPSupport {
    var supportsA: Bool?
}

// MARK: - async → sync 桥接 helper（Task + DispatchSemaphore，不建任何队列）

/// 阻塞等待一个 async 块完成。实现：一次性 Task + DispatchSemaphore。
/// - 调用线程会被阻塞：应用侧务必在非主线程调用（否则 runloop 冻结）；
///   测试允许主线程调用（冻结只影响本进程 UI，不影响正确性）。
/// - 长传输不设硬超时（SFTP 大文件可能 >5min）；连接断开会由 body 抛错返回。
func awaitBlocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do { box.set(.success(try await body())) }
        catch { box.set(.failure(error)) }
        sem.signal()
    }
    sem.wait()
    return try box.take()
}

/// 线程安全的一次性结果盒。
final class ResultBox<T> {
    private let lock = NSLock()
    private var value: Result<T, Error>?

    func set(_ r: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = r
    }

    func take() throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let v = value else { throw TCError.sftpNotExecuted }
        return try v.get()
    }
}
