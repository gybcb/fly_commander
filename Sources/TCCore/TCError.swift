import Foundation

public enum TCError: Error, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case busy(String)
    case invalidPath(String)
    case cancelled
    case alreadyExists(String?)       // "已存在同名：X" / 系统 FileExists 无主体
    case dirExists(String)            // "目录已存在：X"（mkdir 专用）
    case crossSourceDir(String)       // "跨源传输暂不支持目录：X"
    case noSpace                      // "磁盘空间不足"
    case sftpNotExecuted              // "SFTP 操作未执行"
    case smbMountFailed(code: Int32, diag: String)   // "SMB 挂载失败（exit N）：diag"
    case putBackFailed(code: Int32, diag: String)    // "挂回原处失败（exit N）：diag"
    case pathOutsideShare(String)     // "路径不在共享内：X"（SMB 段边界越界）
    case pathEscaped(String)          // "路径逃逸挂载点：X"（折叠 .. 后跑出挂载点）
    case mountPointNotWritable(root: String)         // 多行提权指引（/Volumes 不可写）
    case authRejected(method: String) // "认证被拒绝（method）"（SFTP SSHClientError.authenticationRejected）
    case sftpConnectFailed            // "SFTP 连接失败"（SFTP SSHClientError.connectionFailed）
    case ftpConnectFailed(String)     // "FTP 连接失败：detail"
    case ftpDataConnectFailed(String) // "FTP 数据连接失败：detail"
    /// RETR 收到 226（服务器自认发完）但字节数 < SIZE 预期 = 数据完整性失败，
    /// **不是**连接失败：文案必须分开，否则用户去查网络而不重传该文件。
    case ftpTransferTruncated(got: Int64, expected: Int64)
    case ftpTimeout(Double)           // "FTP 操作超时（N 秒）"
    case ftpConnectionClosed          // "FTP 连接已关闭"
    case unknown(String)              // 收窄：仅 locale 透传（系统 localizedDescription / Traversio message）

    /// 稳定英文内部 message —— 仅供日志/测试/跨模块，不进 UI 显示路径（UI 用 tcErrorDisplay）。
    /// smb/putBack 的 diag 在此截断 200，与 l10nArgs 保持两脸一致。
    public var message: String {
        switch self {
        case .notFound(let p):          return "Not found: \(p)"
        case .permissionDenied(let p):  return "Permission denied: \(p)"
        case .busy(let p):              return "Busy: \(p)"
        case .invalidPath(let p):       return "Invalid path: \(p)"
        case .cancelled:                return "Cancelled"
        case .alreadyExists(let x?):    return "Already exists: \(x)"
        case .alreadyExists(nil):       return "Already exists"
        case .dirExists(let x):         return "Directory already exists: \(x)"
        case .crossSourceDir(let x):    return "Cross-source directory transfer unsupported: \(x)"
        case .noSpace:                  return "No space left on device"
        case .sftpNotExecuted:          return "SFTP operation did not execute"
        case .smbMountFailed(let c, let d): return "SMB mount failed (exit \(c)): \(d.prefix(200))"
        case .putBackFailed(let c, let d):  return "Put-back mount failed (exit \(c)): \(d.prefix(200))"
        case .pathOutsideShare(let p):      return "Path outside share: \(p)"
        case .pathEscaped(let p):           return "Path escaped the mount point: \(p)"
        case .authRejected(let m):          return "Authentication rejected (\(m))"
        case .sftpConnectFailed:            return "SFTP connection failed"
        case .ftpConnectFailed(let d):      return "FTP connect failed: \(d.prefix(200))"
        case .ftpDataConnectFailed(let d):  return "FTP data connection failed: \(d.prefix(200))"
        case .ftpTransferTruncated(let g, let e): return "FTP transfer truncated: got \(g) of \(e) bytes"
        case .ftpTimeout(let s):            return "FTP timed out after \(s)s"
        case .ftpConnectionClosed:          return "FTP connection closed"
        case .mountPointNotWritable(let r):
            return "Cannot create mount point \(r) (/Volumes not writable for current user). "
                 + "Run this once in Terminal:\nsudo mkdir -p \(r) && sudo chown \"$(whoami)\" \(r)"
        case .unknown(let m):           return m
        }
    }

    /// 语义本地化键（TCCore 内算，L10nKey 零依赖 AppKit 成立）。显示层按此键查表。
    public var l10nKey: L10nKey {
        switch self {
        case .notFound:          return .errNotFound
        case .permissionDenied:  return .errPermissionDenied
        case .busy:              return .errBusy
        case .invalidPath:       return .errInvalidPath
        case .cancelled:         return .errCancelled
        case .alreadyExists(let x?): return .errAlreadyExists
        case .alreadyExists(nil):    return .errAlreadyExistsBare
        case .dirExists:         return .errDirExists
        case .crossSourceDir:    return .errCrossSourceDir
        case .noSpace:           return .errNoSpace
        case .sftpNotExecuted:   return .errSFTPNotExecuted
        case .smbMountFailed:    return .errSMBMountFailed
        case .putBackFailed:     return .errPutBackFailed
        case .pathOutsideShare:  return .errPathOutsideShare
        case .pathEscaped:       return .errPathEscaped
        case .authRejected:      return .errAuthRejected
        case .sftpConnectFailed: return .errSFTPConnectFailed
        case .ftpConnectFailed: return .errFTPConnectFailed
        case .ftpDataConnectFailed: return .errFTPDataConnectFailed
        case .ftpTransferTruncated: return .errFTPTransferTruncated
        case .ftpTimeout: return .errFTPTimeout
        case .ftpConnectionClosed: return .errFTPConnectionClosed
        case .mountPointNotWritable: return .errMountPointHint
        case .unknown:           return .errUnknown
        }
    }

    /// 位置插值参数（与 l10nKey 配套，供显示层 t(key, args…) 展开）。
    /// smb/putBack 的 diag 截断 200，与 message 保持一致（两脸一致）。
    public var l10nArgs: [String] {
        switch self {
        case .notFound(let p), .permissionDenied(let p), .busy(let p), .invalidPath(let p):
            return [p]
        case .cancelled, .noSpace, .sftpNotExecuted:
            return []
        case .alreadyExists(let x?):
            return [x]
        case .alreadyExists(nil):
            return []
        case .dirExists(let x), .crossSourceDir(let x):
            return [x]
        case .smbMountFailed(let c, let d), .putBackFailed(let c, let d):
            return ["\(c)", String(d.prefix(200))]
        case .pathOutsideShare(let p), .pathEscaped(let p):
            return [p]
        case .authRejected(let m):
            return [m]
        case .sftpConnectFailed, .ftpConnectionClosed:
            return []
        case .ftpConnectFailed(let d), .ftpDataConnectFailed(let d):
            return [String(d.prefix(200))]
        case .ftpTransferTruncated(let g, let e):
            return [String(g), String(e)]
        case .ftpTimeout(let s):
            return [s == s.rounded() ? String(Int(s)) : String(s)]
        case .mountPointNotWritable(let r):
            return [r]   // 模板内 {0} 出现 3 次，t() 全量替换
        case .unknown(let m):
            return [m]
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
        return .alreadyExists(nil)
    case NSFileWriteOutOfSpaceError:
        return .noSpace
    default:
        // 256（NSFileReadUnknownError）等未知原因的通用错误不猜具体类别。
        return .unknown(ns.localizedDescription)
    }
}
