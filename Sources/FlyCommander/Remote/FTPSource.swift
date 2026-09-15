import Foundation
import TCCore

/// FTP 数据源：实现完整 FileSource 面（浏览 + 元操作 + 流式读写）。
///
/// 逐方法对照 SFTPSource 的语义与错误映射写：
/// - 惰性建连（首次操作连接并复用），断开由 closeConnection 显式触发，
///   连接被判定不可复用时下次操作懒重连；
/// - 所有出口过 `mapped(path:)` 统一映射成 TCError，**path 无默认值**
///   （新增 FileSource 方法漏传 path 必编译失败——照 SFTPSource 终审 M-1）；
/// - sourceID = "ftp://host[:port]"，非默认端口才带 :port。
///
/// 本期错误文案允许英文（集成者统一中文化）；TCError **形态**与 SFTPSource 对齐。
public final class FTPSource: FileSource {
    public let config: FTPClient.Config
    public internal(set) var homeDirectory: String
    private let conn: FTPConnection

    init(config: FTPClient.Config, homeDirectory: String = "/") {
        self.config = config
        self.homeDirectory = homeDirectory
        self.conn = FTPConnection(config: config)
    }

    /// 连接窗用的构造：给定配置，尚未登录（首次操作时才建连+登录）。
    public convenience init(config: FTPClient.Config) {
        self.init(config: config, homeDirectory: "/")
    }

    public var sourceID: String { config.sourceID }
    public var isRemote: Bool { true }
    public var supportsTransfer: Bool { true }

    // MARK: - 连接

    /// 主动断开（关闭后下次操作会重连）。
    public func closeConnection() {
        conn.close()
    }

    /// 登录并解析远端 home（PWD），失败抛 TCError。供连接窗取起始路径。
    public func resolveHome() throws -> String {
        try mapped("") { try conn.performSync { try await $0.pwd() } }
    }

    // MARK: - 错误映射（所有出口统一过这里）

    /// 统一映射出口。`path` = 出错操作的目标远端绝对路径（有主体则 .notFound/.permissionDenied
    /// 携真路径；无主体的操作——连接/认证/home——显式传 ""）。
    private func mapped<T>(_ path: String, _ body: () throws -> T) throws -> T {
        do { return try body() }
        catch { throw error.ftpmappedTCError(path: path) }
    }

    private func call<T>(_ path: String,
                         _ op: @escaping @Sendable (FTPClient) async throws -> T) throws -> T {
        try mapped(path) { try conn.performSync(op) }
    }

    // MARK: - 路径映射

    /// TCPath(ftp://host:port/p) → 远端绝对路径；无路径（根）→ homeDirectory。
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
    /// 裸拼 "ftp://…\(path)" 在名字含空格时 URL(string:)==nil 会回落本地分支（静默错路由）。
    /// 与 SFTPSource.tcPath 同构（仅 scheme 不同）。
    static func tcPath(host: String, port: Int, remotePath: String) -> TCPath {
        var c = URLComponents()
        c.scheme = "ftp"
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
        return try call(dir) { client in
            let entries = try await client.list(dir)
            return entries
                .filter { $0.name != "." && $0.name != ".." }
                .map { entry in Self.map(entry: entry, dir: dir, config: self.config) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
        }
    }

    public func isDirectory(_ path: TCPath) -> Bool {
        (try? stat(path))?.isDirectory ?? false
    }

    /// 存在 → FileItem；不存在 → nil；其它错误 → throw。
    ///
    /// 判别链（按服务器能力降级，不依赖 FEAT 声明）：
    /// 1. MLST（权威事实，一条命令）。回 500/502 = 服务器无此命令 → 永久降级到 2/3 步；
    /// 2. SIZE 命中 → 确定是文件（+ MDTM 取时间）；
    /// 3. SIZE 失败时**不能**断定不存在——550 同时意味着「是目录」。
    ///    故 LIST 父目录按名字命中来消歧（唯一可靠判据）。
    public func stat(_ path: TCPath) throws -> FileItem? {
        let p = remotePath(path)
        let name = path.fileName
        let displayName = name.isEmpty ? "/" : name
        return try mapped(p) {
            // 1) MLST
            if conn.mlsdUsable {
                do {
                    if let entry = try conn.performSync({ try await $0.mlst(p) }) {
                        return Self.map(entry: entry, fullPath: p, name: displayName, config: config)
                    }
                    return nil        // MLST 回 550 = 不存在
                } catch let e as FTPClientError where e.replyCode == 500 || e.replyCode == 502 {
                    conn.mlsdUsable = false      // 无此命令：本连接生命周期内不再试
                }
            }
            // 2) SIZE = 确定是文件
            if let size = try? conn.performSync({ try await $0.size(p) }) {
                let date = (try? conn.performSync({ try await $0.modificationTime(p) })).flatMap { $0 }
                         ?? .distantPast
                return Self.map(entry: FTPListEntry(name: displayName, isDirectory: false, size: size,
                                                    modificationDate: date, isExecutable: false),
                                fullPath: p, name: displayName, config: config)
            }
            // 3) 目录 or 不存在？LIST 父目录判定
            guard let parent = Self.parentOf(p) else {
                return Self.map(entry: FTPListEntry(name: "/", isDirectory: true, size: 0,
                                                    modificationDate: .distantPast, isExecutable: true),
                                fullPath: p, name: "/", config: config)   // 根恒为目录
            }
            let siblings = try conn.performSync({ try await $0.list(parent) })
            guard let hit = siblings.first(where: { $0.name == name }) else { return nil }
            return Self.map(entry: hit, dir: parent, config: config)
        }
    }

    /// `/a/b/c` → `/a/b`；根/裸名 → nil。
    static func parentOf(_ path: String) -> String? {
        guard !path.isEmpty, path != "/" else { return nil }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return nil }
        let parent = String(trimmed[trimmed.startIndex..<slash])
        return parent.isEmpty ? "/" : parent
    }

    // MARK: - 元操作

    /// 同源复制：FTP **没有服务器端复制命令**（无 SFTP 的 exec cp 可用），
    /// 故与 SFTPSource 的回退 pump 同构——本连接上 RETR → STOR 回环（字节过本机）。
    ///
    /// **必须先把源读尽、RETR 的 226 排干干净后，才能开始 STOR**：FTP 的一条控制连接
    /// 同一时刻只允许一个传输（不像 SFTP 多路复用）。若边 RETR 边 STOR，STOR 的 PASV
    /// 会把 RETR 尾部的 226 当自己的应答读走 → 整条会话错位。FTP 无第二条并行数据通道
    /// 可用（单连接模型），故这里读尽再写。
    /// 不变量照旧：调用前 OperationEngine.resolveConflict 已对「覆盖」先 removeItem(dst)。
    ///
    /// **目录**：FileSource 合同要求 copyItem 能复制目录（LocalFileSource=FileManager、
    /// SFTPSource=服务器端 cp -a 皆可递归），且 OperationEngine 同源分支不拦目录
    /// （checkCrossSourceDirectory 只管跨源）。FTP 无服务器端复制 → MKD + 逐子项递归，
    /// 与 SFTPSource 的回退 pump 语义一致（RETR 目录只会 550，落 .notFound 是误导）。
    public func copyItem(from src: TCPath, to dst: TCPath) throws {
        let from = remotePath(src), to = remotePath(dst)
        if let item = try stat(src), item.isDirectory {
            try makeDirectory(at: dst)
            for child in try listDirectory(src) {
                try copyItem(from: makePath(dir: from, name: child.name),
                             to: makePath(dir: to, name: child.name))
            }
            return
        }
        try mapped(to) {
            // 1) 读尽源（RETR 完成、226 已在句柄收尾时排干）
            let reader = try conn.openReader(from)
            var payload = Data()
            while let chunk = try reader(64 * 1024) { payload.append(chunk) }
            // 2) 再写目标（此时控制连接干净，STOR 独占）
            var sent = false
            try conn.streamWrite(to, totalBytes: Int64(payload.count)) {
                if sent { return Data() }
                sent = true
                return payload
            }
        }
    }

    /// 同源移动 = RNFR/RNTO（服务器端改名，字节不动）。
    public func moveItem(from: TCPath, to: TCPath) throws {
        try renameItem(at: from, to: to)
    }

    public func renameItem(at: TCPath, to: TCPath) throws {
        let from = remotePath(at), to = remotePath(to)
        try call(to) { try await $0.rename(from: from, to: to) }
    }

    public func makeDirectory(at: TCPath) throws {
        let p = remotePath(at)
        try call(p) { try await $0.makeDirectory(p) }
    }

    /// 递归删除（FileSource 合同：非空目录也删，不可恢复）。
    /// RMD 只删空目录 → 先删子项再删自身（照 SFTPSource）。
    public func removeItem(at: TCPath) throws {
        let p = remotePath(at)
        guard let item = try stat(at) else { throw TCError.notFound(p) }
        if item.isDirectory {
            let children = try listDirectory(at)
            for child in children {
                try removeItem(at: makePath(dir: p, name: child.name))
            }
            try call(p) { try await $0.removeDirectory(p) }
        } else {
            try call(p) { try await $0.deleteFile(p) }
        }
    }

    // MARK: - 流式

    public func openReader(_ path: TCPath) throws -> ReadHandle {
        let p = remotePath(path)
        return try mapped(p) {
            let handle = try conn.openReader(p)
            // 句柄**调用期**抛出的错误（截断/超时/连接关闭）也必须过映射：
            // 泵送方（OperationEngine.stream、copyItem）直接吃 reader(…) 的错误，
            // 不过这里就会把 FTPTransferTruncatedError/FTPClientError 原样漏给 UI。
            return { want in
                do { return try handle(want) }
                catch { throw error.ftpmappedTCError(path: p) }
            }
        }
    }

    public func streamWrite(_ path: TCPath, totalBytes: Int64?,
                            write: @escaping () throws -> Data) throws {
        // 跨源泵送（他源 openReader → 本方法）不会重入本连接的锁。
        let p = remotePath(path)
        try mapped(p) { try conn.streamWrite(p, totalBytes: totalBytes, write: write) }
    }

    // MARK: - 属性映射

    /// LIST/MLSD 条目 + 所在目录 → FileItem（id/path 用 ftp:// URL）。
    static func map(entry: FTPListEntry, dir: String, config: FTPClient.Config) -> FileItem {
        let joined = dir.hasSuffix("/") ? dir + entry.name : dir + "/" + entry.name
        return map(entry: entry, fullPath: joined, name: entry.name, config: config)
    }

    /// 完整远端路径版（MLST / 单条探测用：name 由调用方给，避免依赖条目自带名字）。
    static func map(entry: FTPListEntry, fullPath: String, name: String,
                    config: FTPClient.Config) -> FileItem {
        let itemPath = tcPath(host: config.host, port: Int(config.port), remotePath: fullPath)
        return FileItem(
            id: fullPath,
            path: itemPath,
            name: name,
            isDirectory: entry.isDirectory,
            size: entry.isDirectory ? 0 : entry.size,
            modificationDate: entry.modificationDate,
            isHidden: entry.name.hasPrefix("."),
            isReadOnly: false,
            isExecutable: entry.isDirectory ? true : entry.isExecutable
        )
    }

    /// SIZE 廉价判别：回 550 视为目录（合同指定的单条探测路径）。
    /// stat 的目录/不存在消歧走 LIST 父目录（550 歧义不可单条消解）；
    /// isDirectory 只需布尔 → 用这条省掉一次 LIST。
    func sizeImpliesDirectory(_ path: TCPath) -> Bool {
        let p = remotePath(path)
        do {
            _ = try conn.performSync { try await $0.size(p) }
            return false          // SIZE 成功 → 文件
        } catch let e as FTPClientError {
            return e.isNotFoundReply      // 550 → 目录
        } catch {
            return false
        }
    }
}

// MARK: - 错误映射

extension Error {
    /// FTPClientError → TCError（不改动 TCCore 的全局 asTCError）。
    /// `path` = 出错操作的目标远端绝对路径；无主体上下文（连接/认证）不吃 path。
    /// 有语义的失败一律落**专用 TCError case**（文案走 L10n 表，UI 出中文），
    /// `.unknown` 只留给 locale 透传（TCError.unknown 的既定收窄）。
    func ftpmappedTCError(path: String = "") -> TCError {
        // 传输截断（226 确认「服务器发完」但字节数 < SIZE 预期）先判：它不是
        // FTPClientError，是数据完整性失败，落专用 case（绝不与连接失败/550 混淆——
        // 用户看到「数据连接失败」会去查网络，而正确处置是重传该文件）。
        if let t = self as? FTPTransferTruncatedError {
            return .ftpTransferTruncated(got: t.received, expected: t.expected)
        }
        switch self {
        case let e as FTPClientError:
            switch e {
            case .authRejected(let method):
                return .authRejected(method: method)
            case .connectFailed(let detail):
                return .ftpConnectFailed(detail)
            case .unexpectedReply(let code, let message):
                switch code {
                case 550: return .notFound(path)          // 主体不存在（isDirectory 判据同源）
                case 530: return .permissionDenied(path)  // 需要登录/无权限
                case 552: return .noSpace
                case 450, 452: return .busy(path)
                // 无专用语义的服务器应答：码号+自由文本，locale 透传。
                default:  return .unknown("FTP \(code): \(message)")
                }
            case .dataConnectFailed(let detail):
                return .ftpDataConnectFailed(detail)
            case .timeout(let seconds):
                return .ftpTimeout(seconds)
            case .closed:
                return .ftpConnectionClosed
            case .unsupported(let what):
                return .unknown("FTP server unsupported: \(what)")
            case .malformedReply(let detail):
                return .unknown("Malformed FTP reply: \(detail)")
            case .invalidPath:
                // 命令未发出（路径含 CR/LF，协议无法转义）——控制流完好。
                return .invalidPath(path)
            }
        default:
            return asTCError(self)
        }
    }
}
