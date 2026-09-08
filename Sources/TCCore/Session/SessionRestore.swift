import Foundation

/// 会话恢复的纯决策：候选目录串 → 本次启动实际可用的目录串。
/// 纯函数（零 IO）：目录可用性由调用方注入 `probe`（app 层探真实磁盘，单测注入闭包）。
public enum SessionRestore {
    /// 严格按序：
    /// 1. 先 trim，后续**全程用 trimmed 值**（绝不用原串构造路径——否则 " /x " 探不到）；
    /// 2. nil / 空串 → fallback；
    /// 3. 不是绝对路径（"/" 开头）也不是家目录形式（"~" / "~/" 开头）→ fallback。
    ///    相对路径、手改垃圾、以及 "~foo" 这类非法家目录写法都在此拦下——"~foo" 若放行会被
    ///    TCPath 当相对路径解析成 cwd 下的绝对路径，probe 失败后一路"上溯"到根，首启落根目录；
    /// 4. 远端串（sftp:// / smb://）→ fallback（本功能只记忆本地目录，且不拿远端串探本地盘）；
    /// 5. 从候选逐级上溯，首个 probe 为真的祖先即结果；到根仍不可用 → fallback。
    public static func resolve(candidate: String?, fallback: String, probe: (String) -> Bool) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed = trimmed, !trimmed.isEmpty else { return fallback }
        guard trimmed.hasPrefix("/") || trimmed == "~" || trimmed.hasPrefix("~/") else { return fallback }
        var p = TCPath(trimmed)                       // "~/x" 在此展开为绝对路径
        // 防御性：若未来放宽上面的前缀检查，此处仍拦住远端串（现在不可达）。
        guard !p.isRemote else { return fallback }
        while true {
            if probe(p.pathString) { return p.pathString }
            guard let parent = p.parent else { return fallback }   // TCPath.parent 在根返回 nil
            p = parent
        }
    }
}
