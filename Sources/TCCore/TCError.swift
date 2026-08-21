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
    case NSFileReadInvalidFileNameError, NSFileReadUnknownError:
        return .invalidPath(ns.localizedDescription)
    default:
        return .unknown(ns.localizedDescription)
    }
}
