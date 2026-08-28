import Foundation

public enum TCError: Error, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case busy(String)
    case invalidPath(String)
    case cancelled
    case unknown(String)

    public var message: String {
        switch self {
        case .notFound(let p): return "找不到：\(p)"
        case .permissionDenied(let p): return "没有权限访问：\(p)"
        case .busy(let p): return "忙碌/被占用：\(p)"
        case .invalidPath(let p): return "无效路径：\(p)"
        case .cancelled: return "已取消"
        case .unknown(let m): return m
        }
    }
}

public func asTCError(_ error: Error) -> TCError {
    if let e = error as? TCError { return e }
    let ns = error as NSError
    switch ns.code {
    case NSFileNoSuchFileError:
        return .notFound(ns.localizedDescription)
    case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
        return .permissionDenied(ns.localizedDescription)
    case NSFileReadInvalidFileNameError:
        return .invalidPath(ns.localizedDescription)
    case NSFileWriteFileExistsError:
        return .unknown("目标已存在同名文件")
    case NSFileWriteOutOfSpaceError:
        return .unknown("磁盘空间不足")
    default:
        // 256（NSFileReadUnknownError）等未知原因的通用错误不猜具体类别。
        return .unknown(ns.localizedDescription)
    }
}
