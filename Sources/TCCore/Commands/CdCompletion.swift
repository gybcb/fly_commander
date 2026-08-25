import Foundation

/// cd 命令自动补全（纯函数，无 IO）。数据源是活动窗格当前目录的条目（app 层传入
/// [FileItem]）；本层只做匹配与补全解析，供下拉建议与 Tab 补全共用。
public enum CdCompletion {
    /// 前缀匹配（忽略大小写）：目录优先、其次按名称（localizedStandardCompare）排序，
    /// 最多取 `cap` 条。prefix 为空时返回整个目录（目录优先）的前 cap 条。
    public static func matches(prefix: String, items: [FileItem], cap: Int = 8) -> [FileItem] {
        let p = prefix.lowercased()
        let hit = items.filter { $0.name.lowercased().hasPrefix(p) }
        let sorted = hit.sorted { l, r in
            if l.isDirectory != r.isDirectory { return l.isDirectory && !r.isDirectory }
            return l.name.localizedStandardCompare(r.name) == .orderedAscending
        }
        return Array(sorted.prefix(cap))
    }

    /// 最长公共前缀（比较忽略大小写，但保留**首项**的大小写形态）。
    /// 空输入/无公共前缀 → 空串。文件补全应不区分大小写（"Down"/"downFile" 共享 "down"）。
    public static func longestCommonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for s in strings.dropFirst() {
            let sLower = s.lowercased()
            while !sLower.hasPrefix(prefix.lowercased()) {
                if prefix.isEmpty { return "" }
                prefix.removeLast()
            }
        }
        return prefix
    }

    /// Tab 补全结果：`text` 是要写回命令栏的 cd 参数（目录/文件全名或公共前缀），
    /// `resolved` 表示是否补全到唯一完整名（true 时停止 Tab 循环）。
    public struct TabResult {
        public let text: String
        public let resolved: Bool
    }

    /// Tab 补全解析：
    /// - 无命中 → nil（命令栏不做改动）；
    /// - 唯一命中 → 该全名（resolved）；
    /// - 多个且 `cycleIndex == 0`（首次 Tab）→ 最长公共前缀（不 resolved，供再次 Tab 循环）；
    /// - 多个且 `cycleIndex > 0`（重复 Tab）→ 按 (cycleIndex-1) 环绕取某一项全名（resolved）。
    public static func tabComplete(matches: [FileItem], cycleIndex: Int) -> TabResult? {
        guard let first = matches.first else { return nil }
        if matches.count == 1 { return TabResult(text: first.name, resolved: true) }
        if cycleIndex <= 0 {
            return TabResult(text: longestCommonPrefix(matches.map { $0.name }), resolved: false)
        }
        let idx = (cycleIndex - 1) % matches.count
        return TabResult(text: matches[idx].name, resolved: true)
    }
}
