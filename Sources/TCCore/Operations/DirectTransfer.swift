import Foundation

/// 跨机直传接缝的结果。
public enum DirectOutcome: Equatable {
    /// 本条目已整体完成（rsync 成功）；bytesTransferred = 实传字节。
    case handled(bytesTransferred: Int64)
    /// 直传不可用（原因串）——调用方走 pump。契约：**未传输任何字节**。
    case unavailable(String)
}
