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

    /// 解析 mount 表一行 → (设备列, 挂载点)。按 " on " 与末个 " (" 切——
    /// server/share/挂载点都可能含空格，不能按空格切列。
    static func parseMountLine(_ line: String) -> (device: String, mountPoint: String)? {
        guard let onRange = line.range(of: " on ") else { return nil }
        let device = String(line[..<onRange.lowerBound])
        let rest = line[onRange.upperBound...]
        guard let paren = rest.range(of: " (", options: .backwards) else { return nil }
        return (device, String(rest[..<paren.lowerBound]))
    }

    /// 解析 `mount` 输出，返回落在 /Volumes/FlyCommander/ 下的挂载点。
    static func staleMounts(fromMountOutput: String) -> [String] {
        fromMountOutput.split(separator: "\n").compactMap { line in
            guard let parsed = parseMountLine(String(line)),
                  parsed.mountPoint.hasPrefix(root + "/") else { return nil }
            return parsed.mountPoint
        }
    }

    /// 从工具输出里抹掉凭据，防 mount_smbfs 把含密码的 URL 回显进错误信息。
    /// `replacingOccurrences(of:)` 是字面量匹配（非正则），无需转义。
    static func redact(_ text: String, url: String, secret: String?) -> String {
        var out = text
        out = out.replacingOccurrences(of: url, with: "[REDACTED]")   // 完整挂载 URL（含密码）
        if let s = secret, !s.isEmpty {
            out = out.replacingOccurrences(of: encodeCredential(s), with: "***") // percent-encoded 密码
            out = out.replacingOccurrences(of: s, with: "***")            // 原始密码（万一被解码后回显）
        }
        return out
    }

    /// 共享 URL 的"server/share"标识（mount 表设备列形如 //user@server/share 或 //domain;user:pass@server/share）。
    static func shareIdentifier(fromMountLine: String) -> String? {
        guard let parsed = parseMountLine(fromMountLine),
              parsed.device.hasPrefix("//") else { return nil }
        let rest = parsed.device.dropFirst(2)
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let offset = rest.distance(from: rest.startIndex, to: at) + 1
        return String(rest.dropFirst(offset))
    }

    /// 该 server/share 是否已被挂在别处（如 Finder 挂在 /Volumes/<share>）。
    /// 命中返回其挂载点路径；已挂在本挂载点（root 下）返回 nil（由 isMounted 复用分支处理）。
    static func shareMountedPoint(server: String, share: String,
                                  fromMountOutput: String) -> String? {
        let id = "\(server)/\(share)"
        for line in fromMountOutput.split(separator: "\n") {
            guard let parsed = parseMountLine(String(line)),
                  Self.shareIdentifier(fromMountLine: String(line)) == id else { continue }
            if !parsed.mountPoint.hasPrefix(root + "/") { return parsed.mountPoint }
        }
        return nil
    }

    /// 预建挂载点目录（root + 挂载点）。/Volumes 不可写时由调用方转 permissionDenied 提示。
    static func makeDirectories(_ mp: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: mp, withIntermediateDirectories: true)
    }

    // MARK: - 真实挂载（e2e 验证）。每个动作注一个 [String]->(exit,stderr)，args[0]=可执行路径。

    private let runMount: ([String]) -> (Int32, String)     // (exit, output)
    private let runUnmount: ([String]) -> (Int32, String)   // (exit, output)
    private let runList: () -> String                        // `mount` 全文
    private let ensureDirectories: (String) throws -> Void   // 建 root+挂载点目录（测试可注 fake 免触 /Volumes）

    init(runMount: @escaping ([String]) -> (Int32, String) = SMBMountManager.exec,
         runUnmount: @escaping ([String]) -> (Int32, String) = SMBMountManager.exec,
         runList: @escaping () -> String = { SMBMountManager.exec(["/usr/bin/mount"]).1 },
         ensureDirectories: @escaping (String) throws -> Void = SMBMountManager.makeDirectories) {
        self.runMount = runMount
        self.runUnmount = runUnmount
        self.runList = runList
        self.ensureDirectories = ensureDirectories
    }

    func mount(_ config: SMBConnectionConfig, secret: String?) throws -> URL {
        let mp = Self.mountPointPath(config)
        // macOS 对同一共享只允许一个活动挂载：Finder 已挂 /Volumes/<share> 时
        // 重挂会 EEXIST —— 复用其挂载点（同 sourceID 不重连哲学，扩展到系统级）。
        // 建目录之前先查：纯复用连接根本不需要 app 目录（没跑过一次性 sudo mkdir 的机器不撞权限错）。
        if let existing = Self.shareMountedPoint(server: config.server, share: config.share,
                                                 fromMountOutput: runList()) {
            return URL(fileURLWithPath: existing)
        }
        do {
            try ensureDirectories(mp)
        } catch {
            // /Volumes 对当前用户不可写（root:wheel）时建目录 EACCES——
            // 给出一次性的提权命令，用户照抄即可，之后无需再 sudo。
            // 指引文案是 `errMountPointHint` 多行模板（中英各一份），内核只出 root。
            if case .permissionDenied = asTCError(error) {
                throw TCError.mountPointNotWritable(root: Self.root)
            }
            throw asTCError(error)
        }
        if isMounted(URL(fileURLWithPath: mp)) {
            return URL(fileURLWithPath: mp)   // 复用
        }
        let args = Self.mountArgs(config: config, secret: secret)
        let url = args[2]   // mountArgs[2] 是 //…@server/share 挂载 URL（含密码）
        let (code, stderr) = runMount(args)
        guard code == 0, isMounted(URL(fileURLWithPath: mp)) else {
            // 诊断的 200 截断由 TCError（message/l10nArgs 两脸一致）负责，这里不再手工 .prefix。
            throw TCError.smbMountFailed(
                code: code, diag: Self.redact(stderr, url: url, secret: secret))
        }
        return URL(fileURLWithPath: mp)
    }

    func unmount(_ mountPoint: URL) throws {
        _ = runUnmount(["/sbin/umount", "-f", mountPoint.path])   // 已卸则忽略
    }

    /// 断开挂载点；若它不在本 app 根（root）下（如复用了 Finder 的 /Volumes/<share> 挂载），
    /// 卸载后把共享挂回**原挂载点**（断连不该吞掉用户的 Finder 卷）。
    /// 重挂失败时共享处于未挂载状态，用户重连（app 或 Finder）即可。
    func putBackMount(_ mountPoint: URL, config: SMBConnectionConfig, secret: String?) throws {
        let wasOutsideRoot = !mountPoint.path.hasPrefix(Self.root + "/")
        try unmount(mountPoint)
        guard wasOutsideRoot else { return }
        var args = Self.mountArgs(config: config, secret: secret)
        args[3] = mountPoint.path   // mountArgs[3] 是挂载点；挂回原处而非 app 根
        let url = args[2]           // //…@server/share 挂载 URL（含密码）
        let (code, stderr) = runMount(args)
        let back = Self.shareMountedPoint(server: config.server, share: config.share,
                                          fromMountOutput: runList())
        guard code == 0, back == mountPoint.path else {
            // 同上：语义 case + 结构化 exit 码，截断交 TCError。
            throw TCError.putBackFailed(
                code: code, diag: Self.redact(stderr, url: url, secret: secret))
        }
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
