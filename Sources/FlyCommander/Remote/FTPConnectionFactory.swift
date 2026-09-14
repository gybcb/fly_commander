import Foundation
import TCCore

/// 一次 FTP 登录所需的运行时参数（含凭据，**不可持久化**）。
///
/// `tls` = Implicit FTPS（990，连接即 TLS）。Explicit `AUTH TLS` 本期不支持——
/// 见 FTPClient 类注释（NWConnection 无同 socket 明文→TLS 升级能力）。
public struct FTPConnectionRequest: Equatable {
    public let host: String
    public let port: UInt16
    public let username: String
    public let password: String?
    public let tls: Bool

    public init(host: String, port: UInt16, username: String,
                password: String?, tls: Bool) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.tls = tls
    }
}

/// UI 集成合同：同步建连 + 登录 + PWD 取 home。
///
/// **调用方保证在后台线程执行**（内部 async→sync 桥会阻塞当前线程；
/// 主线程调用会冻结 runloop——与 SFTP 连接路径同一约束）。
public enum FTPConnectionFactory {
    /// 建连 → 登录 → PWD 拿 home → 返回可复用的 FTPSource（起始路径即 home）。
    /// 失败抛 TCError（连接失败/认证被拒/应答异常）。
    static func connect(_ req: FTPConnectionRequest) throws -> (FTPSource, home: TCPath) {
        let config = FTPClient.Config(host: req.host, port: req.port, username: req.username,
                                      password: req.password, tls: req.tls)
        let source = FTPSource(config: config)
        do {
            let home = try source.resolveHome()
            return (source, FTPSource.tcPath(host: req.host, port: Int(req.port), remotePath: home))
        } catch {
            // 建连失败不留半开连接（closeConnection 幂等）
            source.closeConnection()
            throw error
        }
    }
}
