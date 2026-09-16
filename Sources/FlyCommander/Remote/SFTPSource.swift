import Foundation
import TCCore
import Traversio

/// SFTP 数据源：实现完整 FileSource 面（浏览 + 元操作 + 流式读写）。
/// 惰性建连：首次操作时连接并复用；断开由调用方显式 closeConnection。
public final class SFTPSource: FileSource {
    public let config: SFTPConnectionConfig
    public internal(set) var homeDirectory: String
    private let store: SFTPHostKeyStore
    internal private(set) var _connection: SFTPConnection?

    init(config: SFTPConnectionConfig,
         homeDirectory: String = "/",
         hostKeyStore: SFTPHostKeyStore = SFTPHostKeyStore()) {
        self.config = config
        self.homeDirectory = homeDirectory
        self.store = hostKeyStore
    }

    public var sourceID: String { config.sourceID }
    public var isRemote: Bool { true }
    public var supportsTransfer: Bool { true }

    /// 上一次 copyFile 实际走过的路径。未连接时返回 nil（首次复制前无路由信息）。
    /// TransferEngine 逐文件上报此值，让 UI 显示「服务器端复制 / 本机中转（原因）」。
    public var lastCopyRoute: CopyRoute? { _connection?.lastCopyRoute }

    // MARK: - 连接

    private func conn() throws -> SFTPConnection {
        if let c = _connection { return c }
        let c = try SFTPConnection(config: config, store: store)
        _connection = c
        return c
    }

    /// 主动断开（关闭后下次操作会重连）。
    public func closeConnection() {
        _connection?.close()
        _connection = nil
    }

    /// 连接并解析远端 home 目录（SFTP REALPATH "."），失败抛 TCError。
    /// 连接成功后连接保持复用；供连接窗取起始路径。
    public func resolveHome() throws -> String {
        try mapped("") { try conn().performSync { try await $0.realPath(".") } }.filename
    }

    // MARK: - 错误映射（所有出口统一过这里）

    /// 统一映射出口。`path` = 出错操作的目标远端绝对路径（有主体则 .notFound/.permissionDenied 携真路径，
    /// 无主体的操作（连接/认证/home）显式传 ""）。**无默认值=新增 FileSource 方法漏传 path 必编译失败**（终审 M-1）。
    private func mapped<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch {
            dropConnectionIfDead(error)
            throw (error as? SSHClientError)?.sftpMappedTCError(path: path) ?? asTCError(error)
        }
    }

    /// 死连接判丢（镜像 FTP `keepsConnection`：**服务器答过话 → 连接留着**）。
    /// 判据 = 错误是否携带 SFTP 协议层应答：
    /// - `operationFailed` 且 diagnostics.sftpStatus 非 nil（noSuchFile/permissionDenied/
    ///   eof 等）= 服务器对这条请求给了语义否定 → 传输仍活，留着（否则每次撞不存在
    ///   路径都重付一次 TCP/SSH 握手，且刷新风暴 = 重连风暴）；
    /// - `connectionScopeEnded`（对端拆流/休眠后 TCP 死）/ 无 sftpStatus 的
    ///   `operationFailed`（传输层诊断）/ 一切非 SSHClientError → 判丢，
    ///   `_connection = nil` 下次 conn() 懒重建。
    /// 认证类错误（authenticationRejected）不丢：连接活着，只是凭据不对。
    private func dropConnectionIfDead(_ error: Error) {
        guard let c = _connection else { return }
        var dead: Bool
        switch error {
        case let e as SSHClientError:
            switch e {
            case .operationFailed(let f):
                dead = f.diagnostics.sftpStatus == nil
            case .connectionScopeEnded:
                dead = true
            default:
                // authenticationRejected / passwordChangeRequired / connectionFailed：
                // 前者连接活（凭据问题），后两者发生在 conn() 新建路径（缓存里本就没有连接）
                dead = false
            }
        default:
            dead = true
        }
        guard dead else { return }
        // 仅当还是同一个连接（句柄闭包错误也走到这里时可能已被前次判丢替换）
        if _connection === c {
            c.close()
            _connection = nil
        }
    }

    private func call<T>(_ path: String,
                         _ op: @escaping @Sendable (SFTPClient) async throws -> T) throws -> T {
        try mapped(path) { try conn().performSync(op) }
    }

    // MARK: - 路径映射

    /// TCPath(sftp://host:port/p) → 远端绝对路径；无路径（根）→ homeDirectory。
    private func remotePath(_ p: TCPath) -> String {
        let path = p.pathString
        if path.isEmpty { return homeDirectory }
        return path
    }

    private func makePath(dir: String, name: String) -> TCPath {
        let joined = dir.hasSuffix("/") ? dir + name : dir + "/" + name
        return Self.tcPath(host: config.host, port: Int(config.port), remotePath: joined)
    }

    /// 远端绝对路径 → TCPath。逐段 percent-encode 后经 URLComponents 构造——
    /// 裸拼 "sftp://…\(path)" 在名字含空格时 URL(string:)==nil 会回落本地分支（静默错路由）。
    /// TCPath.pathString / url.path 取值时自动解码，往返与远端真实路径一致。
    static func tcPath(host: String, port: Int, remotePath: String) -> TCPath {
        var c = URLComponents()
        c.scheme = "sftp"
        c.host = host
        c.port = port
        let encoded = remotePath.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! }
            .joined(separator: "/")
        c.percentEncodedPath = encoded.isEmpty ? "/" : "/" + encoded
        return TCPath(url: c.url!)
    }

    // MARK: - 浏览 / 元信息

    public func listDirectory(_ path: TCPath) throws -> [FileItem] {
        let dir = remotePath(path)
        return try call(dir) { sftp in
            let entries = try await sftp.listDirectory(dir)
            return entries
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { entry in
                    let joined = dir.hasSuffix("/") ? dir + entry.filename : dir + "/" + entry.filename
                    return Self.map(attrs: entry.attributes, name: entry.filename,
                                    fullPath: joined, config: self.config)
                }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
        }
    }

    public func isDirectory(_ path: TCPath) -> Bool {
        (try? stat(path))?.isDirectory ?? false
    }

    public func stat(_ path: TCPath) throws -> FileItem? {
        let p = remotePath(path)
        let attrs: SSHSFTPFileAttributes
        do {
            attrs = try call(p) { try await $0.stat(p) }
        } catch let e as TCError {
            if case .notFound = e { return nil }
            throw e
        }
        let name = path.fileName
        return Self.map(attrs: attrs, name: name.isEmpty ? "/" : name,
                        fullPath: p, config: config)
    }

    // MARK: - 元操作

    public func copyItem(from src: TCPath, to dst: TCPath) throws {
        let from = remotePath(src), to = remotePath(dst)
        try mapped(to) { try conn().copyFile(from: from, to: to) }
    }

    public func moveItem(from: TCPath, to: TCPath) throws {
        try renameItem(at: from, to: to)
    }

    public func renameItem(at: TCPath, to: TCPath) throws {
        let from = remotePath(at), to = remotePath(to)
        try call(to) { try await $0.rename(from, to: to) }
    }

    public func makeDirectory(at: TCPath) throws {
        let p = remotePath(at)
        try call(p) { try await $0.makeDirectory(p) }
    }

    /// 递归删除：removeDirectory 只删空目录 → 先删子项再删自身。
    public func removeItem(at: TCPath) throws {
        let p = remotePath(at)
        let attrs = try call(p) { try await $0.lstat(p) }
        let isDir = (attrs.permissions ?? 0) & 0o170000 == 0o040000
        if isDir {
            let children = try call(p) { try await $0.listDirectory(p) }
                .filter { $0.filename != "." && $0.filename != ".." }
            for child in children {
                try removeItem(at: makePath(dir: p, name: child.filename))
            }
            try call(p) { try await $0.removeDirectory(p) }
        } else {
            try call(p) { try await $0.removeFile(p) }
        }
    }

    // MARK: - 流式

    public func openReader(_ path: TCPath) throws -> ReadHandle {
        let p = remotePath(path)
        return try mapped(p) { try conn().openReader(p) }
    }

    public func streamWrite(_ path: TCPath, totalBytes: Int64?,
                            write: @escaping () throws -> Data) throws {
        // 跨源泵送（他源 openReader → 本方法）不会重入本连接的队列。
        let p = remotePath(path)
        try mapped(p) { try conn().streamWrite(p, totalBytes: totalBytes, write: write) }
    }

    // MARK: - 属性映射

    /// 从 SFTP 属性 + 完整远端路径构造 FileItem。
    static func map(attrs: SSHSFTPFileAttributes, name: String,
                    fullPath: String, config: SFTPConnectionConfig) -> FileItem {
        let isDir = (attrs.permissions ?? 0) & 0o170000 == 0o040000
        let itemPath = Self.tcPath(host: config.host, port: Int(config.port), remotePath: fullPath)
        let execBit = (attrs.permissions ?? 0) & 0o0111 != 0
        return FileItem(
            id: fullPath,
            path: itemPath,
            name: name,
            isDirectory: isDir,
            size: isDir ? 0 : Int64(attrs.size ?? 0),
            modificationDate: Date(timeIntervalSince1970: TimeInterval(attrs.modificationTime ?? 0)),
            isHidden: name.hasPrefix("."),
            isReadOnly: false,
            isExecutable: isDir || execBit
        )
    }

    // MARK: - SFTP 状态码判别

    static func sftpStatus(_ error: Error) -> SSHSFTPStatusCode? {
        guard case SSHClientError.operationFailed(let f) = error else { return nil }
        return f.diagnostics.sftpStatus?.statusCode
    }

    static func isSFTPNotFound(_ error: Error) -> Bool {
        sftpStatus(error) == .noSuchFile
    }

    static func isSFTPPermissionDenied(_ error: Error) -> Bool {
        sftpStatus(error) == .permissionDenied
    }
}

extension Error {
    /// SSHClientError → TCError（不改动 TCCore 的全局 asTCError）。
    /// `path` = 出错操作的目标远端绝对路径（remotePath 恒非空，故 .notFound/.permissionDenied 携真主体；
    /// 无主体上下文的错误——认证/连接/泛化透传——不吃 path）。
    func sftpMappedTCError(path: String = "") -> TCError {
        switch self {
        case let e as SSHClientError:
            if case .authenticationRejected(let method, _, _, _) = e {
                return .authRejected(method: method)
            }
            if case .connectionFailed = e {
                return .sftpConnectFailed
            }
            if SFTPSource.isSFTPNotFound(e) {
                return .notFound(path)
            }
            if SFTPSource.isSFTPPermissionDenied(e) {
                return .permissionDenied(path)
            }
            if case .operationFailed(let f) = e {
                return .unknown(f.message)
            }
            return .unknown(String(describing: e))
        default:
            return asTCError(self)
        }
    }
}
