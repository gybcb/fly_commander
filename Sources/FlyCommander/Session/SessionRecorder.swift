import Foundation
import TCCore

/// 会话记忆的小状态机（app 层，可单测）：把"窗格当前目录"换算成"该写回快照的值"。
///
/// 核心是 degraded（启动时上溯）的一次性语义：若启动候选目录不可用、被上溯到某祖先，
/// 而用户没离开该祖先，就继续写回**原始候选**——不能用上溯后的祖先覆盖记忆，
/// 否则用户修好那个目录（如重新挂载磁盘）后记忆已被污染。一旦用户离开该祖先
/// （current != resolved），degraded 立即失效，此后按普通路径记录。
final class SessionRecorder {
    struct SideStartup {
        /// 该侧最终启动的目录（可能由候选逐级上溯而来）。
        let resolved: String
        /// 该侧快照里的原始候选（无快照 / 该侧无记录 → nil）。
        let candidate: String?
    }

    private let startup: [PaneID: SideStartup]
    private var degraded: Set<PaneID>

    init(startups: [PaneID: SideStartup]) {
        self.startup = startups
        self.degraded = Set(startups.compactMap { side, s in
            s.candidate != nil && s.resolved != s.candidate ? side : nil
        })
    }

    /// 该侧此刻应写回快照的值（nil = 不写该侧，保留上次记忆）。
    func valueToRecord(side: PaneID, current: String?, isRemote: Bool) -> String? {
        // 远端串永不写入（决策 2）：下次启动该侧回落默认起始目录。
        guard !isRemote else { return nil }
        // 无 startup（首启/该侧无候选）→ 无历史可守护，照常记录当前。
        guard let s = startup[side] else { return current }
        guard degraded.contains(side) else { return current }
        guard current == s.resolved else {
            degraded.remove(side)          // 用户已离开上溯落点 → 一次性语义结束
            return current
        }
        return s.candidate ?? current
    }
}

/// 启动期两条开关的纯函数（供单测锁真值表）。
enum SessionPolicy {
    /// 显式指定了起始目录（--start-dir / FLY_START_DIR）或参数域关闭 → 不恢复。
    static func restoreEnabled(explicitStartPath: String?, argumentDisabled: Bool) -> Bool {
        explicitStartPath == nil && !argumentDisabled
    }

    /// 注入快照（UI 测试）时只读不写：否则测试里的一举一动都会污染用户的真实记忆。
    /// 以"是否设置注入"判定（空串/坏 JSON 也算），见 SessionStore.hasInjectedSnapshot。
    static func recordingEnabled(restoreEnabled: Bool, hasInjectedSnapshot: Bool) -> Bool {
        restoreEnabled && !hasInjectedSnapshot
    }

    /// 本次启动实际使用的快照：恢复开关关闭（显式起始目录 / 参数域禁用）→ 一律不用，
    /// 连注入也不看——契约是"显式启动目录压过记忆"（注入只是另一种恢复来源）。
    /// 开关开启时：**设置了注入就以注入为准**，解码失败（injected == nil）也绝不回落
    /// 持久化快照（否则坏注入会静默恢复真实记忆，与隔离契约矛盾）；未设置注入才用持久化。
    static func snapshotToUse(restoreEnabled: Bool, hasInjectedSnapshot: Bool,
                              injected: SessionSnapshot?, stored: SessionSnapshot?) -> SessionSnapshot? {
        guard restoreEnabled else { return nil }
        return hasInjectedSnapshot ? injected : stored
    }
}
