import Foundation

/// 流式读句柄：按期望块大小拉取数据；返回 nil 表示读完（句柄随之关闭）。
public typealias ReadHandle = (Int) throws -> Data?

/// 完整文件系统面：浏览 + 元操作 + 流式读写。
/// 跨源传输 = `源.openReader` 泵入 `目标.streamWrite`（64KB 块），
/// 同源 copy/move 由各实现走最快路径（本地 fm / SFTP 服务端 rename）。
public protocol FileSource {
    /// 数据源唯一标识（同源判定）。同一底层文件系统同 id：
    /// 本地恒 "local"；SFTP 形如 "sftp://host:port"。
    var sourceID: String { get }
    /// 是否远端源（SFTP 等）。远端预览/编辑/搜索走降级提示。
    var isRemote: Bool { get }
    /// 是否可参与跨源流式传输（读+写全能力）。
    var supportsTransfer: Bool { get }

    func listDirectory(_ path: TCPath) throws -> [FileItem]
    func isDirectory(_ path: TCPath) -> Bool
    /// 存在 → 完整 FileItem；不存在 → nil；其它错误（权限等）→ throw。
    func stat(_ path: TCPath) throws -> FileItem?
    /// 同源内复制（目标已存在 → throw，冲突检查由引擎层先做）。
    func copyItem(from: TCPath, to: TCPath) throws
    /// 同源内移动（本地跨卷自动退化为 copy+remove）。
    func moveItem(from: TCPath, to: TCPath) throws
    /// 重命名（目标已存在 → throw）。
    func renameItem(at: TCPath, to: TCPath) throws
    /// 建目录（已存在 → throw；只建一级，不建中间目录）。
    func makeDirectory(at: TCPath) throws
    /// 删除（文件或非空目录，递归；不可恢复）。
    func removeItem(at: TCPath) throws
    /// 打开流式读。同一时刻一个路径只应有一个活动句柄。
    func openReader(_ path: TCPath) throws -> ReadHandle
    /// 流式写：反复调用 write 闭包拉取数据，闭包返回空 Data 即结束。
    /// 目标已存在则先截断重建。totalBytes 供引擎层算进度（实现可不使用）。
    func streamWrite(_ path: TCPath, totalBytes: Int64?, write: () throws -> Data) throws
}

public extension FileSource {
    var isRemote: Bool { false }
    var supportsTransfer: Bool { false }
}
