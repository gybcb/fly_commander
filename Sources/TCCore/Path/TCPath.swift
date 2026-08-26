import Foundation

public struct TCPath: Hashable, Equatable {
    public let url: URL

    public init(url: URL) {
        if url.isFileURL {
            self.url = url.standardizedFileURL
        } else {
            // 非文件 URL（sftp://host:port/path）原样保留——
            // standardizedFileURL 会丢 scheme/host/port。
            self.url = url
        }
    }

    public init(_ string: String) {
        if string.hasPrefix("sftp://") || string.hasPrefix("smb://") {
            if let url = URL(string: string) {
                self.url = url
                return
            }
            // 远端 URL 解析失败（如服务器名含未编码空格——URL(string:) 对非法字符返回 nil）。
            // 回落本地路径分支，不崩：有意的降级——宁可当本地不存在的路径报"路径不存在"
            // （该值会被 LocalFileSource 按不存在的路径处理，错误可被上层捕获），也不 trap。
        }
        var s = string
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s == "~" {
            s = home
        } else if s.hasPrefix("~/") {
            s = home + s.dropFirst(1)   // drop "~", keep "/..."
        }
        self.url = URL(fileURLWithPath: s).standardizedFileURL
    }

    /// 是否远端路径（sftp 等非 file scheme）。远端家目录解析由具体 Source 负责。
    public var isRemote: Bool { !(url.isFileURL) }

    public var pathString: String { url.path }
    public var fileName: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
    /// sftp URL 无路径时 path 为空串，本地 file URL 为 "/"，两者皆根。
    public var isRoot: Bool { url.path.isEmpty || url.path == "/" }
    public var isHidden: Bool { url.lastPathComponent.hasPrefix(".") }
    public var parent: TCPath? { isRoot ? nil : TCPath(url: url.deletingLastPathComponent()) }

    @discardableResult
    public func joining(_ name: String) -> TCPath { TCPath(url: url.appendingPathComponent(name)) }

    public func displayString() -> String {
        if isRemote {
            var s = "\(url.scheme ?? "sftp")://\(url.host ?? "")"
            if let port = url.port { s += ":\(port)" }
            return s + url.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}
