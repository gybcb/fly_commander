import Foundation

/// 跨机直传接缝的结果。
public enum DirectOutcome: Equatable {
    /// 本条目已整体完成（rsync 成功）；bytesTransferred = 实传字节。
    case handled(bytesTransferred: Int64)
    /// 直传不可用（原因串）——调用方走 pump。契约：**未传输任何字节**。
    /// 唯一例外 = 空闲看门狗超时路（`rsyncIdleTimeoutCode`）：可能已推部分字节，
    /// 回退 pump 依赖 streamWrite truncate 重写 + rsync 无 --partial 自弃 .tmp。
    case unavailable(String)
}

extension DirectOutcome {
    /// rsync 静默超空闲阈值（对端半死）——app 层 SFTPSource 据此丢弃被烧连接、
    /// pump 走懒重建（传输层收包不理 cancellation，僵尸收包者占死旧连接）。
    public static let rsyncIdleTimeoutCode = "rsyncIdleTimeout"
    /// `unavailable(code)` 是否为看门狗超时码。
    public var isRsyncIdleTimeout: Bool {
        if case .unavailable(let code) = self { return code == Self.rsyncIdleTimeoutCode }
        return false
    }
}
