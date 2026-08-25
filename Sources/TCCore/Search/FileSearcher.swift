import Foundation

public struct SearchHit: Hashable {
    public let path: TCPath
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
}

public struct NamePattern {
    public let pattern: String
    public let sensitive: Bool

    public init(_ pattern: String, caseSensitive: Bool = true) {
        self.pattern = pattern
        self.sensitive = caseSensitive
    }

    public func matches(_ name: String) -> Bool {
        var regex = ""
        for scalar in pattern.unicodeScalars {
            switch scalar {
            case "*", "?":
                regex.append(scalar == "*" ? ".*" : ".")
            default:
                regex.append(NSRegularExpression.escapedPattern(for: String(scalar)))
            }
        }
        let options: NSRegularExpression.Options = sensitive ? [] : [.caseInsensitive]
        guard let re = try? NSRegularExpression(pattern: "^\(regex)$", options: options) else {
            return false
        }
        let range = NSRange(location: 0, length: name.utf16.count)
        return re.firstMatch(in: name, options: [], range: range) != nil
    }
}

public struct FileSearcher {
    public init() {}

    /// 通用过 `FileSource.listDirectory` 递归搜索（本地/远端同一套逻辑）。
    /// 默认 `LocalFileSource()`，既有本地调用零改动；远端传对应 source。
    @discardableResult
    public func search(root: TCPath,
                       pattern: NamePattern,
                       limit: Int = 1000,
                       source: FileSource = LocalFileSource(),
                       progress: ((Int) -> Void)? = nil,
                       isCancelled: () -> Bool = { false }) -> [SearchHit] {
        var hits: [SearchHit] = []
        var visited = 0
        // DFS 迭代（栈）。目录项的 path 是"可直接再 list 的源内绝对路径"，
        // 故 stack.append(item.path) 天然成立（本地 file URL / sftp URL 皆然）。
        var stack: [TCPath] = [root]
        while !stack.isEmpty {
            if isCancelled() || hits.count >= limit { break }
            let dir = stack.removeLast()
            guard let items = try? source.listDirectory(dir) else { continue }
            for item in items {
                visited += 1
                if visited % 10 == 0 { progress?(visited) }
                if item.isHidden { continue }            // 跳过隐藏（含不下潜进隐藏目录）
                if pattern.matches(item.name) {
                    hits.append(SearchHit(path: item.path, name: item.name,
                                          isDirectory: item.isDirectory, size: item.size))
                    if hits.count >= limit { break }
                }
                if item.isDirectory { stack.append(item.path) }
            }
        }
        hits.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            let pa = a.path.pathString
            let pb = b.path.pathString
            return pa.localizedStandardCompare(pb) == .orderedAscending
        }
        progress?(visited)
        return hits
    }
}
