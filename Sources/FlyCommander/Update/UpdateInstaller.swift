import AppKit
import Foundation
import TCCore
import CryptoKit

/// 一键升级执行器：下载 dmg → sha256 校验 → 挂载 → 替换 .app → 就绪重启。
/// 全部副作用走注入 seam（runShell/download/digest/relaunch），单测 hermetic 断言参数序列。
///
/// **红线（安全边界，勿"顺手优化"）**：本类**绝不**调用 `xattr` 清除下载隔离属性。
/// 自动清 quarantine = app 替用户放行未验证代码（恶意软件自更新器标准手法）。
/// Gatekeeper 指引以「可见、可复制、用户自己执行」的形态呈现（gatekeeperCommand 只产出
/// 字符串给 UI 显示，永不执行）。
final class UpdateInstaller {
    enum Phase: Equatable { case download, verify, replace }
    enum InstallError: Error, Equatable {
        case downloadFailed
        case checksumMismatch       // 先于挂载判定：哈希不过，任何东西都不碰
        case mountFailed(Int32, String)
        case copyFailed(Int32, String)
    }

    /// 真 shell（args[0]=可执行路径，同 SMBMountManager.exec 约定）。
    static func exec(_ args: [String]) -> (Int32, String) {
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

    /// 流式 sha256（1 MB 块，3 MB dmg 与未来大 dmg 都稳）→ 小写 hex。
    static func sha256Hex(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 真下载：同步 GET 写临时文件（只在后台队列调）。信号量同步包装（缩减 SDK 纪律）。
    static func downloadToTemp(_ url: URL) throws -> URL {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.setValue("FlyCommander-Update", forHTTPHeaderField: "User-Agent")
        let lock = NSLock()
        var result: Result<Data, Error>?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            lock.lock()
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                result = .failure(URLError(.badServerResponse))
            }
            else if let data { result = .success(data) }
            else { result = .failure(URLError(.zeroByteResource)) }
            lock.unlock()
            sem.signal()
        }.resume()
        guard sem.wait(timeout: .now() + 120) == .success else { throw URLError(.timedOut) }
        lock.lock(); let r = result; lock.unlock()
        let data = try (r ?? .failure(URLError(.unknown))).get()
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("FlyCommander-update-\(UUID().uuidString).dmg")
        try data.write(to: dest)
        return dest
    }

    // MARK: - 注入面

    private let runShell: ([String]) -> (Int32, String)
    private let download: (URL) throws -> URL
    private let digest: (URL) throws -> String
    private let currentBundleURL: URL
    private let tempDir: URL

    init(runShell: @escaping ([String]) -> (Int32, String) = UpdateInstaller.exec,
         download: @escaping (URL) throws -> URL = UpdateInstaller.downloadToTemp,
         digest: @escaping (URL) throws -> String = UpdateInstaller.sha256Hex,
         currentBundleURL: URL = Bundle.main.bundleURL,
         tempDir: URL = FileManager.default.temporaryDirectory) {
        self.runShell = runShell
        self.download = download
        self.digest = digest
        self.currentBundleURL = currentBundleURL
        self.tempDir = tempDir
    }

    /// 只产出**给用户看/复制**的放行命令（含引号包裹的路径）；本类永不执行它。
    var gatekeeperCommand: String {
        "xattr -dr com.apple.quarantine \"\(currentBundleURL.path)\""
    }

    /// 走完 下载→校验→挂载→替换→卸载。onPhase 依次收到 download/verify/replace。
    /// 任何一步失败即中止；替换阶段的失败做回滚（旧 bundle 移回原位）。
    /// 全程 runShell 参数序列（成功路）：attach → mv(旧让位) → cp(新就位) → detach，
    /// 失败路在 cp 失败时多一次 mv(回滚)。恒无 xattr。
    func install(manifest: UpdateManifest,
                 onPhase: @escaping (Phase) -> Void,
                 completion: @escaping (Result<Void, InstallError>) -> Void) {
        guard let dmgURL = URL(string: manifest.dmgURL) else {
            completion(.failure(.downloadFailed)); return
        }
        onPhase(.download)
        let dmg: URL
        do { dmg = try download(dmgURL) } catch { completion(.failure(.downloadFailed)); return }

        onPhase(.verify)
        let hex: String
        do { hex = try digest(dmg) } catch { completion(.failure(.checksumMismatch)); return }
        guard hex == manifest.sha256.lowercased() else {
            completion(.failure(.checksumMismatch)); return      // 先于挂载：哈希不过零副作用
        }

        onPhase(.replace)
        let mountPoint = tempDir.appendingPathComponent("fc-update-mnt-\(UUID().uuidString)")
        let oldAside = tempDir.appendingPathComponent("fc-update-old-\(UUID().uuidString).app")
        let staged = mountPoint.appendingPathComponent("FlyCommander.app")
        try? FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        var (code, out) = runShell(["/usr/bin/hdiutil", "attach", "-nobrowse",
                                    "-mountpoint", mountPoint.path, dmg.path])
        guard code == 0 else {
            try? FileManager.default.removeItem(at: mountPoint)
            completion(.failure(.mountFailed(code, out))); return
        }
        // 三步替换：旧让位(mv) → 新就位(cp -R) → 卸挂载。cp 失败回滚旧 bundle。
        (code, out) = runShell(["/bin/mv", currentBundleURL.path, oldAside.path])
        if code != 0 {
            _ = runShell(["/usr/bin/hdiutil", "detach", mountPoint.path])
            completion(.failure(.copyFailed(code, out))); return
        }
        (code, out) = runShell(["/bin/cp", "-R", staged.path, currentBundleURL.path])
        if code != 0 {
            _ = runShell(["/bin/mv", oldAside.path, currentBundleURL.path])   // 回滚
            _ = runShell(["/usr/bin/hdiutil", "detach", mountPoint.path])
            completion(.failure(.copyFailed(code, out))); return
        }
        _ = runShell(["/usr/bin/hdiutil", "detach", mountPoint.path])
        try? FileManager.default.removeItem(at: dmg)
        completion(.success(()))
    }

    /// 就绪重启：拉起**新实例** → 退出旧进程。注入面（测试不真启动 app）。
    /// 探针实证：本 SDK 无 `createsNewProcessInstance`，但有 ObjC 正名
    /// `createsNewApplicationInstance`——不设它，LaunchServices 会复用仍在跑的旧实例
    /// （净效果=只退出、不重启）。新实例成功拉起后才退出旧进程。
    var relaunch: () -> Void = {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            NSApp.terminate(nil)
        }
    }
}
