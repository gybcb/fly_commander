import Foundation
import TCCore

/// SMB 挂载生命周期（挂载式后端的 SMB 特有心智）。
/// 纯函数（mountArgs/mountPointPath/staleMounts）可单测；真实 mount/unmount 由 e2e 验证。
final class SMBMountManager {
    static let root = "/Volumes/FlyCommander"

    // MARK: - 纯函数（可单测）

    /// 挂载点：/Volumes/FlyCommander/<sanitize(server)>--<sanitize(share)>。
    static func mountPointPath(_ config: SMBConnectionConfig) -> String {
        root + "/" + sanitize(config.server) + "--" + sanitize(config.share)
    }

    /// 只留 [A-Za-z0-9-]，其余字符（空格/斜杠/点/下划线等）一律替换成 -。
    static func sanitize(_ s: String) -> String {
        String(s.unicodeScalars.map { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
                ? Character(c) : "-"
        })
    }

    /// 挂载 URL 允许的字符：字母数字 + $ - . ! * ' ( )。
    /// user/pass 里的 ; @ : & 空格等分隔符/特殊字符必须 percent-encode。
    static let credentialAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" +
        "$-.*'()!")

    /// percent-encode 用户/密码（保留字符集见 credentialAllowed）。
    static func encodeCredential(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: credentialAllowed) ?? s
    }

    /// mount_smbfs 参数：URL //<domain;user[:pass]>@<server>/<share>（macOS 版无 credentials 文件）。
    /// domain 分隔符是 ;（SMB 惯例）；secret 为空/nil → 不带冒号。
    static func mountArgs(config: SMBConnectionConfig, secret: String?) -> [String] {
        let domainPart = config.domain.map { encodeCredential($0) + ";" } ?? ""
        let passPart = (secret?.isEmpty == false) ? ":\(encodeCredential(secret!))" : ""
        let url = "//\(domainPart)\(encodeCredential(config.username))\(passPart)@\(config.server)/\(config.share)"
        return ["/sbin/mount_smbfs", "-N", url, mountPointPath(config)]
    }

    /// 解析 `mount` 输出，返回落在 /Volumes/FlyCommander/ 下的挂载点（第 3 列，以 root 开头）。
    static func staleMounts(fromMountOutput: String) -> [String] {
        fromMountOutput.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 3 else { return nil }
            let mp = String(cols[2])
            return mp.hasPrefix(root + "/") ? mp : nil
        }
    }

    // MARK: - 真实挂载（e2e 验证）。每个动作注一个 [String]->(exit,stderr)，args[0]=可执行路径。

    private let runMount: ([String]) -> (Int32, String)     // (exit, stderr)
    private let runUnmount: ([String]) -> (Int32, String)
    private let runList: () -> String                        // `mount` 全文

    init(runMount: @escaping ([String]) -> (Int32, String) = SMBMountManager.exec,
         runUnmount: @escaping ([String]) -> (Int32, String) = SMBMountManager.exec,
         runList: @escaping () -> String = { SMBMountManager.exec(["/usr/bin/mount"]).1 }) {
        self.runMount = runMount
        self.runUnmount = runUnmount
        self.runList = runList
    }

    func mount(_ config: SMBConnectionConfig, secret: String?) throws -> URL {
        let mp = Self.mountPointPath(config)
        let fm = FileManager.default
        try fm.createDirectory(atPath: Self.root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: mp, withIntermediateDirectories: true)
        if isMounted(URL(fileURLWithPath: mp)) {
            return URL(fileURLWithPath: mp)   // 复用
        }
        let (code, stderr) = runMount(Self.mountArgs(config: config, secret: secret))
        guard code == 0, isMounted(URL(fileURLWithPath: mp)) else {
            throw TCError.unknown("SMB 挂载失败（exit \(code)）：\(stderr.prefix(200))")
        }
        return URL(fileURLWithPath: mp)
    }

    func unmount(_ mountPoint: URL) throws {
        _ = runUnmount(["/sbin/umount", "-f", mountPoint.path])   // 已卸则忽略
    }

    /// 只查 mount 表（runList）——**不**加 contentsOfDirectory 兜底：
    /// 预建的空挂载点目录会让它误判"已挂"。mount_smbfs 是同步调用，返回即挂好，单判据可靠。
    func isMounted(_ mountPoint: URL) -> Bool {
        Self.staleMounts(fromMountOutput: runList()).contains(mountPoint.path)
    }

    /// 启动清理 /Volumes/FlyCommander/* 残留挂载（手动挂的 /Volumes 别处 smb 卷不碰）。
    func reclaimStale() {
        for mp in Self.staleMounts(fromMountOutput: runList()) {
            try? unmount(URL(fileURLWithPath: mp))   // 静默回收
        }
    }

    /// 跑外部命令，返回 (exitCode, stderr)。stdout 合并进 stderr 一并回传（诊断用）。
    /// 约定：args[0] 是**可执行文件路径**，其余是它的参数（mountArgs 等按此生成）。
    private static func exec(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        p.standardError = pipe
        p.standardOutput = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
