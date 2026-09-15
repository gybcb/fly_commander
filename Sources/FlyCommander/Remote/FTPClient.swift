import Foundation
import Network
import Security
import TCCore

// MARK: - 错误

/// FTP 层错误（协议/传输级）。→ TCError 的映射统一走 FTPSource.ftpmappedTCError。
public enum FTPClientError: Error, Equatable {
    /// 控制连接建立失败（DNS/拒连/握手/未就绪）
    case connectFailed(String)
    /// 登录被拒（530）。payload = 被拒阶段。
    case authRejected(String)
    /// 服务器应答码不符合预期（语义判别只看 code）
    case unexpectedReply(code: Int, message: String)
    /// 数据连接建立/读写失败
    case dataConnectFailed(String)
    /// 超时（控制命令或数据通道）
    case timeout(Double)
    /// 连接已关闭
    case closed
    /// 服务器能力缺失（如无 PASV）
    case unsupported(String)
    /// 应答/端点解析失败
    case malformedReply(String)
    /// 路径含 CR/LF：FTP 行协议整行即参数，无法转义 → **拒绝发送**而非静默改写
    /// （静默替换会把操作打到另一个路径上，且 UI 显示的路径与实发参数不一致）。
    /// 控制流不受影响（命令根本没发出）。
    case invalidPath

    /// 应答码（仅 unexpectedReply 承载）。
    public var replyCode: Int? {
        switch self {
        case .unexpectedReply(let code, _): return code
        default: return nil
        }
    }

    /// 「主体不存在」语义只由码号 550 承载（服务器自由文本不可判语义）。
    public var isNotFoundReply: Bool { replyCode == 550 }
}

// MARK: - 应答（值类型）

/// 一条 FTP 应答（可能多行）。
public struct FTPReply: Equatable {
    public let code: Int
    /// 各行文本（已去 \r\n）。单行应答即 1 元素。
    public let lines: [String]
    public var message: String { lines.first ?? "" }

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// 单码号断言；不符 → throw（调用方带命令名只为读得懂栈）。
    public func expect(_ want: Int, command: String = "") throws {
        guard code == want else { throw FTPClientError.unexpectedReply(code: code, message: message) }
    }

    public func expectOneOf(_ want: [Int], command: String = "") throws {
        guard want.contains(code) else {
            throw FTPClientError.unexpectedReply(code: code, message: message)
        }
    }
}

// MARK: - 应答分帧（纯函数 + 可测状态机）

/// 控制连接行协议分帧器：字节进、整条应答出。
///
/// RFC 959 §4.2：
/// - 单行 = `NNN sp text`
/// - 多行 = 首行 `NNN-…`，中间行首字符非空格，结束行 `NNN sp…`（同码号）
/// 零 IO、零时钟，可单测。
public final class FTPReplyParser {
    private var bytes: [UInt8] = []

    public init() {}

    public func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    /// 取出一条完整应答；不足 → nil。
    public func nextReply() -> FTPReply? {
        var lines: [String] = []
        var code: Int?
        while let line = takeLine() {
            if code == nil {
                // 某些服务器在 220 之前塞无码横幅注释行 → 丢弃继续找。
                guard let c = Self.parseCode(line) else { continue }
                code = c
                lines.append(line)
                if Self.isSingleLine(line) { return FTPReply(code: c, lines: lines) }
                continue
            }
            lines.append(line)
            if Self.isSingleLine(line), Self.parseCode(line) == code {
                return FTPReply(code: code!, lines: lines)
            }
        }
        return nil
    }

    /// 剩余未消费字节数（测试/诊断用）。
    public var pendingByteCount: Int { bytes.count }

    private func takeLine() -> String? {
        guard let nl = bytes.firstIndex(of: 0x0A) else { return nil }
        var end = nl
        if nl > 0, bytes[nl - 1] == 0x0D { end = nl - 1 }
        let slice = Array(bytes[0..<end])
        bytes.removeSubrange(0...nl)
        return String(decoding: slice, as: UTF8.self)
    }

    /// 前 3 字符为数字 → 码号。
    public static func parseCode(_ line: String) -> Int? {
        guard line.utf8.count >= 3 else { return nil }
        let prefix = Array(line.utf8.prefix(3))
        guard prefix.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(String(decoding: prefix, as: UTF8.self))
    }

    /// `NNN sp…`（第 4 字节是空格）；长度恰 3 也当单行（个别服务器省尾随空格）。
    public static func isSingleLine(_ line: String) -> Bool {
        let b = Array(line.utf8)
        if b.count == 3 { return parseCode(line) != nil }
        guard b.count >= 4, parseCode(line) != nil else { return false }
        return b[3] == 0x20
    }

    /// `NNN-…`
    public static func isMultiLineStart(_ line: String) -> Bool {
        let b = Array(line.utf8)
        guard b.count >= 4, parseCode(line) != nil else { return false }
        return b[3] == 0x2D
    }
}

// MARK: - PASV / EPSV 端点解析（纯函数）

public struct FTPDataEndpoint: Equatable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public enum FTPPasv {
    /// `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2).`
    /// 容错：句号/空白/多行、括号前有裸 IP 的写法（一律取括号内 6 段）。
    public static func parse(_ reply: FTPReply, fallbackHost: String) -> FTPDataEndpoint? {
        guard let text = reply.lines.first(where: { $0.contains("(") }),
              let open = text.firstIndex(of: "(") else { return nil }
        // 括号内到最近的 ')'；无 ')' 则取到行尾
        let after = text.index(after: open)
        let closeIdx = text[after...].firstIndex(of: ")") ?? text.endIndex
        return sixNumbers(String(text[after..<closeIdx]), fallbackHost: fallbackHost)
    }

    /// `229 Entering Extended Passive Mode (|||port|).`
    public static func parseEpsv(_ reply: FTPReply, fallbackHost: String) -> FTPDataEndpoint? {
        guard let text = reply.lines.first(where: { $0.contains("|") }),
              let first = text.firstIndex(of: "|") else { return nil }
        let digits = text[text.index(after: first)...].filter(\.isNumber)
        guard let p = UInt16(digits), p != 0 else { return nil }
        return FTPDataEndpoint(host: fallbackHost, port: p)
    }

    private static func sixNumbers(_ s: String, fallbackHost: String) -> FTPDataEndpoint? {
        let parts = s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "." })
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            .map(String.init)
        guard parts.count >= 6 else { return nil }
        let tail = Array(parts.suffix(2))
        guard let hi = UInt32(tail[0]), let lo = UInt32(tail[1]), hi <= 255, lo <= 255 else { return nil }
        let port = UInt16(hi * 256 + lo)
        guard port != 0 else { return nil }
        let host = parts.dropLast(2).joined(separator: ".")
        return FTPDataEndpoint(host: host.isEmpty ? fallbackHost : host, port: port)
    }
}

// MARK: - 时间（纯函数）

public enum FTPDate {
    /// MLSD `modify=` / MDTM：`YYYYMMDDhhmmss`（RFC 3659 规定 UTC）。容忍尾随 `Z`/小数秒。
    public static func parseTimestamp(_ s: String) -> Date? {
        let digits = String(s.prefix { $0.isNumber })
        guard digits.count >= 14 else { return nil }
        func slice(_ off: Int) -> Int? { Int(digits.dropFirst(off).prefix(2)) }
        guard let y = Int(digits.prefix(4)), let mo = slice(4), let d = slice(6),
              let h = slice(8), let mi = slice(10), let se = slice(12),
              (1...12).contains(mo), (1...31).contains(d), h <= 23, mi <= 59, se <= 60 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = se
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!      // UTC
        return cal.date(from: c)
    }
}

// MARK: - 目录列表条目（值类型）

/// LIST / MLSD 单条结果（不含路径；路径由 FTPSource 拼）。
public struct FTPListEntry: Equatable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modificationDate: Date
    public let isExecutable: Bool

    public init(name: String, isDirectory: Bool, size: Int64,
                modificationDate: Date, isExecutable: Bool) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.isExecutable = isExecutable
    }
}

// MARK: - 列表解析（纯函数：MLSD + LIST 双格式）

/// `now`/`timeZone` 注入而非取当下 → 单测可判定「当年 vs 去年」分支。
public enum FTPListParser {
    /// 一批 LIST 行 → 条目。无法解析的行静默丢弃（噪声行/分页行）。
    ///
    /// **必须用 `Character.isNewline` 而非 `== "\n" || == "\r"`**：Swift 的 `Character`
    /// 是字素簇，`"\r\n"` 合成**单个**簇，既不 `== "\r"` 也不 `== "\n"` → 逐字符比较
    /// 永不命中，整段 LIST 当成一行（名字里带裸 CRLF）。`isNewline` 把 `"\r\n"` 整簇判真。
    public static func parseList(_ text: String, now: Date, timeZone: TimeZone) -> [FTPListEntry] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { parseListLine(String($0), now: now, timeZone: timeZone) }
    }

    public static func parseMlsd(_ text: String) -> [FTPListEntry] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { parseMlsdLine(String($0)) }
    }

    // MARK: MLSD

    /// RFC 3659：事实以 `;` 分隔、事实区以 `; `（分号+空格）收尾，其后整段是条目名
    /// （可含空格）。名字含空格时名称区即答案；少数服务器额外给一个**末位** `name=`
    /// 事实，两者应当一致，故名称区优先（更贴近服务器实际发出的字节）。
    public static func parseMlsdLine(_ line: String) -> FTPListEntry? {
        // 事实区可为**空**（RFC 3659 允许）：形如 "  name"（名字前恰两个空格）。
        // 若只认 "; "，这类合规行整行被静默丢 → 目录列不全。
        var factsText = ""
        var name: String
        if let sep = line.range(of: "; ") {
            factsText = String(line[line.startIndex..<sep.lowerBound])
            name = String(line[line.index(sep.lowerBound, offsetBy: 2)...])
        } else if line.hasPrefix("  ") {
            name = String(line.dropFirst(2))
        } else {
            return nil
        }
        var facts: [String: String] = [:]
        for token in factsText.split(separator: ";") {
            let t = token.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "=") else { continue }
            facts[t[t.startIndex..<eq].lowercased()] = String(t[t.index(after: eq)...])
        }
        guard !name.isEmpty, name != "." , name != ".." else { return nil }
        let type = (facts["type"] ?? "file").lowercased()
        let isDir = type == "dir" || type == "cdir" || type == "pdir"
        let size = Int64(facts["size"] ?? "") ?? 0
        let date = facts["modify"].flatMap(FTPDate.parseTimestamp)
            ?? facts["create"].flatMap(FTPDate.parseTimestamp)
            ?? .distantPast
        return FTPListEntry(name: name, isDirectory: isDir, size: isDir ? 0 : size,
                            modificationDate: date, isExecutable: isDir)
    }

    // MARK: LIST

    public static func parseListLine(_ line: String, now: Date,
                                     timeZone: TimeZone) -> FTPListEntry? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        let lower = t.lowercased()
        // UNIX `total 42` / IIS `Directory of …` 提示行
        if lower == "total" || lower.hasPrefix("total ") { return nil }
        if lower.hasPrefix("directory of") { return nil }
        if let dos = parseDosLine(t, now: now, timeZone: timeZone) { return dos }
        return parseUnixLine(t, now: now, timeZone: timeZone)
    }

    /// UNIX ls：`-rw-r--r-- 1 owner group 12345 Jan 01 12:34 name[ -> target]`
    /// 时间两形态：`MMM DD HH:MM`（当年/去年）与 `MMM DD YYYY`。
    ///
    /// 列数**不固定**：名字可含空格、GNU `ls` 的 SELinux/ACL 后缀（`drwxr-xr-x.` /
    /// `-rw-rw-r--+`）让权限列变 11 字符、部分实现省略链接数或 group 列。固定 9 段切法
    /// 会让整目录条目被 compactMap 静默丢空（实证：SELinux 后缀 3/4 被丢）。
    /// 故以「日期三元组」为锚定位，前后列数弹性。
    static func parseUnixLine(_ line: String, now: Date, timeZone: TimeZone) -> FTPListEntry? {
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 6 else { return nil }
        let perm = String(f[0])
        guard looksLikePerm(perm) else { return nil }
        let kind = perm.first ?? "?"
        // 锚定日期：找第一个「数字尺寸 + 月份名 + 数字日 + 时间/年」位置。
        // 正向扫描 = 命中真日期在前（名字里的伪日期段在其后），且真日期必满足该形态。
        var mi = -1
        for i in 3..<(f.count - 2) {
            guard monthNumber(String(f[i])) != nil,
                  Int(f[i - 1]) != nil, Int(f[i + 1]) != nil,
                  looksLikeTimeOrYear(String(f[i + 2])) else { continue }
            mi = i; break
        }
        guard mi >= 3 else { return nil }                 // 至少 perm/…/size 三列在前
        let size = Int64(f[mi - 1]) ?? 0
        guard let date = unixDate(month: String(f[mi]), day: Int(f[mi + 1]) ?? 0,
                                  third: String(f[mi + 2]), now: now, timeZone: timeZone) else { return nil }
        var name = f[(mi + 3)...].joined(separator: " ")
        // 符号链接写作 `foo -> bar`：名字只取箭头前（目录判定跟链接本身，按文件处理）
        if kind == "l", let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrow.lowerBound])
        }
        guard !name.isEmpty, name != "." , name != ".." else { return nil }
        let isDir = kind == "d"
        let exec = perm.contains("x")
        return FTPListEntry(name: name, isDirectory: isDir, size: isDir ? 0 : size,
                            modificationDate: date, isExecutable: isDir || exec)
    }

    /// 第三段时间列形态：`HH:MM` 或 4 位年份（unixDate 的两种合法第三段）。
    static func looksLikeTimeOrYear(_ s: String) -> Bool {
        if s.count == 5, s.contains(":") { return true }
        return s.count == 4 && Int(s) != nil
    }

    /// ls 权限列形态：首字符 ∈ -dlbcps，其后 9 位 ∈ rwxstST-（mode 位），
    /// 再可跟 1 位后缀指示符：GNU `ls -l` 的 SELinux/ACL（`.` / `+`）或 BSD/macOS
    /// 扩展属性（`@`）——FTP 服务器跑在 BSD/macOS 上时会带 `@`。
    /// （形态判定是双格式路由的关键——MS-DOS 行没有权限列，误判会把尺寸读成名字。）
    static func looksLikePerm(_ s: String) -> Bool {
        let c = Array(s)
        guard c.count == 10 || c.count == 11 else { return false }
        guard "-dlbcps".contains(c[0]) else { return false }
        // mode 的 9 位
        guard c[1...9].allSatisfy({ "rwxstST-".contains($0) }) else { return false }
        // 第 11 位（若有）= ACL/SELinux/扩展属性指示符
        if c.count == 11 { return ".+@".contains(c[10]) }
        return true
    }

    /// `HH:MM` 形态无年份列 = 「最近半年内」→ 当年；算出在未来 → 去年。
    static func unixDate(month: String, day: Int, third: String,
                         now: Date, timeZone: TimeZone) -> Date? {
        guard let mo = monthNumber(month), (1...31).contains(day) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var c = DateComponents()
        c.month = mo; c.day = day
        if third.count == 5, third.contains(":") {
            let p = third.split(separator: ":")
            guard p.count == 2, let h = Int(p[0]), let mi = Int(p[1]), h <= 23, mi <= 59 else { return nil }
            c.hour = h; c.minute = mi
            let thisYear = cal.component(.year, from: now)
            c.year = thisYear
            guard let asThisYear = cal.date(from: c) else { return nil }
            // 未来 6 个月以外 → 说明是去年的条目（ls 只对 >6 月旧的省略年份？不：省略年份=近6月内，
            // 故算出在未来即年份取错，回退去年）。
            let sixMonths: TimeInterval = 6 * 30.44 * 24 * 3600
            if asThisYear.timeIntervalSince(now) > sixMonths {
                c.year = thisYear - 1
                return cal.date(from: c)
            }
            return asThisYear
        }
        if third.count == 4, let y = Int(third), (1970...2100).contains(y) {
            c.year = y
            c.hour = 12                 // 无时间列 → 中午，避开时区跨日抖动
            return cal.date(from: c)
        }
        return nil
    }

    static func monthNumber(_ m: String) -> Int? {
        let names = ["jan", "feb", "mar", "apr", "may", "jun",
                     "jul", "aug", "sep", "oct", "nov", "dec"]
        let key = m.prefix(3).lowercased()
        guard let i = names.firstIndex(where: { $0 == key }) else { return nil }
        return i + 1
    }

    /// MS-DOS：`05-13-26  10:35AM  <DIR>  sub` / `05-13-26  10:35AM  12345 file.txt`
    static func parseDosLine(_ line: String, now: Date, timeZone: TimeZone) -> FTPListEntry? {
        // 切成 3 段（日期/时间/其余）再解析「其余」：文件行的尺寸与名字之间只保证至少
        // 一个空格、名字本身可含空格 → 固定列数切法会把名字丢掉。
        let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard f.count == 3 else { return nil }
        // 第 2 段须含 ':'（时间列）——双格式路由判据，缺它 UNIX 行会误入 DOS
        guard f[1].contains(":") else { return nil }
        guard let date = dosDate(String(f[0]), time: String(f[1]), now: now, timeZone: timeZone) else { return nil }
        // maxSplits 切出的第 3 段带着列间空格的行首空白 → 先剥
        let rest = f[2].trimmingCharacters(in: .whitespaces)
        if rest.uppercased().hasPrefix("<DIR>") {
            let name = rest.dropFirst("<DIR>".count).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "." , name != ".." else { return nil }
            return FTPListEntry(name: name, isDirectory: true, size: 0,
                                modificationDate: date, isExecutable: true)
        }
        // 文件行：`尺寸 名字`
        let sp = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard sp.count == 2, sp[0].allSatisfy(\.isNumber), !sp[0].isEmpty else { return nil }
        let name = String(sp[1]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "." , name != ".." else { return nil }
        return FTPListEntry(name: name, isDirectory: false, size: Int64(sp[0]) ?? 0,
                            modificationDate: date, isExecutable: false)
    }

    /// `MM/DD/YY`｜`MM-DD-YY`｜`MM.DD.YY` + `hh:mmAM|PM`（大小写/空格/缺 AM-PM 容忍）。
    static func dosDate(_ d: String, time: String, now: Date, timeZone: TimeZone) -> Date? {
        let dp = d.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." })
        guard dp.count == 3, dp[2].count <= 4 else { return nil }
        guard let mo = Int(String(dp[0])), let dd = Int(String(dp[1])), let yy = Int(String(dp[2])),
              (1...12).contains(mo), (1...31).contains(dd) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var c = DateComponents()
        c.month = mo; c.day = dd
        if dp[2].count <= 2 {
            // 两位年 → 当前世纪（IIS 惯例）
            c.year = (cal.component(.year, from: now) / 100) * 100 + yy
        } else { c.year = yy }

        var t = time.lowercased().replacingOccurrences(of: " ", with: "")
        var isPM = false, isAM = false
        if t.hasSuffix("am") { isAM = true; t = String(t.dropLast(2)) }
        else if t.hasSuffix("pm") { isPM = true; t = String(t.dropLast(2)) }
        let tp = t.split(separator: ":")
        guard tp.count >= 2, let h = Int(tp[0]), let mi = Int(tp[1]), mi <= 59 else { return nil }
        if isPM || isAM { guard (1...12).contains(h) else { return nil } }
        else { guard (0...23).contains(h) else { return nil } }
        if isPM, h < 12 { c.hour = h + 12 }
        else if isAM, h == 12 { c.hour = 0 }
        else { c.hour = h }
        c.minute = mi
        if tp.count >= 3, let s = Int(tp[2]), s <= 60 { c.second = s }
        return cal.date(from: c)
    }
}

// MARK: - 一次性续作盒

/// CheckedContinuation 双 resume = trap。网络状态回调与读回调可能同时想 resume，
/// 所有续作统一过这个盒（首个生效，其余 no-op）。
final class ResumeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Error>?

    init(_ cont: CheckedContinuation<T, Error>) { self.cont = cont }

    @discardableResult func resume(_ body: () -> T) -> Bool { fire { $0.resume(returning: body()) } }
    @discardableResult func resume(throwing error: Error) -> Bool { fire { $0.resume(throwing: error) } }

    private func fire(_ action: (CheckedContinuation<T, Error>) -> Void) -> Bool {
        lock.lock()
        guard let c = cont else { lock.unlock(); return false }
        cont = nil
        lock.unlock()
        action(c)
        return true
    }
}

// MARK: - 超时（Task race，绝不建队列）

/// `body` 与定时器赛跑。超时抛 .timeout（调用方据此判连接作废）。
///
/// **为什么不用 withThrowingTaskGroup**：task group 在闭包返回时会等**所有**子任务收尾，
/// 而 body 可能正卡在 NWConnection 的 continuation 上（收不到数据就永不 resume，
/// `cancelAll` 也唤不醒它）→ 超时会假性「永不返回」。
/// 故这里用两个**独立 Task** 抢写同一个一次性盒，父任务只等那一个续作：
/// 超时先到就立即返回 .timeout，body 那个 Task 之后自行收尾（RaceBox 双写 no-op，
/// 且 FTPSource 随即标死/关闭连接，其 receive 会以 error 结束）。
public enum FTPTask {
    public static func withTimeout<T: Sendable>(_ seconds: Double,
                                                _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let box = RaceBox<T>()
        let seconds = max(0.001, seconds)
        let work = Task {
            do { box.fill(.success(try await body())) }
            catch { box.fill(.failure(error)) }
        }
        // 定时器：`Task.sleep` **独占 cooperative 池线程直到睡满**。不取消就会在连续
        // 十几次命令后把池抽干（实测：整页 e2e 全挂）。故结果一出立刻 cancel。
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { box.fillTimeout(seconds) }
        }
        do {
            let v = try await box.value()
            timer.cancel(); work.cancel()
            return v
        } catch {
            timer.cancel(); work.cancel()
            throw error
        }
    }
}

/// body / 定时器共写的一次性结果盒（首个生效）。
private final class RaceBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var conts: [CheckedContinuation<T, Error>] = []

    func fill(_ r: Result<T, Error>) { setResult(r) }
    func fillTimeout(_ seconds: Double) { setResult(.failure(FTPClientError.timeout(seconds))) }

    private func setResult(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let pending = conts; conts = []
        lock.unlock()
        for c in pending { c.resume(with: r) }
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<T, Error>) in
            lock.lock()
            if let r = result { lock.unlock(); k.resume(with: r); return }
            conts.append(k)
            lock.unlock()
        }
    }
}

// MARK: - 控制连接

/// FTP 控制连接。**同一时刻只有一个 outstanding receive**（由上层串行锁保证），
/// 故无「两次 receive 交错投递」的乱序风险；不做后台读循环。
///
/// 超时/断连后协议流状态不可知（可能有半条应答残留在解析器里）→ 一律标死，
/// 由 FTPSource 丢弃连接、下次操作懒重连（对齐 SFTPSource 的 closeConnection 语义）。
final class FTPControlConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let parser = FTPReplyParser()
    private let lock = NSLock()
    private var closed = false

    init(conn: NWConnection) { self.conn = conn }

    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    /// 建连（含 TLS 握手）。ready 前服务器不发 220。
    func start(timeout: TimeInterval) async throws {
        try await FTPTask.withTimeout(timeout) {
            let c = self.conn
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let box = ResumeBox(k)
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.resume { }
                    case .failed(let e): self.markClosed(); box.resume(throwing: FTPClientError.connectFailed(String(describing: e)))
                    case .cancelled: self.markClosed(); box.resume(throwing: FTPClientError.closed)
                    default: break
                    }
                }
                // 铁律：只传预建系统队列，绝不动态创建 DispatchQueue。
                c.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    func close() {
        markClosed()
        conn.cancel()
    }

    private func markClosed() {
        lock.lock(); closed = true; lock.unlock()
    }

    // MARK: 命令 / 应答

    /// 发命令并等一条完整应答。
    /// 超时后协议流位置不可知（服务器可能稍后才把应答吐完，解析器里可能留着半条）
    /// → 一律标死连接，由 FTPSource 丢弃并在下次操作懒重连（对齐 SFTPSource 语义）。
    func command(_ line: String, timeout: TimeInterval) async throws -> FTPReply {
        do {
            return try await FTPTask.withTimeout(timeout) {
                try await self.commandInner(line)
            }
        } catch let e as FTPClientError {
            if case .timeout = e { markClosed() }
            throw e
        }
    }

    /// 不发命令，只等一条应答（登录前的 220、传输完成后的 226）。
    /// nil = 对端在应答之前关闭了控制连接。
    func reply(timeout: TimeInterval) async throws -> FTPReply? {
        do {
            return try await FTPTask.withTimeout(timeout) {
                try await self.readReplyInner()
            }
        } catch let e as FTPClientError {
            if case .timeout = e { markClosed() }
            throw e
        }
    }

    private func commandInner(_ line: String) async throws -> FTPReply {
        if isClosed { throw FTPClientError.closed }
        try await write(Data((line + "\r\n").utf8))
        guard let r = try await readReplyInner() else { throw FTPClientError.closed }
        return r
    }

    /// 从解析器/网络取一条应答。**唯一**的 receive 驱动路径。
    /// nil = 对端关闭（调用方按语义决定 throw 还是容忍）。
    private func readReplyInner() async throws -> FTPReply? {
        while true {
            lock.lock()
            let buffered = parser.nextReply()
            lock.unlock()
            if let r = buffered { return r }
            guard let chunk = try await receiveChunk() else { return nil }
            lock.lock(); parser.append(chunk); lock.unlock()
        }
    }

    /// 一次 receive。空且 isComplete → nil（EOF）。
    private func receiveChunk() async throws -> Data? {
        if isClosed { throw FTPClientError.closed }
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
            let box = ResumeBox(k)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    self.markClosed()
                    box.resume(throwing: FTPClientError.closed)
                    return
                }
                if let data, !data.isEmpty { box.resume { data }; return }
                if isComplete {
                    self.markClosed()
                    box.resume { nil }
                    return
                }
                // 空块非 EOF：继续等（重新挂一次 receive）
                self.receiveRetry(box)
            }
        }
    }

    private func receiveRetry(_ box: ResumeBox<Data?>) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error { self.markClosed(); box.resume(throwing: FTPClientError.closed); return }
            if let data, !data.isEmpty { box.resume { data }; return }
            if isComplete { self.markClosed(); box.resume { nil }; return }
            self.receiveRetry(box)
        }
    }

    private func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let box = ResumeBox(k)
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { self.markClosed(); box.resume(throwing: FTPClientError.closed) }
                else { box.resume { } }
            })
        }
    }
}

// MARK: - 数据连接

/// 数据连接（PASV/EPSV 目标）。每操作一个实例，读完/写完即 cancel。
final class FTPDataConnection: @unchecked Sendable {
    private let conn: NWConnection
    private let lock = NSLock()
    private var buffer = Data()
    private var eof = false
    private var closed = false

    init(conn: NWConnection) { self.conn = conn }

    func start(timeout: TimeInterval) async throws {
        try await FTPTask.withTimeout(timeout) {
            let c = self.conn
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let box = ResumeBox(k)
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: box.resume { }
                    case .failed(let e): box.resume(throwing: FTPClientError.dataConnectFailed(String(describing: e)))
                    case .cancelled: box.resume(throwing: FTPClientError.closed)
                    default: break
                    }
                }
                c.start(queue: .global(qos: .userInitiated))
            }
        }
    }

    /// 读至多 want 字节；EOF → nil。
    func read(want: Int, timeout: TimeInterval) async throws -> Data? {
        try await FTPTask.withTimeout(timeout) {
            try await self.readInner(want: want)
        }
    }

    private func readInner(want: Int) async throws -> Data? {
        lock.lock()
        if !buffer.isEmpty {
            let n = min(want, buffer.count)
            let out = buffer.subdata(in: 0..<n)
            buffer.removeFirst(n)
            lock.unlock()
            return out
        }
        if eof { lock.unlock(); return nil }
        lock.unlock()

        let chunk: Data? = try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data?, Error>) in
            let box = ResumeBox(k)
            self.pump(box)
        }
        guard let chunk, !chunk.isEmpty else { return nil }
        if chunk.count > want {
            lock.lock()
            buffer.insert(contentsOf: chunk.suffix(chunk.count - want), at: 0)
            lock.unlock()
            return chunk.prefix(want)
        }
        return chunk
    }

    /// 收一块。空块 + isComplete = EOF。空块非 EOF = 继续等。
    private func pump(_ box: ResumeBox<Data?>) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { box.resume { nil }; return }
            if let error { box.resume(throwing: FTPClientError.dataConnectFailed(String(describing: error))); return }
            if let data, !data.isEmpty { box.resume { data }; return }
            if isComplete {
                self.lock.lock(); self.eof = true; self.lock.unlock()
                box.resume { nil }
                return
            }
            self.pump(box)
        }
    }

    func write(_ data: Data, timeout: TimeInterval) async throws {
        guard !data.isEmpty else { return }
        try await FTPTask.withTimeout(timeout) {
            let c = self.conn
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let box = ResumeBox(k)
                c.send(content: data, completion: .contentProcessed { error in
                    if let error { box.resume(throwing: FTPClientError.dataConnectFailed(String(describing: error))) }
                    else { box.resume { } }
                })
            }
        }
    }

    /// 关闭数据通道。FTP 服务器在**看到数据连接 FIN 之后**才回 226 ——
    /// NWConnection 无半关闭，cancel() 即 FIN，正是上传收尾所需。
    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        conn.cancel()
    }
}

// MARK: - FTPClient

/// RFC 959 客户端（async/await 内核）。
///
/// **本期 TLS 合同：明文 FTP(21) + Implicit FTPS(990，连接即 TLS)。**
/// **Explicit `AUTH TLS`(21 上升级) 本期不做**——NWConnection 没有 startTLS 等价物，
/// TLS 只能在连接创建时挂进协议栈；同 socket 明文→TLS 升级无法表达。要 TLS 请用 990。
public final class FTPClient: @unchecked Sendable {
    public struct Config: Equatable {
        public let host: String
        public let port: UInt16
        public let username: String
        public let password: String?
        /// Implicit FTPS（连接即 TLS）。见类注释关于 Explicit 的说明。
        public let tls: Bool

        public init(host: String, port: UInt16 = 21, username: String,
                    password: String? = nil, tls: Bool = false) {
            self.host = host; self.port = port
            self.username = username; self.password = password; self.tls = tls
        }

        /// 同源判定 id（与 FTPSource.sourceID 一致）：非默认端口才带 :port。
        public var sourceID: String {
            var s = "ftp://\(host)"
            if port != Self.defaultPort(tls: tls) { s += ":\(port)" }
            return s
        }

        public static func defaultPort(tls: Bool) -> UInt16 { tls ? 990 : 21 }

        /// 凭据账号（Keychain 键），与 SFTP 同构。
        public var credentialAccount: String { "\(host):\(port):\(username)" }
    }

    public let config: Config
    public private(set) var features: Set<String> = []
    public private(set) var utf8On = false

    let control: FTPControlConnection
    /// 控制/数据超时（合同 15s）
    static let controlTimeout: TimeInterval = 15
    static let dataTimeout: TimeInterval = 15

    init(config: Config, control: FTPControlConnection) {
        self.config = config
        self.control = control
    }

    var supportsMlsd: Bool { features.contains("mlsd") }

    // MARK: 建连 + 登录

    static func connect(_ config: Config) async throws -> FTPClient {
        let nw = NWConnection(host: NWEndpoint.Host(config.host),
                              port: NWEndpoint.Port(rawValue: config.port) ?? NWEndpoint.Port(rawValue: Config.defaultPort(tls: config.tls))!,
                              using: parameters(tls: config.tls))
        let ctrl = FTPControlConnection(conn: nw)
        let client = FTPClient(config: config, control: ctrl)
        do {
            try await ctrl.start(timeout: controlTimeout)
            try await client.login()
        } catch {
            ctrl.close()
            throw error
        }
        return client
    }

    /// TLS 参数。
    ///
    /// **关闭证书校验**：FTP 服务器大量使用自签名证书，且本仓库 SFTP 侧同样是
    /// TOFU 不阻断（SFTPHostKeyStore 首见即信任），安全水位对齐。
    /// 本 SDK 已探针确认**无** `NWProtocolTLS.Options.peerCertificateVerificationMode`
    /// 也无 `evaluationCompleteHandler`（两者均编译不过）；可用写法只有 C 层
    /// `sec_protocol_options_set_verify_block`，且其 done 回调是**单参数 Bool**
    /// （`sec_trust_result_t`/`sec_trust_result_type_t` 在本 SDK 不可见）。
    static func parameters(tls: Bool) -> NWParameters {
        guard tls else { return .tcp }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, _, done in
            done(true)          // 恒 proceed（等价 disabled 校验）
        }, DispatchQueue.global(qos: .userInitiated))
        let p = NWParameters.tcp
        p.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return p
    }

    /// 220 → USER → (331 → PASS) → 230 → FEAT → UTF8 ON → TYPE I。
    private func login() async throws {
        guard let hello = try await control.reply(timeout: Self.controlTimeout) else {
            throw FTPClientError.closed
        }
        guard hello.code == 220 else {
            // 421 = 服务器即将关闭（服务不可用）
            throw FTPClientError.unexpectedReply(code: hello.code, message: hello.message)
        }
        let user = config.username.isEmpty ? "anonymous" : config.username
        var r = try await control.command("USER \(user)", timeout: Self.controlTimeout)
        if r.code == 230 { try await negotiate(); return }        // 免密
        try r.expectOneOf([331, 332], command: "USER")
        var pass = config.password ?? ""
        if user == "anonymous", pass.isEmpty { pass = "ftp@example.invalid" }   // 匿名惯例填邮箱
        r = try await control.command("PASS \(pass)", timeout: Self.controlTimeout)
        if r.code == 530 { throw FTPClientError.authRejected("password") }
        try r.expect(230, command: "PASS")
        try await negotiate()
    }

    /// 登录后能力协商。FEAT/UTF8 失败容忍；TYPE I 必须成功（尺寸/字节校验依赖二进制模式）。
    private func negotiate() async throws {
        if let feat = try? await control.command("FEAT", timeout: Self.controlTimeout), feat.code == 211 {
            for line in feat.lines {
                // 多行 FEAT 的能力行以空格缩进；末行 "211 End" 亦无害
                for token in line.split(separator: " ") where token.count >= 2 {
                    features.insert(String(token).lowercased())
                }
            }
        }
        if let r = try? await control.command("UTF8 ON", timeout: Self.controlTimeout),
           r.code == 200 || r.code == 202 { utf8On = true }
        let t = try await control.command("TYPE I", timeout: Self.controlTimeout)
        try t.expect(200, command: "TYPE")
    }

    // MARK: - 命令面

    func pwd() async throws -> String {
        let r = try await control.command("PWD", timeout: Self.controlTimeout)
        try r.expect(257, command: "PWD")
        return Self.unquotePath(r.message)
    }

    func changeDirectory(_ path: String) async throws {
        let r = try await control.command("CWD \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expectOneOf([250, 257], command: "CWD")
    }

    /// SIZE：文件 → 字节数；目录 → 550（FTPSource 的 isDirectory 判据）。
    func size(_ path: String) async throws -> Int64 {
        let r = try await control.command("SIZE \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expect(213, command: "SIZE")
        guard let n = Int64(r.message.dropFirst(3).trimmingCharacters(in: .whitespaces)) else {
            throw FTPClientError.unexpectedReply(code: r.code, message: r.message)
        }
        return n
    }

    /// MDTM（213 应答，与 SIZE 同码）。
    func modificationTime(_ path: String) async throws -> Date? {
        let r = try await control.command("MDTM \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expect(213, command: "MDTM")
        return FTPDate.parseTimestamp(r.message.dropFirst(3).trimmingCharacters(in: .whitespaces))
    }

    /// MLST：单条目权威事实（stat 最优路径）。550 → nil（不存在）。
    ///
    /// 应答码同时接受 **250 与 257**：RFC 3659 §7.2 规定 MLST 用 250
    /// （`250-` + 条目 + `250`），但大量实现（含本仓库 fixture）回 257。
    /// 只认 257 会让符合 RFC 的服务器 stat 抛错 → 「双击目录没反应」。
    func mlst(_ path: String) async throws -> FTPListEntry? {
        let r = try await control.command("MLST \(try Self.arg(path))", timeout: Self.controlTimeout)
        if r.code == 550 { return nil }
        try r.expectOneOf([250, 257], command: "MLST")
        for line in r.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let e = FTPListParser.parseMlsdLine(trimmed) { return e }
        }
        return nil
    }

    func makeDirectory(_ path: String) async throws {
        let r = try await control.command("MKD \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expect(257, command: "MKD")
    }

    func removeDirectory(_ path: String) async throws {
        let r = try await control.command("RMD \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expect(250, command: "RMD")
    }

    func deleteFile(_ path: String) async throws {
        let r = try await control.command("DELE \(try Self.arg(path))", timeout: Self.controlTimeout)
        try r.expect(250, command: "DELE")
    }

    func rename(from: String, to: String) async throws {
        let fr = try await control.command("RNFR \(try Self.arg(from))", timeout: Self.controlTimeout)
        try fr.expect(350, command: "RNFR")
        let tr = try await control.command("RNTO \(try Self.arg(to))", timeout: Self.controlTimeout)
        try tr.expect(250, command: "RNTO")
    }

    func quit() async throws {
        _ = try? await control.command("QUIT", timeout: 3)
    }

    // MARK: - 列表（MLSD 优先，LIST 回退）

    /// 返回条目（不含 "."/".."）。
    func list(_ path: String) async throws -> [FTPListEntry] {
        // 服务器没报 FEAT 时也试一次 MLSD（有些实现不声明却支持）；
        // 500/502/550（命令不认识/无此能力）→ LIST 回退。
        do {
            return try await mlsd(path)
        } catch let e as FTPClientError {
            guard let code = e.replyCode, code == 500 || code == 502 || code == 501 else { throw e }
        }
        let text = try await listText(path)
        return FTPListParser.parseList(text, now: Date(), timeZone: .current)
    }

    func mlsd(_ path: String) async throws -> [FTPListEntry] {
        let text = try await downloadText(command: "MLSD \(try Self.arg(path))")
        return FTPListParser.parseMlsd(text)
    }

    func listText(_ path: String) async throws -> String {
        try await downloadText(command: "LIST \(try Self.arg(path))")
    }

    // MARK: - 数据通道

    /// 开数据通道 → 发命令 → 收到 EOF → 关数据通道 → 收完成哨（226/250）。
    /// LIST/MLSD 用此路径（小结果，一次读尽）。
    private func downloadText(command: String) async throws -> String {
        let data = try await openDataConnection()
        defer { data.close() }
        let r = try await control.command(command, timeout: Self.controlTimeout)
        try r.expectOneOf([150, 125], command: command)
        var out = Data()
        while let chunk = try await data.read(want: 64 * 1024, timeout: Self.dataTimeout) {
            out.append(chunk)
        }
        data.close()
        try await expectTransferComplete()
        return String(decoding: out, as: UTF8.self)
    }

    /// RETR 流式读句柄（**async** 形态）：数据通道随句柄存活；EOF 时关数据通道并收 226。
    /// 交给 FTPConnection 逐块桥成同步 ReadHandle——桥只有一层，
    /// 绝不在 async 上下文里调 awaitBlocking（会占死 cooperative 线程）。
    ///
    /// **完整性以 SIZE 为权威**（F1）：226 只表示「服务器自认为发完」，不表示客户端收全
    /// （服务端中途 RST / 慢链路超时后仍可能回 226）。收哨后 `bytesRead != expected` → 抛错，
    /// 绝不返回 nil=EOF 让调用方写出半截文件还报成功。SIZE 拿不到（服务器无 SIZE/竞态）
    /// 时 expected=nil，退回旧行为（以 226 为准）。
    func openReader(_ path: String, state: FTPReadState) async throws -> FTPAsyncReadHandle {
        let data = try await openDataConnection()
        do {
            let r = try await control.command("RETR \(try Self.arg(path))", timeout: Self.controlTimeout)
            try r.expectOneOf([125, 150], command: "RETR")
        } catch {
            data.close()
            throw error
        }
        let control = self.control
        state.transferStarted = true
        let dataTimeout = Self.dataTimeout
        return { want in
            guard !state.done else { return nil }
            let n = max(1, want > 0 ? want : 64 * 1024)
            do {
                guard let chunk = try await data.read(want: n, timeout: dataTimeout) else {
                    // 数据 EOF（对端 FIN 后回 226）：关通道、排干完成哨并核对字节数，交回 nil。
                    // 排干是**必须**的：226 若留在共享控制连接上，下一条命令会读到它 →
                    // 全局错位（RETR→226、MLST→PASV 应答……整条会话崩）。
                    try await self.finishRead(data: data, control: control, state: state,
                                              counted: nil, timeout: dataTimeout)
                    return nil
                }
                state.count += Int64(chunk.count)
                return chunk
            } catch {
                // 数据通道以 error 收尾（服务器 cancel 数据连接常产生 RST/POSIX 96，
                // 而非干净 FIN），或 finishRead 自己判定出截断。两种都必须排干共享控制连接
                // 上的完成哨（否则毒化整条会话），再决定上抛什么：
                // - 判定出截断 → 上抛截断错（SIZE 权威结论，盖过收尾噪声）；
                // - 排到 226/250 且字节数等于 SIZE（无 SIZE 则不可判）→ error 只是收尾
                //   噪声，按 EOF；
                // - 其余 = 真失败，上抛原错误。
                try? await self.finishRead(data: data, control: control, state: state,
                                           counted: nil, timeout: dataTimeout)
                if let expected = state.truncatedBy {
                    throw FTPTransferTruncatedError(received: state.count, expected: expected)
                }
                if state.confirmedComplete, state.expected == nil || state.count == state.expected {
                    return nil
                }
                throw error
            }
        }
    }

    /// RETR 读句柄的**唯一**终止收尾：关数据通道 → 排干完成哨（226/250）→ **核对字节数**（F1）。
    /// 完成哨排到但收不满 SIZE 预期 → 抛 FTPTransferTruncatedError（226 只表示「服务器自认
    /// 为发完」，不表示客户端收全）。幂等：state.done 已置 → 不双排干，直接沿用首次判定。
    private func finishRead(data: FTPDataConnection, control: FTPControlConnection,
                            state: FTPReadState, counted: Data?,
                            timeout: TimeInterval) async throws {
        if state.done {
            if let c = state.truncatedBy { throw FTPTransferTruncatedError(received: state.count,
                                                                           expected: c) }
            return
        }
        state.done = true
        if let counted { state.count += Int64(counted.count) }
        data.close()
        // 排干本身的异常（连接已死/超时）= 没排到完成哨 → 未完成。
        state.confirmedComplete = ((try? await control.reply(timeout: timeout))?.code).map { $0 == 226 || $0 == 250 } ?? false
        // 权威判据是**字节数**（F1）：收不满 SIZE 预期就是截断，与有没有排到 226 无关。
        guard let expected = state.expected, state.count != expected else { return }
        state.truncatedBy = expected
        throw FTPTransferTruncatedError(received: state.count, expected: expected)
    }

    /// STOR 流式写：write 闭包返回空 Data 结束 → 关数据通道（=FIN，服务器据此发 226）→ 收哨。
    func streamWrite(_ path: String, write: @escaping () throws -> Data) async throws {
        let data = try await openDataConnection()
        defer { data.close() }
        do {
            let r = try await control.command("STOR \(try Self.arg(path))", timeout: Self.controlTimeout)
            try r.expectOneOf([125, 150], command: "STOR")
            while true {
                let chunk = try write()
                if chunk.isEmpty { break }
                try await data.write(chunk, timeout: Self.dataTimeout)
            }
        } catch {
            data.close()
            throw error     // 原样上抛，FTPSource 统一映射
        }
        data.close()
        try await expectTransferComplete()
    }

    /// 226（传输完成）/ 250（部分实现）。
    ///
    /// 控制连接 nil/EOF **不再当成功**（F1 同族问题）：协议规定完成哨先于控制连接关闭
    /// （RFC 959），没排到哨 = 无法确认服务器收完/发完 → 上抛 .closed（dropIfDead 见
    /// closed 即丢连接，下次懒重连），而不是静默「完成」。
    private func expectTransferComplete() async throws {
        guard let r = try await control.reply(timeout: Self.controlTimeout) else {
            throw FTPClientError.closed
        }
        guard r.code == 226 || r.code == 250 else {
            throw FTPClientError.unexpectedReply(code: r.code, message: r.message)
        }
    }

    /// PASV（EPSV 后备）+ 连上数据端口。
    private func openDataConnection() async throws -> FTPDataConnection {
        let endpoint = try await passiveEndpoint()
        let nw = NWConnection(host: NWEndpoint.Host(endpoint.host),
                              port: NWEndpoint.Port(rawValue: endpoint.port) ?? 0,
                              using: Self.parameters(tls: config.tls))
        let data = FTPDataConnection(conn: nw)
        do {
            try await data.start(timeout: Self.dataTimeout)
        } catch {
            data.close()
            throw error
        }
        return data
    }

    private func passiveEndpoint() async throws -> FTPDataEndpoint {
        if features.contains("epsv") {
            if let r = try? await control.command("EPSV", timeout: Self.controlTimeout), r.code == 229,
               let ep = FTPPasv.parseEpsv(r, fallbackHost: config.host) {
                return ep
            }
        }
        let r = try await control.command("PASV", timeout: Self.controlTimeout)
        try r.expect(227, command: "PASV")
        guard let ep = FTPPasv.parse(r, fallbackHost: config.host) else {
            throw FTPClientError.malformedReply(r.message)
        }
        return ep
    }

    // MARK: - 纯文本处理（可单测）

    /// `"257 "/a/b/c" is the current directory"` → `/a/b/c`。
    /// 路径内的 `"` 按 RFC 959 转义成 `""`。
    static func unquotePath(_ line: String) -> String {
        guard let first = line.firstIndex(of: "\"") else { return line }
        let after = line.index(after: first)
        guard let last = line[after...].lastIndex(of: "\""), last >= after else { return line }
        let inner = String(line[after..<last])
        return inner.replacingOccurrences(of: "\"\"", with: "\"")
    }

    /// FTP 行协议整行即参数（不加 shell 式引号）。CR/LF 会截断命令、且协议无法转义
    /// → 抛 invalidPath 拒绝发送。**绝不**替换成空格：那等于对另一个（可能存在的）
    /// 路径执行删除/改名，而 UI 显示的是原路径。
    static func arg(_ s: String) throws -> String {
        if s.contains(where: { $0 == "\r" || $0 == "\n" }) { throw FTPClientError.invalidPath }
        return s
    }
}

/// RETR 句柄状态（同 ReadCursor 先例：类盒，上层锁内使用）。
/// expected = SIZE 权威预期字节（nil=服务器无 SIZE/取不到 → 不做字节校验）；
/// transferStarted = RETR 已被 150/125 接受（此后弃用会在控制连接上滞留 226）；
/// confirmedComplete = 排到了 226/250。
final class FTPReadState: @unchecked Sendable {
    var done = false
    var count: Int64 = 0
    var expected: Int64?
    var transferStarted = false
    var confirmedComplete = false
    /// 首次收尾判定出的截断（幂等重入时复述同一结论）。
    var truncatedBy: Int64?
    init(expected: Int64?) { self.expected = expected }
}

/// 传输截断：服务器回了完成哨（226/250）但客户端收到的字节 < SIZE 预期。
/// **不是** FTPClientError（不走 ftpmappedTCError 的码号分支），单独前置判定后落
/// `TCError.ftpTransferTruncated`，与「主体不存在」550、「数据连接失败」明确区分。
struct FTPTransferTruncatedError: Error {
    let received: Int64
    let expected: Int64
}

/// async 读句柄（FTPClient 产出，FTPConnection 桥成 TCCore 的同步 ReadHandle）。
typealias FTPAsyncReadHandle = (Int) async throws -> Data?

// MARK: - 连接（async→sync 桥 + 串行锁）

/// FTPClient 的薄封装：串行化 + async→sync 桥。
///
/// 并发设计逐字对齐 SFTPConnection：
/// - 全程 **NSLock，绝不创建 DispatchQueue**（本环境 Swift Concurrency 启动后建队列会
///   在泛型元数据缓存段错误）。
/// - 桥接只用 `Task + DispatchSemaphore`（C API，无泛型元数据）。awaitBlocking 已在
///   SFTPClient.swift 定义并全 target 可见，这里直接复用。
/// - 主线程调用会冻结 runloop：应用侧一律走后台队列，仅测试允许主线程。
final class FTPConnection: @unchecked Sendable {
    let config: FTPClient.Config
    private let lock = NSLock()
    private var client: FTPClient?

    init(config: FTPClient.Config) {
        self.config = config
    }

    var sourceID: String { config.sourceID }

    /// MLSD 可用性（连接级缓存）：MLST/LIST 撞 500/502（命令不认识）后置 false，
    /// 本连接生命周期内不再试。FTPSource.stat 的降级链用。
    var mlsdUsable = true

    /// 懒建连（同 SFTPSource.conn()）：首次操作时连接并复用；
    /// 断开（closeConnection / 连接被标死）后下次操作重连。
    /// `performSync` 内串行，故同一时刻只有一个在途 client。
    private func currentClient() throws -> FTPClient {
        lock.lock()
        // 控制连接已被标死（传输被弃用/取消 → release() 关掉了它）→ 视同无 client，
        // 静默重连。否则下次操作要先撞一次 .closed 才触发 dropIfDead，
        // 用户会看到一条莫名的「FTP 连接已关闭」。
        if let c = client, !c.control.isClosed { lock.unlock(); return c }
        client = nil
        lock.unlock()
        // 建连在锁外（可能几十秒），避免互相阻塞；竞态由下面 CAS 收敛。
        let fresh = try awaitBlocking { try await FTPClient.connect(self.config) }
        lock.lock()
        if let existing = client { lock.unlock(); Task { try? await fresh.quit() }; return existing }
        client = fresh
        lock.unlock()
        return fresh
    }

    /// 串行执行一个 async 操作。**全程持锁**（对齐 SFTPConnection.performSync）：
    /// FTP 只有一条控制连接，无法像 SFTP 那样多路复用——命令与它的应答之间被别的
    /// 命令插进来就错位（实证：跨源下载时 ⌘R 刷新 → unexpectedReply 226/150/超时）。
    /// 出错时判定连接是否已死（超时/关闭 → 丢弃，下次重连）。
    func performSync<T>(_ op: @escaping @Sendable (FTPClient) async throws -> T) throws -> T {
        let c = try currentClient()
        lock.lock()
        do {
            let r = try awaitBlocking { try await op(c) }
            lock.unlock()
            return r
        } catch {
            // 先放锁再判定丢弃：NSLock 非递归，持锁调 dropClient 会自锁。
            lock.unlock()
            dropIfDead(c, error: error)
            throw error
        }
    }

    /// 连接不可复用（超时/关闭/截断）→ 丢弃，下次操作懒重连。
    /// 服务器语义错误（550/530 等）**不**丢连接——控制流仍完好。
    fileprivate func dropIfDead(_ c: FTPClient, error: Error) {
        guard !keepsConnection(error) else { return }
        dropClient(c)
    }

    /// 出错后控制连接是否**仍可用**。
    /// 判据是「应答槽里的码号是不是服务器对**命令**的正常否定应答」：
    /// - 4xx/5xx = 服务器答了这条命令 → 位置正确，留着；
    /// - **2xx**（226/227/150…）= 上一条传输的哨被当成应答读走了 = 会话已错位 → 丢；
    /// - 非 FTPClientError（如泵送里 write 闭包抛的 TCError.cancelled、截断错）= 传输
    ///   被半途中止，数据连接已 FIN，服务器随后发的 226 一定还滞留在控制连接上 → 丢。
    ///   （实证：取消一次 STOR 后同连接后续操作连吃 226 → 227 → 425，三次不自愈。）
    /// 一律「丢=下次懒重连」，比留着一条位置已错位的连接便宜。
    private func keepsConnection(_ error: Error) -> Bool {
        guard let e = error as? FTPClientError else { return false }
        switch e {
        case .unexpectedReply(let code, _):
            // 4xx/5xx = 服务器对这条命令的正常否定应答 → 位置正确；2xx = 传输哨被读走 → 丢。
            return code >= 400
        case .invalidPath, .malformedReply:
            // 命令未发出/应答未消费：控制流位置不变 → 留着。
            return true
        case .authRejected:
            // 登录被拒：控制流干净（服务器完整答完 530），留着没害处，
            // 且丢了会让「重试密码」每次都重付一次 TCP/TLS 握手。
            return true
        default:
            // 超时/关闭/连接失败/数据通道失败/malformedReply，以及一切非 FTPClientError
            return false
        }
    }

    /// 丢弃指定 client（仅当它仍是当前 client）并关闭其控制连接。
    fileprivate func dropClient(_ c: FTPClient) {
        lock.lock()
        if client === c { client = nil }
        lock.unlock()
        c.control.close()
    }

    /// 主动断开（**下次操作懒重连**，对齐 SFTPSource.closeConnection）。
    ///
    /// 只丢弃内层 client，**不**置永久 closed 标志：FTPSource 以 `let conn` 持有本对象，
    /// closeConnection 语义是「断开但可复用」——下次 currentClient() 见 client 为 nil 即重建
    /// （与 SFTPSource `_connection = nil` 后下次 conn() 新建完全同构）。
    func close() {
        lock.lock()
        guard let c = client else { lock.unlock(); return }
        client = nil
        lock.unlock()
        Task {
            try? await c.quit()
            c.control.close()
        }
    }

    deinit {
        close()
    }

    // MARK: 传输独占租约（openReader 用）

    /// 取一条「整段传输独占控制连接」的租约。
    /// 建连在锁外（可能几十秒），拿到 client 之后才锁——建连期间不阻塞别人。
    fileprivate func acquireTransferLease() throws -> FTPReadLease {
        let c = try currentClient()
        lock.lock()
        return FTPReadLease(lock: lock, client: c, onAbandon: { [weak self] in self?.dropClient(c) })
    }
}

/// openReader 期间的控制连接独占锁（形态照 streamWrite 的「泵送整程持锁」）。
///
/// 为什么必须整程：FTP 一条控制连接**不能**多路复用。RETR 发出后它的完成哨（226）
/// 排在控制流上，期间任何别的命令（窗格 ⌘R 的 listDirectory/stat）都会把 226 当成
/// 自己的应答读走 → 会话整体错位（实证：下载中按 ⌘R → unexpectedReply 226/150/15s 超时）。
/// SFTP 没这问题（多路复用），所以那边只按块持锁。
///
/// 释放点三处：句柄读到 EOF、句柄抛错、**句柄被弃用**（取消下载/预览切走——调用方不再
/// 调它，前两者永不发生）。第三条靠 deinit 兜底：NSLock 无超时，锁悬着 = 整条连接死锁。
private final class FTPReadLease: @unchecked Sendable {
    private let lock: NSLock
    let client: FTPClient
    /// 未收尾就释放时丢弃连接（置 nil + 关控制连接），下次操作**静默**重连。
    private let onAbandon: () -> Void
    /// 本次读的状态盒；release 时若尚未收尾 = 被弃用 → 控制连接上可能滞留 226，标死。
    var state: FTPReadState?
    private var held = true

    init(lock: NSLock, client: FTPClient, onAbandon: @escaping () -> Void) {
        self.lock = lock
        self.client = client
        self.onAbandon = onAbandon
        // 锁已由 acquireTransferLease 持上
    }

    func release() {
        guard held else { return }
        held = false
        // 未收尾就被释放（弃用）：数据连接随句柄一起消亡 → 服务器看见 FIN 后发 226，
        // 这条 226 会滞留在共享控制连接上，被下一条命令读成它的应答（实证：取消后
        // 连续 3 次 unexpectedReply 226/227/425）。排干来不及（226 可能还没到），
        // 直接标死控制连接，下次操作懒重连。
        let abandoned = (state != nil) && state!.transferStarted && !state!.done
        lock.unlock()
        // dropClient 自己要拿锁 → 必须先 release 再 abandon，否则自锁（NSLock 非递归）。
        if abandoned { onAbandon() }
    }

    deinit { release() }
}

// MARK: - 流式桥接（openReader / streamWrite）

extension FTPConnection {
    /// 打开读句柄并桥成同步闭包（形态照 SFTPConnection.openReader）。
    ///
    /// 与 SFTP 的关键差异：FTP 单控制连接不能多路复用，故**整段传输独占一把锁**
    /// （FTPReadLease），而不是每块各持一次——每块各持一次正允许 ⌘R 的 listDirectory
    /// 插进 RETR 与它的 226 之间（实证毒化会话）。句柄收尾（EOF/抛错）或随调用方弃用
    /// （deinit）时释放租约。SIZE 预期字节在**锁内**取（F1：以 SIZE 为权威）。
    func openReader(_ path: String) throws -> ReadHandle {
        let lease = try acquireTransferLease()
        let handle = FTPReadState(expected: nil)
        lease.state = handle
        do {
            // 锁内取 SIZE（expected），失败（无 SIZE/竞态）→ nil = 不做字节校验。
            handle.expected = try? awaitBlocking { try await lease.client.size(path) }
            let asyncHandle: FTPAsyncReadHandle =
                try awaitBlocking { try await lease.client.openReader(path, state: handle) }
            return { want in
                do {
                    let chunk = try awaitBlocking { try await asyncHandle(want) }
                    if chunk == nil { lease.release() }   // EOF：收尾完成，还锁
                    return chunk
                } catch {
                    lease.release()                       // 抛错：收尾完成，还锁
                    throw error
                }
            }
        } catch {
            lease.release()
            dropIfDead(lease.client, error: error)   // 同 performSync：超时/关闭类错误丢连接
            throw error
        }
    }

    /// 流式写（泵送期间整程持锁，对齐 SFTPConnection.streamWrite）。
    func streamWrite(_ path: String, totalBytes: Int64?,
                     write: @escaping () throws -> Data) throws {
        let c = try currentClient()
        lock.lock()
        do {
            try awaitBlocking { try await c.streamWrite(path, write: write) }
            lock.unlock()
        } catch {
            // 先放锁再判定丢弃（NSLock 非递归，持锁调 dropClient 自锁）。
            lock.unlock()
            dropIfDead(c, error: error)
            throw error     // 原样上抛，FTPSource 统一映射为 TCError
        }
    }
}
