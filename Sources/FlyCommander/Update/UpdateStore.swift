import Foundation

/// 更新偏好持久化（ThemeStore 同构单例）：上次检查时间 + 用户跳过的版本。
/// storeKey 点分域；persist 首行 TestIsolation 闸（UI 测试零污染）。
final class UpdateStore {
    static let shared = UpdateStore()

    private let defaults: UserDefaults
    private let lastCheckKey = "update.lastCheck"
    private let skippedKey = "update.skippedVersion"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 上次发起检查的 Unix 时间（从未检查 = nil）。setter 传 nil 清空。
    var lastCheck: TimeInterval? {
        get { defaults.object(forKey: lastCheckKey) as? Double }
        set {
            guard !TestIsolation.suppressPreferenceWrites else { return }
            if let v = newValue { defaults.set(v, forKey: lastCheckKey) }
            else { defaults.removeObject(forKey: lastCheckKey) }
        }
    }

    /// 用户点了「跳过此版本」的版本号（该版本不再自动弹窗提示）。
    var skippedVersion: String? {
        get { defaults.string(forKey: skippedKey) }
        set {
            guard !TestIsolation.suppressPreferenceWrites else { return }
            if let v = newValue { defaults.set(v, forKey: skippedKey) }
            else { defaults.removeObject(forKey: skippedKey) }
        }
    }
}
