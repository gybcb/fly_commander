import Foundation

/// 会话恢复的纯决策：候选目录串 → 本次启动实际可用的目录串。
/// 纯函数（零 IO）：目录可用性由调用方注入 `probe`（app 层探真实磁盘，单测注入闭包）。
public enum SessionRestore {
    /// 候选串的**合法性判定 + 归一化**（trim 后的可用形式；非法 → nil）：
    /// 1. nil / 空串 / 纯空白 → nil；
    /// 2. 不是绝对路径（"/" 开头）也不是家目录形式（"~" / "~/" 开头）→ nil。
    ///    相对路径、手改垃圾、以及 "~foo" 这类非法家目录写法都在此拦下——"~foo" 若放行会被
    ///    TCPath 当相对路径解析成 cwd 下的绝对路径，probe 失败后一路"上溯"到根，首启落根目录；
    /// 3. 远端串（sftp:// / smb://）→ nil（本功能只记忆本地目录，且不拿远端串探本地盘）。
    ///    当前前缀守卫已先拦下这类串，此条是**纵深防御**（将来若放宽前缀规则仍能拦住）；
    ///    故它对应的断言不是独立可证伪的，属既有设计遗留。
    /// 归一化只 trim：调用方拿到的串可直接写回持久化（写者与 resolve 用同一把尺）。
    public static func normalizedCandidate(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else { return nil }
        guard !TCPath(trimmed).isRemote else { return nil }
        return trimmed
    }

    /// 严格按序：
    /// 1. 归一化失败（见 `normalizedCandidate`）→ fallback；
    /// 2. 从候选逐级上溯，首个 probe 为真的祖先即结果；到根仍不可用 → fallback。
    public static func resolve(candidate: String?, fallback: String, probe: (String) -> Bool) -> String {
        guard let trimmed = normalizedCandidate(candidate) else { return fallback }
        var p = TCPath(trimmed)                       // "~/x" 在此展开为绝对路径
        while true {
            if probe(p.pathString) { return p.pathString }
            guard let parent = p.parent else { return fallback }   // TCPath.parent 在根返回 nil
            p = parent
        }
    }
}
