import Foundation
import TCCore
import Traversio

/// SFTP 连接配置。认证支持密码与 OpenSSH 私钥文件（可带 passphrase）两种。
public struct SFTPConnectionConfig {
    public enum Auth {
        case password(String)
        case keyFile(path: String, passphrase: String? = nil)
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

    /// 同源（同一 SFTP 连接）复制：两个句柄同时打开，一个 async 块内泵完。
    func copyFile(from src: String, to dst: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try awaitBlocking {
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

// MARK: - 读游标

/// openReader 的句柄状态。所有读写都在同一把 NSLock 保护下，无并发。
final class ReadCursor {
    var offset: UInt64 = 0
    var done = false
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
        guard let v = value else { throw TCError.unknown("SFTP 操作未执行") }
        return try v.get()
    }
}
