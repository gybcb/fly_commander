import Foundation
import XCTest

/// 本地 sshd 测试服务器（rootless）：/usr/sbin/sshd 起在 127.0.0.1 空闲端口，
/// 当前用户 + 测试专用密钥（ssh-keygen 现生成，绝不碰用户真实 ~/.ssh）+
/// 临时目录当"远端家目录"。环境不满足（无 sshd/端口被占/起不来）时
/// start() 返回 nil，测试据此 XCTSkip，保证无服务器环境不红。
///
/// 注意：sshd 以当前用户跑（非 root，故无法把测试临时目录设为真实 home；
/// 家目录语义由调用方在远端路径上用显式目录代替）。
final class SFTPServerFixture {
    struct Live {
        let port: Int
        let username: String
        /// 供调用方自行注入密码（本 fixture 不掌握系统密码；
        /// 密码认证测试需要调用方已知密码的用户——默认跳过密码用例）。
        let password: String?
        let keyPath: String        // 测试私钥（带 passphrase）
        let keyPassphrase: String
        let remoteBase: URL        // 远端工作目录（本地临时目录，登录后用）
    }

    private var sshdProcess: Process?
    private var tmpDir: URL?
    // restartInPlace 复用（同 config 同端口重拉需要）。
    private var configURL: URL?
    private var logURL: URL?
    private var currentPort: Int?

    func start() -> Live? {
        let sshd = "/usr/sbin/sshd"
        guard FileManager.default.isExecutableFile(atPath: sshd) else { return nil }
        // SFTP 子系统可执行文件（macOS 标准路径）；sshd 配置里必须声明
        // Subsystem sftp，否则服务端直接拒绝 sftp 子系统请求。
        let sftpServer = "/usr/libexec/sftp-server"
        guard FileManager.default.isExecutableFile(atPath: sftpServer) else { return nil }

        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("fly-sftp-test-\(UUID().uuidString)")
        let remoteBase = base.appendingPathComponent("work")
        let hostKeyURL = base.appendingPathComponent("host_ed25519")
        let privURL = base.appendingPathComponent("test_ed25519")
        let configURL = base.appendingPathComponent("sshd_config")
        let logURL = base.appendingPathComponent("sshd.log")
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            try fm.createDirectory(at: remoteBase, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            self.tmpDir = base
            self.configURL = configURL
            self.logURL = logURL
        } catch { return nil }

        let user = NSUserName()

        // 1) 测试密钥：带 passphrase 的 ed25519（同时验证 Traversio 的
        //    OpenSSH 格式 passphrase 加载能力——T0 的关键未知项之一）。
        let passphrase = "flytest-key-pass"
        guard Self.run(["/usr/bin/ssh-keygen", "-t", "ed25519", "-N", passphrase,
                        "-q", "-f", privURL.path]) == 0 else { cleanup(); return nil }

        // 2) 主机密钥。
        guard Self.run(["/usr/bin/ssh-keygen", "-t", "ed25519", "-N", "",
                        "-q", "-f", hostKeyURL.path]) == 0 else { cleanup(); return nil }

        // 3) authorized_keys（测试公钥进临时目录——绝不碰用户真实 ~/.ssh）。
        let pubData = (try? Data(contentsOf: privURL.appendingPathExtension("pub"))) ?? Data()
        guard !pubData.isEmpty else { cleanup(); return nil }
        let authKeysURL = base.appendingPathComponent("authorized_keys")
        do { try pubData.write(to: authKeysURL) } catch { cleanup(); return nil }

        // 4) sshd 配置（双认证开、PAM 关、StrictModes 关、authorized_keys
        //    显式指向临时文件——sshd 以当前用户跑，默认路径会落到真实 home）。
        let port = Self.findFreePort()
        guard port > 0 else { cleanup(); return nil }
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKeyURL.path)
        PasswordAuthentication yes
        PubkeyAuthentication yes
        UsePAM no
        StrictModes no
        AuthorizedKeysFile \(authKeysURL.path)
        Subsystem sftp \(sftpServer)
        LogLevel ERROR
        """
        do { try config.write(to: configURL, atomically: true, encoding: .utf8) }
        catch { cleanup(); return nil }

        // 4) 起 sshd（-D 前台，日志落文件）。
        guard launchSSHD(configURL: configURL, logURL: logURL) != nil else {
            cleanup(); return nil
        }
        currentPort = port

        // 5) 端口就绪探测（sshd 未就绪时 connect 被拒）。
        guard Self.waitPortReady(port: port, deadline: 10) else {
            // 诊断：把 sshd 日志打到测试输出，便于定位启动失败原因。
            if let log = try? String(contentsOf: logURL) {
                print("sshd 启动失败，日志：\n\(log)")
            }
            cleanup()
            return nil
        }

        return Live(port: port, username: user, password: nil,
                    keyPath: privURL.path, keyPassphrase: passphrase,
                    remoteBase: remoteBase)
    }

    /// 起一个前台 sshd（-D）挂在 configURL 上；成功返回进程，失败 nil。
    private func launchSSHD(configURL: URL, logURL: URL) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        p.arguments = ["-D", "-f", configURL.path]
        do {
            let logHandle = try FileHandle(forWritingTo: logURL)
            p.standardOutput = logHandle
            p.standardError = logHandle
        } catch { return nil }
        do { try p.run() } catch { return nil }
        sshdProcess = p
        return p
    }

    /// 杀 sshd **进程树**（父 + 全部后代）——sshd fork-per-connection + 特权分离：
    /// 直接子 = monitor，真正服务 socket 的是 monitor 再 fork 的非特权子（ppid≠父）。
    /// 只杀父/直接子 → 非特权子 reparent 后继续服务，客户端连接不死（实测）。
    /// 必须递归杀全树，OS 才对活连接发 RST。
    func killServerTree() {
        guard let parent = sshdProcess else { return }
        killDescendants(of: parent.processIdentifier)
        kill(parent.processIdentifier, SIGKILL)
        parent.waitUntilExit()
        sshdProcess = nil
    }

    /// BFS 收集全部后代 pid，先杀后代再返回（杀完后轮询确认消失，最多 ~2s）。
    private func killDescendants(of pid: pid_t) {
        var queue: [pid_t] = [pid]
        var all: [pid_t] = []
        var head = 0
        while head < queue.count {
            defer { head += 1 }
            let r = Self.runCapture(["/usr/bin/pgrep", "-P", String(queue[head])])
            for line in r.split(whereSeparator: { $0.isNewline }) {
                guard let child = Int32(line), !all.contains(child) else { continue }
                all.append(child)
                queue.append(child)
            }
        }
        for child in all.reversed() { kill(child, SIGKILL) }
        // 等全部后代真正消失（reap 有微小时差）
        for _ in 0..<20 {
            let alive = all.contains { kill($0, 0) == 0 }
            if !alive { return }
            usleep(100_000)
        }
    }

    /// 原地重启（模拟唤醒）：杀进程树 → 同 config 同端口重新拉起。
    /// 旧连接被打死，服务器可重连——修复后的连接层应懒重连恢复。
    func restartInPlace() -> Bool {
        guard let configURL, let logURL, let port = currentPort else { return false }
        killServerTree()
        // 端口释放有微小时差：轮询重拉（bind 失败重试），最多 ~3s。
        for i in 0..<15 {
            if launchSSHD(configURL: configURL, logURL: logURL) != nil,
               Self.waitPortReady(port: port, deadline: 2) {
                return true
            }
            usleep(UInt32(200_000 * (i + 1)))
        }
        return false
    }

    private static func runCapture(_ cmd: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    func cleanup() {
        sshdProcess?.terminate()
        sshdProcess = nil
        if let base = tmpDir {
            try? FileManager.default.removeItem(at: base)
            tmpDir = nil
        }
    }

    // MARK: - 私有工具

    private static func run(_ cmd: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd[0])
        p.arguments = Array(cmd.dropFirst())
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private static func findFreePort() -> Int {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        let bindOK = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindOK == 0 else { return 0 }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameOK = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameOK == 0 else { return 0 }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    private static func waitPortReady(port: Int, deadline: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            if s >= 0 {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
                let ok = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                close(s)
                if ok == 0 { return true }
            }
            usleep(200_000)
        }
        return false
    }
}
