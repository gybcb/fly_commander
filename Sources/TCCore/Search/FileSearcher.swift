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
    private let fm = FileManager.default
    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]

    public init() {}

    @discardableResult
    public func search(root: TCPath,
                       pattern: NamePattern,
                       limit: Int = 1000,
                       progress: ((Int) -> Void)? = nil,
                       isCancelled: () -> Bool = { false }) -> [SearchHit] {
        var hits: [SearchHit] = []
        var visited = 0
        guard let enumerator = fm.enumerator(
            at: root.url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }
        for case let url as URL in enumerator {
            if isCancelled() { break }
            visited += 1
            if visited % 10 == 0 { progress?(visited) }
            let values = (try? url.resourceValues(forKeys: keys)) ?? URLResourceValues()
            let isDir = values.isDirectory ?? false
            let name = url.lastPathComponent
            if pattern.matches(name) {
                hits.append(SearchHit(
                    path: TCPath(url: url),
                    name: name,
                    isDirectory: isDir,
                    size: isDir ? 0 : Int64(values.fileSize ?? 0)))
                if hits.count >= limit { break }
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
