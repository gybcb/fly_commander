import Foundation

public struct TCPath: Hashable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public init(_ string: String) {
        var s = string
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if s == "~" {
            s = home
        } else if s.hasPrefix("~/") {
            s = home + s.dropFirst(1)   // drop "~", keep "/..."
        }
        self.url = URL(fileURLWithPath: s).standardizedFileURL
    }

    public var pathString: String { url.path }
    public var fileName: String { url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
    public var isRoot: Bool { url.path == "/" }
    public var isHidden: Bool { url.lastPathComponent.hasPrefix(".") }
    public var parent: TCPath? { isRoot ? nil : TCPath(url: url.deletingLastPathComponent()) }

    @discardableResult
    public func joining(_ name: String) -> TCPath { TCPath(url: url.appendingPathComponent(name)) }

    public func displayString() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~" + url.path.dropFirst(home.count)
        }
        return url.path
    }
}
