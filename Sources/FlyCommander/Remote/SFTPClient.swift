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
    /// 类盒先例 = ReadCursor：@Sendable 闭包捕获类常量、锁内改属性。
    private let cpFlags = CPSupport()
    /// 上一次 copyFile 实际走过的路径（锁内写，无锁读——竞态仅影响 UI 展示时机，不影响正确性）。
    /// 供 TransferEngine 逐文件上报 CopyRoute，让 UI 显示「服务器端复制 / 本机中转（原因）」。
    private(set) var lastCopyRoute: CopyRoute = .relayed(.channelGone)

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
    func openReader(_ path: String) throws -> (Int) throws -> Data? {
        let handle: SFTPFileHandle = try performSync { try await $0.openFile(path, flags: [.read]) }
        let cursor = ReadCursor()
        return { want in
            try self.performSync { _ in
                guard !cursor.done else { return nil }
                let len = UInt32(max(1, min(Int(UInt32.max), want > 0 ? want : 64 * 1024)))
                let bytes: [UInt8]? = try await handle.read(at: cursor.offset, length: len)
                guard let bytes else {
                    cursor.done = true
                    try? await handle.close()
                    return nil
                }
                cursor.offset += UInt64(bytes.count)
                return Data(bytes)
            }
        }
    }

    /// 流式写：write 闭包拉数据，空 Data 结束。整个泵送期间持锁。
    func streamWrite(_ path: String, totalBytes: Int64?,
                     write: @escaping () throws -> Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try awaitBlocking {
            let handle = try await self.sftp.openFile(path, flags: [.write, .create, .truncate])
            do {
                while true {
                    let chunk = try write()
                    if chunk.isEmpty { break }
                    try await handle.write([UInt8](chunk))
                }
            } catch {
                try? await handle.close()
                throw error   // 原样上抛，由 SFTPSource.map 统一映射为 TCError
            }
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

            // 阶段 2：回退 pump（原实现逐字保留）。
            self.lastCopyRoute = .relayed(relayReason)
            let reader = try await self.sftp.openFile(src, flags: [.read])
            let writer = try await self.sftp.openFile(dst, flags: [.write, .create, .truncate])
            do {
                var offset: UInt64 = 0
                while true {
                    let chunk = try await reader.read(at: offset, length: 64 * 1024)
                    if chunk == nil { break }
                    try await writer.write(chunk!)
                    offset += UInt64(chunk!.count)
                }
            } catch {
                try? await reader.close()
                try? await writer.close()
                throw error
            }
            try? await reader.close()
            try? await writer.close()
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
    case relayed(RelayReason)     // 本机中转（回退 pump），带原因
}

/// 回退到本机中转 pump 的原因分类。
public enum RelayReason: Equatable {
    case execRejected        // exec 通道被服务器拒绝（ForceCommand=internal-sftp / chroot-only）
    case cpMissing           // 服务器无 cp（exit 127）
    case unsupportedFlags    // -a/-Rp 都不认（罕见 cp 方言），重试后仍不行
    case channelGone         // 通道级异常：无 exit 状态 / 空 stderr / execute 其它抛错
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

// MARK: - 读游标

/// openReader 的句柄状态。所有读写都在同一把 NSLock 保护下，无并发。
final class ReadCursor {
    var offset: UInt64 = 0
    var done = false
}

/// cp -a 支持缓存。类盒（同 ReadCursor 模式）：@Sendable 闭包只捕获不可变引用，
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
