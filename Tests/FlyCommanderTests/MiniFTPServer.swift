import Foundation
import Network
import XCTest

/// 进程内最小 FTP 服务器（NWListener，绑 127.0.0.1 随机端口），锁 FTPSource 端到端。
///
/// 后端是一个真实临时目录（登录后 home=该目录绝对路径），命令直接映射到 FileManager，
/// 故 RETR/STOR 落盘可被测试逐字节比对。支持：USER/PASS/230、FEAT、UTF8、TYPE、PWD、
/// CWD、PASV、LIST、MLSD、RETR、STOR、MKD、RMD、DELE、RNFR/RNTO、MDTM、SIZE、QUIT。
///
/// 铁律：所有 NWConnection/NWListener 回调用 `.global(qos:)`，**绝不动态建队列**。
/// 每连接一个 async `run()` 循环（FTP 天然串行：客户端不发下一条直到收到上一条应答）。
final class MiniFTPServer {
    let root: URL
    /// 是否 FEAT 声明 MLSD（关掉 → 客户端 LIST 回退路径）
    let advertiseMlsd: Bool
    /// MLSD/MLST 是否回 500（测客户端 LIST 回退 + stat 降级链）
    let refuseMlsd: Bool
    /// PASV 之外是否也支持 EPSV（本期客户端只走 PASV）
    let advertiseEpsv: Bool
    /// 登录口令（"user"/"secret"）；其它 → 530
    let password: String
    /// MLST 应答码（RFC 3659 规定 250；本 fixture 默认沿用旧实现的 257）。
    let mlstReplyCode: Int
    /// RETR 只发前 N 字节就 RST 数据通道、随后照常回 226（F1 截断注入；nil=关）。
    let retrTruncateBytes: Int?

    private var controlListener: NWListener?
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var started = false
    private var startError: Error?

    init(root: URL, advertiseMlsd: Bool = true, refuseMlsd: Bool = false,
         advertiseEpsv: Bool = false, password: String = "secret",
         mlstReplyCode: Int = 257, retrTruncateBytes: Int? = nil) {
        self.root = root
        self.advertiseMlsd = advertiseMlsd
        self.refuseMlsd = refuseMlsd
        self.advertiseEpsv = advertiseEpsv
        self.password = password
        self.mlstReplyCode = mlstReplyCode
        self.retrTruncateBytes = retrTruncateBytes
    }

    /// 同步启动：绑定监听端口后返回实际端口（轮询等待 ready，上限 ~5s）。
    ///
    /// **`listener.port` 在 `state == .ready` 之前返回 `0`**（实测：start 后立刻读得到
    /// `Optional(0)`，ready 后才是真端口），故只判 `port != nil` 会把 **0** 当端口返回，
    /// 客户端连 port 0 → `Can't assign requested address` → 整条 e2e 全挂。必须等 ready。
    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: 0)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleNewControl(conn)
        }
        controlListener = listener
        listener.start(queue: .global(qos: .userInitiated))
        // 轮询 state==.ready 拿实际端口
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .ready = listener.state, let p = listener.port, p.rawValue != 0 {
                self.port = p.rawValue; started = true; return p.rawValue
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw NSError(domain: "MiniFTPServer", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "listener not ready"])
    }

    func stop() {
        controlListener?.cancel()
        controlListener = nil
    }

    private func handleNewControl(_ conn: NWConnection) {
        // 不在此 start：由会话的 startAndWaitReady 先装 stateUpdateHandler 再 start。
        let session = FTPServerSession(conn: conn, server: self)
        Task { await session.run() }
    }
}

// MARK: - NWConnection 异步收发小工具（服务端用）

private extension NWConnection {
    /// 装 handler 后再 start，等到 ready（一次性盒防双 resume）。
    /// 顺序很重要：先 start 再装 handler 会在「ready 先于赋值到达」时永久卡死。
    func startAndWaitReady() async -> Bool {
        await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            let box = ServerVoidBox(k)
            stateUpdateHandler = { state in
                switch state {
                case .ready: box.resume(true)
                case .failed, .cancelled: box.resume(false)
                default: break
                }
            }
            start(queue: .global(qos: .userInitiated))
        }
    }

    func sendAll(_ data: Data) async {
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            send(content: data, completion: .contentProcessed { _ in
                k.resume()
            })
        }
    }

    /// 收到 EOF（isComplete 或 error 或空块且已 isComplete）为止累计全部字节。
    func receiveAll() async -> Data {
        var out = Data()
        while true {
            let chunk: Data? = await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
                receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error { k.resume(returning: nil); return }
                    if let data, !data.isEmpty { k.resume(returning: data); return }
                    if isComplete { k.resume(returning: nil); return }
                    k.resume(returning: Data())        // 空块非 EOF：继续
                }
            }
            guard let chunk else { break }
            if chunk.isEmpty { continue }
            out.append(chunk)
        }
        return out
    }

    /// 收一行（\r\n 结尾），来自外部累计缓冲。返回 nil=对端关闭。
    func receiveLine(buffered: ServerLineBuffer) async -> String? {
        while true {
            if let line = buffered.takeLine() { return line }
            let chunk: Data? = await withCheckedContinuation { (k: CheckedContinuation<Data?, Never>) in
                receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                    if let error { k.resume(returning: nil); return }
                    if let data, !data.isEmpty { k.resume(returning: data); return }
                    if isComplete { k.resume(returning: nil); return }
                    k.resume(returning: Data())
                }
            }
            guard let chunk else { return nil }
            if !chunk.isEmpty { buffered.append(chunk) }
        }
    }
}

/// 一次性续作盒（服务端版，双 resume 防护）。
private final class ServerVoidBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ v: T) {
        lock.lock(); guard let c = cont else { lock.unlock(); return }; cont = nil; lock.unlock()
        c.resume(returning: v)
    }
}

/// 行缓冲（服务端读命令用）。
final class ServerLineBuffer {
    private var bytes: [UInt8] = []
    func append(_ d: Data) { bytes.append(contentsOf: d) }
    func takeLine() -> String? {
        guard let nl = bytes.firstIndex(of: 0x0A) else { return nil }
        var end = nl
        if nl > 0, bytes[nl - 1] == 0x0D { end = nl - 1 }
        let s = String(decoding: bytes[0..<end], as: UTF8.self)
        bytes.removeSubrange(0...nl)
        return s
    }
}

// MARK: - 会话

private final class FTPServerSession {
    private let conn: NWConnection
    private let server: MiniFTPServer
    private let buffer = ServerLineBuffer()
    private var cwd: String          // 远端绝对路径（真实 FS 路径）
    private var user: String?
    private var renameFrom: String?
    /// PASV 预备的数据 listener + 已接受连接
    private var dataListener: NWListener?
    private let dataLock = NSLock()
    private var acceptedData: NWConnection?

    init(conn: NWConnection, server: MiniFTPServer) {
        self.conn = conn
        self.server = server
        self.cwd = server.root.standardizedFileURL.path
    }

    func run() async {
        guard await conn.startAndWaitReady() else { conn.cancel(); return }
        await reply("220 MiniFTP ready")
        while true {
            guard let line = await conn.receiveLine(buffered: buffer) else { break }
            let handled = await handle(line)
            if handled == .quit { break }
        }
        conn.cancel()
        dataListener?.cancel()
    }

    enum Outcome { case `continue`, quit }

    private func handle(_ line: String) async -> Outcome {
        // "VERB 空格 参数"；参数保留原样（含空格）
        let verb: String
        let arg: String
        if let sp = line.firstIndex(of: " ") {
            verb = String(line[..<sp]).uppercased()
            arg = String(line[line.index(after: sp)...])
        } else {
            verb = line.uppercased(); arg = ""
        }
        switch verb {
        case "USER":
            user = arg
            await reply("331 Password required")
        case "PASS":
            if arg == server.password { await reply("230 Logged in") }
            else { await reply("530 Login incorrect") }
        case "FEAT":
            var lines = ["211-Features:"]
            if server.advertiseMlsd, !server.refuseMlsd { lines.append(" MLSD") }
            lines.append(" UTF8")
            lines.append(" SIZE")
            lines.append(" MDTM")
            lines.append("211 End")
            await replyRaw(lines.joined(separator: "\r\n"))
        case "UTF8", "OPTS":
            await reply("200 OK")
        case "TYPE":
            await reply("200 Type set to I")
        case "PWD":
            await reply("257 \"\(cwd)\" is current directory")
        case "CWD":
            let target = resolve(arg)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target, isDirectory: &isDir), isDir.boolValue {
                cwd = target
                await reply("250 Directory changed")
            } else {
                await reply("550 No such directory")
            }
        case "SIZE":
            let target = resolve(arg)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
               let sz = attrs[.size] as? Int {
                await reply("213 \(sz)")
            } else { await reply("550 Size operation failed") }
        case "MDTM":
            let target = resolve(arg)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
               let mtime = attrs[.modificationDate] as? Date {
                await reply("213 \(Self.formatMdtm(mtime))")
            } else { await reply("550") }
        case "PASV":
            await doPasv()
        case "EPSV":
            await reply("500 EPSV not supported")     // 本期客户端只走 PASV
        case "MLST":
            if server.refuseMlsd { await reply("500 MLST not understood"); break }
            let target = resolve(arg)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else {
                await reply("550 no such file")
                break
            }
            let attrs = try? FileManager.default.attributesOfItem(atPath: target)
            let size = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            let type = isDir.boolValue ? "dir" : "file"
            let facts = "  type=\(type);size=\(size);modify=\(Self.formatMdtm(mtime));"
            await replyRaw("\(server.mlstReplyCode)-Listing \(target)\r\n\(facts) \(URL(fileURLWithPath: target).lastPathComponent)\r\n\(server.mlstReplyCode) End")
        case "LIST", "MLSD":
            if verb == "MLSD", server.refuseMlsd { await reply("500 MLSD not understood") }
            else { await doList(mlsd: verb == "MLSD", arg: arg) }
        case "RETR":
            await doRetr(arg)
        case "STOR":
            await doStor(arg)
        case "MKD":
            let target = resolve(arg)
            do {
                try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: false)
                await reply("257 \"\(target)\" created")
            } catch { await reply("550 Create directory operation failed") }
        case "RMD":
            let target = resolve(arg)
            do { try FileManager.default.removeItem(atPath: target); await reply("250 RMD successful") }
            catch { await reply("550 RMD failed") }
        case "DELE":
            let target = resolve(arg)
            do { try FileManager.default.removeItem(atPath: target); await reply("250 DELE successful") }
            catch { await reply("550 DELE failed") }
        case "RNFR":
            renameFrom = resolve(arg)
            await reply("350 Ready to rename")
        case "RNTO":
            guard let from = renameFrom else { await reply("550 Rename failed"); break }
            do {
                try FileManager.default.moveItem(atPath: from, toPath: resolve(arg))
                renameFrom = nil
                await reply("250 Rename successful")
            } catch { await reply("550 Rename failed") }
        case "QUIT":
            await reply("221 Bye")
            return .quit
        default:
            await reply("500 Unknown command")
        }
        return .continue
    }

    // MARK: 数据通道命令

    private func doPasv() async {
        // 服务端也开一个 listener 接数据（绑 127.0.0.1）
        do {
            let dl = try NWListener(using: .tcp, on: 0)
            dl.newConnectionHandler = { [weak self] c in
                c.start(queue: .global(qos: .userInitiated))
                self?.dataLock.lock()
                self?.acceptedData = c
                self?.dataLock.unlock()
            }
            dl.start(queue: .global(qos: .userInitiated))
            // 等实际端口（同 start()：ready 前 port 是 0）
            let deadline = Date().addingTimeInterval(5)
            var p: NWEndpoint.Port?
            while Date() < deadline {
                if case .ready = dl.state, let lp = dl.port, lp.rawValue != 0 { p = lp; break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let port = p else { dataListener?.cancel(); dataListener = dl; await reply("425 no data port"); return }
            dataListener?.cancel()
            dataListener = dl
            acceptedData = nil
            let hi = UInt8(port.rawValue / 256)
            let lo = UInt8(port.rawValue % 256)
            await reply("227 Entering Passive Mode (127,0,0,1,\(hi),\(lo)).")
        } catch {
            await reply("425 Can't open data connection")
        }
    }

    /// 取已接受的数据连接（客户端先发 PASV、再连数据、再发命令；给短暂等待窗口）。
    private func takeDataConnection() async -> NWConnection? {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            dataLock.lock()
            let c = acceptedData
            dataLock.unlock()
            if let c { return c }
            try? await Task.sleep(nanoseconds: 3_000_000)
        }
        return nil
    }

    /// LIST/MLSD 的**参数就是目标路径**（空参 = cwd）。之前恒用 cwd 是错的：
    /// 客户端发的是 `LIST /abs/path`，服务端列 cwd 会返回完全不相干的条目。
    private func doList(mlsd: Bool, arg: String) async {
        guard let data = await takeDataConnection() else { await reply("425 no data"); return }
        await reply("150 Here comes the directory listing")
        let dir = arg.isEmpty ? cwd : resolve(arg)
        let text: String
        if mlsd {
            text = (try? mlsdListing(dir)) ?? ""
        } else {
            text = (try? unixListing(dir)) ?? ""
        }
        await data.sendAll(Data(text.utf8))
        data.cancel()
        await reply("226 Transfer complete")
    }

    private func doRetr(_ arg: String) async {
        guard let data = await takeDataConnection() else { await reply("425 no data"); return }
        let target = resolve(arg)
        guard let contents = FileManager.default.contents(atPath: target) else {
            // 文件不存在：仍接受数据连接，但直接 450（无数据）。先回 150 再 450 不合协议——
            // 简化：回 550（不发 150）。数据连接由客户端超时关闭。
            await reply("550 Failed to open file")
            return
        }
        await reply("150 Opening data connection")
        if let n = server.retrTruncateBytes {
            // 只发前 n 字节 → 数据通道以 error 收尾（服务端 cancel 产生 RST 类错误），
            // 但服务器仍自认为发完 → 照发 226（实证「226=发完」不成立）。
            await data.sendAll(contents.prefix(n))
        } else {
            await data.sendAll(contents)
        }
        data.cancel()
        await reply("226 Transfer complete")
    }

    private func doStor(_ arg: String) async {
        guard let data = await takeDataConnection() else { await reply("425 no data"); return }
        await reply("150 Ok to send data")
        let payload = await data.receiveAll()     // 客户端写完即 close → 这里收到 EOF
        data.cancel()
        let target = resolve(arg)
        do {
            try payload.write(to: URL(fileURLWithPath: target))
            await reply("226 Transfer complete")
        } catch {
            await reply("550 Write failed")
        }
    }

    // MARK: 目录列表生成（真实 FS）

    private func unixListing(_ dir: String) throws -> String {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [])
        var out = ""
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = rv?.isDirectory ?? false
            let size = rv?.fileSize ?? 0
            let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate) ?? Date()
            let perm = isDir ? "drwxr-xr-x" : "-rw-r--r--"
            let name = url.lastPathComponent
            // 时间格式 "MMM DD HH:MM"（近半年）或 "MMM DD YYYY"
            out += "\(perm) 1 owner group \(isDir ? 4096 : size) \(Self.lsDate(mtime)) \(name)\r\n"
        }
        return out
    }

    private func mlsdListing(_ dir: String) throws -> String {
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [])
        var out = ""
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDir = rv?.isDirectory ?? false
            let size = rv?.fileSize ?? 0
            let mtime = rv?.contentModificationDate ?? Date()
            let type = isDir ? "dir" : "file"
            let facts = "type=\(type);size=\(size);modify=\(Self.formatMdtm(mtime));"
            out += "\(facts) \(url.lastPathComponent)\r\n"
        }
        return out
    }

    // MARK: 路径 / 时间

    private func resolve(_ arg: String) -> String {
        if arg.hasPrefix("/") { return arg }
        return cwd.hasSuffix("/") ? cwd + arg : cwd + "/" + arg
    }

    /// MDTM/MLSD modify：`YYYYMMDDhhmmss`（UTC）。
    static func formatMdtm(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// LIST 时间列：近 6 月内 `MMM DD HH:MM`，否则 `MMM DD YYYY`（用本地时区，和真服务器一致）。
    static func lsDate(_ date: Date) -> String {
        let months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let mon = months[(c.month ?? 1) - 1]
        let age = -date.timeIntervalSinceNow
        if age < 6 * 30.44 * 24 * 3600 {
            return String(format: "%@ %02d %02d:%02d", mon, c.day ?? 1, c.hour ?? 0, c.minute ?? 0)
        }
        return String(format: "%@ %02d %d", mon, c.day ?? 1, c.year ?? 1970)
    }

    // MARK: 应答发送

    private func reply(_ s: String) async { await conn.sendAll(Data((s + "\r\n").utf8)) }
    private func replyRaw(_ s: String) async { await conn.sendAll(Data((s + "\r\n").utf8)) }
}
