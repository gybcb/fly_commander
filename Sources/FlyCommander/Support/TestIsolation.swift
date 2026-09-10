import Foundation

/// 测试隔离：UI 测试（真窗）在启动时写 UserDefaults 会污染开发者真实偏好——
/// 收藏夹条目指向已删的临时夹具目录、showHiddenFiles 被翻成 true 都会串台到下次 `swift run`。
/// 复用代码库**唯一**的「UI 测试模式」信号 `-flyDisableSessionRestore YES`（所有真窗用例都传），
/// 命中则抑制收藏夹/隐藏开关的落盘（会话恢复本就被它关掉）。Tier-1 注入空 suite 不受影响。
enum TestIsolation {
    static var suppressPreferenceWrites: Bool {
        UserDefaults.standard.bool(forKey: "flyDisableSessionRestore")
    }
}
