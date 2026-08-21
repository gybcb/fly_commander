import Foundation

public struct LocalFileSource: FileSource {
    public init() {}

    private let fm = FileManager.default
    private let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .isHiddenKey, .isWritableKey, .isExecutableKey,
    ]

    public func isDirectory(_ path: TCPath) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: path.url.path, isDirectory: &isDir) && isDir.boolValue
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
}
