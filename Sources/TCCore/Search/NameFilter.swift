import Foundation

/// 窗格内筛选匹配器（决策 1）：默认**不区分大小写的子串**；输入含 `*`/`?` 时切换为
/// **通配符**（全串锚定，如 `*.pdf`、`report?.txt`）。构造时一次性预编译匹配器，
/// `matches` 按项调用为 O(1) 复用（2 万项/键击不可逐项重编正则）。
public struct NameFilter {
    private enum Kind {
        case empty                 // 空串：恒真
        case substring(String)     // 子串（不走正则，`.` 等元字符按字面）
        case wildcard(NamePattern) // 通配符（预编译正则，全串锚定）
    }

    /// 原始输入文本（**不 trim**：空白按字面匹配，只命中名字含空格的项——明确取舍）。
    public let text: String
    private let kind: Kind

    public var isEmpty: Bool { text.isEmpty }

    public init(_ text: String) {
        self.text = text
        if text.isEmpty {
            kind = .empty
        } else if text.contains("*") || text.contains("?") {
            kind = .wildcard(NamePattern(text, caseSensitive: false))
        } else {
            kind = .substring(text)
        }
    }

    public func matches(_ name: String) -> Bool {
        switch kind {
        case .empty:
            return true
        case .substring(let text):
            return name.range(of: text, options: [.caseInsensitive]) != nil
        case .wildcard(let pattern):
            return pattern.matches(name)
        }
    }
}
