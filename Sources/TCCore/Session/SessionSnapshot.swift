import Foundation

/// 退出时的会话快照：左右窗格目录 + 活动侧。纯数据（TCCore 零 AppKit、零 IO），
/// 持久化由 app 层 SessionStore 负责。
///
/// 容错解码是硬要求：**单字段损坏不得让整份解码失败**——否则一侧的手改垃圾
/// 会连累另一侧的记忆（两窗格一起回落默认目录）。故每个字段独立 `try?`：
/// 缺失或类型不符都降级为该字段的默认值，其余字段照常读回。
public struct SessionSnapshot: Codable, Equatable {
    public let version: Int
    public var leftPath: String?
    public var rightPath: String?
    public var active: String          // "left" / "right"

    public init(version: Int = 1, leftPath: String?, rightPath: String?, active: String) {
        self.version = version
        self.leftPath = leftPath
        self.rightPath = rightPath
        self.active = active
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        leftPath = try? c.decode(String.self, forKey: .leftPath)
        rightPath = try? c.decode(String.self, forKey: .rightPath)
        // 未知/缺失的 active 一律当左——非法值不得让启动落空。
        active = (try? c.decode(String.self, forKey: .active)) == "right" ? "right" : "left"
    }
}
