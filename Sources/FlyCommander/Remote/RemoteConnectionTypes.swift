import Foundation
import TCCore

/// 统一连接对话框支持的远端协议（段控件三选一）。
enum RemoteProto: String, Codable {
    case sftp
    case smb
    /// FTP 协议层由并行任务实现；本对话框只留注入缝（executors 缺该 key 即提示未接线）。
    case ftp

    /// 段控件展示名（走 L10n：现值为协议专名，中英同值；仍走表以随语言机制重刷）。
    var label: String {
        switch self {
        case .sftp: return L10n.t(.protoSFTP)
        case .smb: return L10n.t(.protoSMB)
        case .ftp: return L10n.t(.protoFTP)
        }
    }
}

/// 统一连接请求（连接窗表单 → 执行器）。协议不适用的字段恒 nil。
struct RemoteConnectionRequest {
    var proto: RemoteProto
    var name: String
    // sftp / ftp
    var host: String?
    var port: Int?
    // smb
    var server: String?
    var share: String?
    var domain: String?
    // 公共
    var username: String
    /// sftp：password / keyFile；smb/ftp 只有 password。
    var authKind: SFTPConnectionRecord.AuthKind?
    var keyPath: String?
    /// 密码或密钥 passphrase（未记住时仅本次使用）。
    var secret: String?
    var tls: Bool = false   // ftp 专用
}

/// 统一连接结果：任意 FileSource + 起始路径。
struct RemoteConnection {
    let source: any FileSource
    let home: TCPath
}

/// 连接执行注入合同：completion 须回主线程（沿用旧 connectExecutor 合同）。
typealias RemoteConnectExecutor = (RemoteConnectionRequest,
                                   @escaping (Result<RemoteConnection, Error>) -> Void) -> Void
