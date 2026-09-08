import Foundation
import TCCore

/// 会话快照的持久化门面（UserDefaults + JSON Data，键 "session.lastDirectories"）。
/// 仿 ThemeStore：单例 + 可注入 defaults（单测用独立 suite，不碰 .standard）；
/// 编解码失败一律静默回落 nil——记忆是尽力而为，绝不因坏数据打扰用户。
final class SessionStore {
    static let shared = SessionStore()

    private let defaults: UserDefaults
    private let storeKey = "session.lastDirectories"
    private(set) var snapshot: SessionSnapshot?
    /// 上次写盘/读盘的快照，用于 saveIfChanged 去重（每次刷新都写盘是无谓开销）。
    /// init 必须用解码结果初始化，否则新进程首次保存的去重失效（白写一次）。
    private var lastWritten: SessionSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storeKey),
           let s = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
            snapshot = s
            lastWritten = s
        }
    }

    /// 与上次写盘相等 → 不写盘返回 false；否则写盘并同步内存态返回 true。
    @discardableResult
    func saveIfChanged(_ s: SessionSnapshot) -> Bool {
        guard s != lastWritten else { return false }
        guard let data = try? JSONEncoder().encode(s) else { return false }
        defaults.set(data, forKey: storeKey)
        snapshot = s
        lastWritten = s
        return true
    }

    /// 遗忘记忆：键与内存态一并清除（否则同进程内 snapshot 仍是旧值）。
    func clear() {
        defaults.removeObject(forKey: storeKey)
        snapshot = nil
        lastWritten = nil
    }

    /// `-flyDisableSessionRestore YES`（argument domain）→ 关闭恢复（UI 测试用）。
    static var disabledByArgumentDomain: Bool {
        UserDefaults.standard.bool(forKey: "flyDisableSessionRestore")
    }

    /// 环境变量注入（UI 测试用）：FLY_SESSION_JSON 的原始串；未设置 → nil。
    static var injectedRaw: String? {
        ProcessInfo.processInfo.environment["FLY_SESSION_JSON"]
    }

    /// 是否**设置了**注入（空串也算设置）。以存在性而非"能否解码"判定：
    /// 注入存在却解码失败时必须按"注入"处理（不回落真实记忆、不写回），
    /// 否则手误/格式漂移反而会静默恢复并污染用户的真实偏好。
    static var hasInjectedSnapshot: Bool { injectedRaw != nil }

    /// 解码注入快照：未设置 / 非法 JSON → nil。
    static func injectedSnapshot() -> SessionSnapshot? {
        decodeInjected(injectedRaw)
    }

    /// 纯解码（可单测）：nil / 非法 JSON → nil。
    static func decodeInjected(_ json: String?) -> SessionSnapshot? {
        guard let json = json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionSnapshot.self, from: data)
    }
}
