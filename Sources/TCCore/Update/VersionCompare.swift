import Foundation

/// 版本字符串比较（纯内核，零 IO/零 AppKit，可单测）。
/// 发布链与 App 端共用同一套 semver 语义：判定「远端版本是否比本地新」。
public enum VersionCompare {

    /// 远端版本是否比本地版本新（用于决定是否提示升级）。
    /// 逐段（按 '.' 分割）数值比较；段数不等时缺失段按 0 补齐
    /// （`0.1` == `0.1.0`）；任一段非纯数字 → 该段按 0 处理（保守，不误报升级）。
    /// 两串规范化后相等 → false（同版本不提示）。
    public static func isUpdate(_ remote: String, newerThan local: String) -> Bool {
        compare(remote, local) == .orderedDescending
    }

    /// 三态比较（内部复用，亦暴露给测试精确断言语义）。
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let as_ = segments(a), bs = segments(b)
        let n = max(as_.count, bs.count)
        for i in 0..<n {
            let av = i < as_.count ? as_[i] : 0
            let bv = i < bs.count ? bs[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    /// 拆 '.' 逐段转 Int；非数字段回落 0（不抛错，保证 UI 永不因畸形串崩）。
    static func segments(_ v: String) -> [Int] {
        v.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }
}
