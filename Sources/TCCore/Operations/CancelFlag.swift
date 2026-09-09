import Foundation

/// 传输取消标志：跨线程（UI 按钮置位、后台引擎读取）的单布尔量。
///
/// 类盒 + NSLock（C API，无泛型元数据）——本缩减 SDK 下禁动态建 DispatchQueue，
/// 亦不宜用 actor；锁临界区仅读写一个 Bool，无嵌套。CPSupport 类盒同型先例。
/// 语义：一旦置位不复位（一次传输一个标志，用完即弃）。
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    /// UI 侧调用：请求取消。
    public func cancel() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    /// 引擎侧调用：在文件边界 / pump 块边界轮询。
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
