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

    /// smb://server/share/rel → 本地挂载路径的 TCPath（LocalFileSource 各方法收 TCPath）。
    /// share 根（rel 空）→ 挂载点本身；否则挂载点 + rel。
    static func toLocal(_ smb: TCPath, mountPoint: URL, share: String) -> TCPath {
        let s = smb.pathString                       // "/share/rel"
        let sharePrefix = "/" + share
        let rel: String
        if s.hasPrefix(sharePrefix) { rel = String(s.dropFirst(sharePrefix.count)) }
        else { rel = s }                             // 兜底：异常输入原样
        return rel.isEmpty ? TCPath(url: mountPoint)
                           : TCPath(url: mountPoint.appendingPathComponent(rel))
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
        try local.listDirectory(Self.toLocal(path, mountPoint: mountPoint, share: config.share))
            .map { Self.remap($0, to: path.joining($0.name)) }   // 每项 id = 父 smb 目录 + 名
    }
    public func isDirectory(_ path: TCPath) -> Bool {
        local.isDirectory(Self.toLocal(path, mountPoint: mountPoint, share: config.share))
    }
    public func stat(_ path: TCPath) throws -> FileItem? {
        try local.stat(Self.toLocal(path, mountPoint: mountPoint, share: config.share))
            .map { Self.remap($0, to: path) }   // stat 的目标即自身 smb 路径
    }
    public func copyItem(from: TCPath, to: TCPath) throws {
        try local.copyItem(from: Self.toLocal(from, mountPoint: mountPoint, share: config.share),
                           to: Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func moveItem(from: TCPath, to: TCPath) throws {
        try local.moveItem(from: Self.toLocal(from, mountPoint: mountPoint, share: config.share),
                           to: Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func renameItem(at: TCPath, to: TCPath) throws {
        try local.renameItem(at: Self.toLocal(at, mountPoint: mountPoint, share: config.share),
                             to: Self.toLocal(to, mountPoint: mountPoint, share: config.share))
    }
    public func makeDirectory(at: TCPath) throws {
        try local.makeDirectory(at: Self.toLocal(at, mountPoint: mountPoint, share: config.share))
    }
    public func removeItem(at: TCPath) throws {
        try local.removeItem(at: Self.toLocal(at, mountPoint: mountPoint, share: config.share))
    }
    public func openReader(_ path: TCPath) throws -> ReadHandle {
        try local.openReader(Self.toLocal(path, mountPoint: mountPoint, share: config.share))
    }
    public func streamWrite(_ path: TCPath, totalBytes: Int64?, write: @escaping () throws -> Data) throws {
        try local.streamWrite(Self.toLocal(path, mountPoint: mountPoint, share: config.share),
                              totalBytes: totalBytes, write: write)
    }

    /// 挂载式后端无连接可关；卸载由 SMBConnectionStore 经 SMBMountManager 负责。
    public func closeConnection() { /* no-op */ }
}
