import Foundation

public struct LocalFileSource: FileSource {
    public init() {}

    private let fm = FileManager.default
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .isHiddenKey, .isWritableKey, .isExecutableKey,
    ]

    public var isRemote: Bool { false }
    public var supportsTransfer: Bool { true }
    public var sourceID: String { "local" }

    // MARK: - 浏览 / 元信息

    public func isDirectory(_ path: TCPath) -> Bool {
        (try? stat(path))?.isDirectory ?? false
    }

    public func stat(_ path: TCPath) throws -> FileItem? {
        let url = path.url
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return FileItem.fromResourceValues(
            url: url, isDirFallback: isDir.boolValue, keys: keys)
    }

    public func listDirectory(_ path: TCPath) throws -> [FileItem] {
        let urls: [URL]
        do {
            urls = try fm.contentsOfDirectory(at: path.url,
                                              includingPropertiesForKeys: Array(keys),
                                              options: [])
        } catch {
            throw asTCError(error)
        }
        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            let rv = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
            let isDir = rv.isDirectory ?? false
            let size: Int64 = isDir ? 0 : Int64(rv.fileSize ?? 0)
            let date = rv.contentModificationDate ?? .distantPast
            items.append(FileItem(
                id: url.path,
                path: TCPath(url: url),
                name: url.lastPathComponent,
                isDirectory: isDir,
                size: size,
                modificationDate: date,
                isHidden: rv.isHidden ?? false,
                isReadOnly: !(rv.isWritable ?? true),
                isExecutable: rv.isExecutable ?? false
            ))
        }
        return items.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: - 元操作

    public func copyItem(from: TCPath, to: TCPath) throws {
        do { try fm.copyItem(at: from.url, to: to.url) }     // 缩减 SDK：旧签名 at:to:
        catch { throw asTCError(error) }
    }

    public func moveItem(from: TCPath, to: TCPath) throws {
        do { try fm.moveItem(at: from.url, to: to.url) }    // 跨卷自动 copy+remove
        catch { throw asTCError(error) }
    }

    public func renameItem(at: TCPath, to: TCPath) throws {
        do { try fm.moveItem(at: at.url, to: to.url) }
        catch { throw asTCError(error) }
    }

    public func makeDirectory(at: TCPath) throws {
        do { try fm.createDirectory(at: at.url, withIntermediateDirectories: false) }
        catch { throw asTCError(error) }
    }

    public func removeItem(at: TCPath) throws {
        do { try fm.removeItem(at: at.url) }                 // 非空目录递归
        catch { throw asTCError(error) }
    }

    // MARK: - 流式

    public func openReader(_ path: TCPath) throws -> ReadHandle {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: path.url)
            try handle.seek(toOffset: 0)   // 不可读文件在此暴露
        } catch {
            throw asTCError(error)
        }
        let chunkCapacity = 64 * 1024
        return { want in
            let target = want > 0 ? min(want, chunkCapacity) : chunkCapacity
            var out = Data()
            while out.count < target {
                let piece: Data
                do { piece = try handle.read(upToCount: target - out.count) ?? Data() }
                catch {
                    try? handle.close()
                    throw asTCError(error)
                }
                guard !piece.isEmpty else { break }   // EOF
                out.append(piece)
            }
            guard !out.isEmpty else {
                try? handle.close()                   // 读完即关
                return nil
            }
            return out
        }
    }

    public func streamWrite(_ path: TCPath, totalBytes: Int64?,
                            write: () throws -> Data) throws {
        let url = path.url
        do {
            // 缩减 SDK：FileHandle 无 create 选项 → 先删旧文件再显式建空文件
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            fm.createFile(atPath: url.path, contents: Data())
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            while true {
                let chunk = try write()
                if chunk.isEmpty { break }
                handle.write(chunk)   // 缩减 SDK：write 不抛错
            }
        } catch {
            try? fm.removeItem(at: url)        // 失败清理半截文件
            throw asTCError(error)
        }
    }
}

extension FileItem {
    /// stat 路径复用（目录标志以 fileExists 探测为准，资源读取兜底）。
    static func fromResourceValues(url: URL, isDirFallback: Bool,
                                   keys: Set<URLResourceKey>) -> FileItem {
        let rv = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
        let isDir = rv.isDirectory ?? isDirFallback
        return FileItem(
            id: url.path,
            path: TCPath(url: url),
            name: url.lastPathComponent,
            isDirectory: isDir,
            size: isDir ? 0 : Int64(rv.fileSize ?? 0),
            modificationDate: rv.contentModificationDate ?? .distantPast,
            isHidden: rv.isHidden ?? false,
            isReadOnly: !(rv.isWritable ?? true),
            isExecutable: rv.isExecutable ?? false
        )
    }
}
