import Foundation
import TCCore

/// SMB 数据源：挂载式后端——share 已挂成本地 POSIX 目录，全部 IO 委托 `LocalFileSource`
/// （同步、零 async 桥接）。路径在 smb://（对外，满足 id==pathString）与本地挂载路径间转换。
public final class SMBSource: FileSource {
    public let config: SMBConnectionConfig
    public let mountPoint: URL
    private let local = LocalFileSource()

    public init(config: SMBConnectionConfig, mountPoint: URL) {
        self.config = config
        self.mountPoint = mountPoint
    }

    public var sourceID: String { config.sourceID }
    public var isRemote: Bool { true }
    public var supportsTransfer: Bool { true }
    /// share 根（smb://server/share），cd 回 home / connect 开标签用。
    public var homePath: TCPath { TCPath("smb://\(config.server)/\(config.share)") }

    // MARK: - 纯路径映射（可单测）

    /// 把 smb:// 路径映射到挂载点本地路径；结果必须落在挂载点内，否则抛错（防路径穿越）。
    /// 只做词法判定（standardizedFileURL 折叠 `..`），不做 symlink 解析——新建路径的末段尚不存在、
    /// 无法解析，且本工具面向用户自己的挂载共享（非多租户服务），与 Finder 跟随符号链接的行为一致。
    static func toLocal(_ smb: TCPath, mountPoint: URL, share: String) throws -> TCPath {
        let s = smb.pathString
        let root = "/" + share
        if s == root { return TCPath(url: mountPoint) }                 // 共享根
        guard s.hasPrefix(root + "/") else {                            // 段边界（末尾 /），排除 /downloadsother
            throw TCError.pathOutsideShare(s)
        }
        let rel = String(s.dropFirst((root + "/").count))
        let mapped = mountPoint.appendingPathComponent(rel)
        let c = mapped.standardizedFileURL.path
        let b = mountPoint.standardizedFileURL.path
        guard c == b || c.hasPrefix(b + "/") else {                     // 折叠 .. 后仍须落在挂载点内
            throw TCError.pathEscaped(s)
        }
        return TCPath(url: mapped)
    }

    /// 本地 FileItem → smb://：元信息透传，id/path 用传入的 smb 路径（id==pathString 由构造保证）。
    /// 不反剥本地挂载路径前缀——规避 contentsOfDirectory 的 /private 前缀坑。
    static func remap(_ local: FileItem, to smb: TCPath) -> FileItem {
        FileItem(id: smb.pathString, path: smb, name: local.name,
                 isDirectory: local.isDirectory, size: local.size,
                 modificationDate: local.modificationDate, isHidden: local.isHidden,
                 isReadOnly: local.isReadOnly, isExecutable: local.isExecutable)
    }

    // MARK: - FileSource 面（委托 local）

    public func listDirectory(_ path: TCPath) throws -> [FileItem] {
        try local.listDirectory(try Self.toLocal(path, mountPoint: mountPoint, share: config.share))
            .map { Self.remap($0, to: path.joining($0.name)) }   // 每项 id = 父 smb 目录 + 名
    }
    public func isDirectory(_ path: TCPath) -> Bool {
        // 唯一非 throws 面：越界/非法 smb 路径视为非目录（与 LocalFileSource 吞错返回 false 一致）。
        guard let lp = try? Self.toLocal(path, mountPoint: mountPoint, share: config.share) else { return false }
        return local.isDirectory(lp)
    }
    public func stat(_ path: TCPath) throws -> FileItem? {
        try local.stat(try Self.toLocal(path, mountPoint: mountPoint, share: config.share))
            .map { Self.remap($0, to: path) }   // stat 的目标即自身 smb 路径
    }
    public func copyItem(from: TCPath, to: TCPath) throws {
        try local.copyItem(from: try Self.toLocal(from, mountPoint: mountPoint, share: config.share),
                           to: try Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func moveItem(from: TCPath, to: TCPath) throws {
        try local.moveItem(from: try Self.toLocal(from, mountPoint: mountPoint, share: config.share),
                           to: try Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func renameItem(at: TCPath, to: TCPath) throws {
        try local.renameItem(at: try Self.toLocal(at, mountPoint: mountPoint, share: config.share),
                             to: try Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func makeDirectory(at: TCPath) throws {
        try local.makeDirectory(at: try Self.toLocal(at, mountPoint: mountPoint, share: config.share))
    }
    public func removeItem(at: TCPath) throws {
        try local.removeItem(at: try Self.toLocal(at, mountPoint: mountPoint, share: config.share))
    }
    public func openReader(_ path: TCPath) throws -> ReadHandle {
        try local.openReader(try Self.toLocal(path, mountPoint: mountPoint, share: config.share))
    }
    public func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {
        try local.streamWrite(try Self.toLocal(path, mountPoint: mountPoint, share: config.share),
                              totalBytes: totalBytes, write: write)
    }

    /// 挂载式后端无连接可关；卸载由 SMBConnectionStore 经 SMBMountManager 负责。
    public func closeConnection() { /* no-op */ }
}
