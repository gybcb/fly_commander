import Foundation

/// 跨机直传的纯函数面：rsync 命令构造 + 失败分类 + `--progress` 输出解析。
/// 全部无 IO 无线程——e2e 之外的行为都锁在这层。
///
/// 命令规格（spec §2，三轮修订）：**只用 --progress，绝不用 --info**——macOS 自带
/// openrsync（协议 29）不认 --info=progress2/--info=name（实测 unrecognized option），
/// GNU rsync ≥3.1 才认；`-a --progress` 两方言通吃且无 tty 也输出。
/// `-oBatchMode=yes`：源机→目标机需要口令/首次指纹 → 立即失败不挂起 → 回退。
enum DirectRsync {
    /// dstPath = **完整目标路径**（非父目录）——接缝收到的 destDir 即 destDir.joining(name)
    /// 已是全路径（Task 1 testSeamReceivesJoinedDest 锁死），此处不得再拼一次名。
    /// isDirectory 只决定 src/dst 尾斜杠（源尾斜杠=拷内容不嵌套）。
    struct ItemTarget {
        let remotePath: String
        let dstPath: String
        let isDirectory: Bool
    }
    struct Peer { let host: String; let port: UInt16; let username: String }
    // **Peer 故意没有 auth/密码字段**：直传只认 A→B 密钥信任，密码绝不入命令行。

    static func command(item: ItemTarget, peer: Peer) -> String {
        let portPart = peer.port == 22 ? "" : " -p \(peer.port)"
        let slash = item.isDirectory ? "/" : ""
        let src = item.remotePath + slash
        let dst = item.dstPath + slash
        // user@host: 前缀裸露，仅冒号后路径 shellQuote（远端 ssh 在 B 上再解一层引用）。
        let dstURI = "\(peer.username)@\(peer.host):\(ServerSideCopy.shellQuote(dst))"
        return "rsync -a --progress -e 'ssh -oBatchMode=yes\(portPart)' -- "
            + "\(ServerSideCopy.shellQuote(src)) \(dstURI)"
    }
    // 无 lastPathComponent 重拼 = 无「src 尾斜杠吞掉路径名」类坑（早先草稿在此踩过）。

    /// 失败分类表（spec §2）：与 ServerSideCopy.classify 同形状、不同表。
    /// needsAuth 串集：ssh/rsync 对「认证不过/连不上对端」的原话。
    static func classify(exitStatus: UInt32?, stderr: String) -> ServerSideCopy.Result {
        guard let status = exitStatus else { return .relay(.channelGone) }
        if status == 0 { return .ok }
        if status == 127 { return .relay(.rsyncMissing) }
        let msg = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if msg.isEmpty { return .relay(.channelGone) }
        let authMarks = ["Permission denied", "Host key verification failed",
                         "Connection refused", "Could not resolve hostname"]
        if authMarks.contains(where: msg.contains) { return .relay(.needsAuth) }
        return .fail(msg)   // 真失败：带 stderr 上抛不回退（cp 同政策）
    }

    /// 字节帧的**范围**判定（纯函数，终审 B2 裁定：接缝 byteProgress 合同 = spec §1
    /// 「(本条目已传, 本条目总量)，0=未知」，逐条目严格）：
    /// - 单文件条目：总量 = totalHint（= item.size）→ 定量帧；
    /// - 目录条目：无预扫描、总量先天未知 → total 恒 0（不定量，面板扫动态）。
    /// 旧实现拿 parser.fileBytesTotal（**当前文件**的总量）当条目分母 + 引擎再叠
    /// 跨条目基线 → done>total 稳态、面板恒 100%（终审实测）。
    /// 字节帧 = (done, total)，Equatable 便于锁。
    struct Frame: Equatable { let done: Int64; let total: Int64 }

    static func progressFrame(isDirectory: Bool, entryDone: Int64,
                              totalHint: Int64?) -> Frame {
        if isDirectory { return Frame(done: entryDone, total: 0) }
        let hint = totalHint ?? 0
        guard hint > 0 else { return Frame(done: entryDone, total: 0) }     // size 拿不到 → 不定量
        return Frame(done: min(entryDone, hint), total: hint)
    }
}

/// `rsync -a --progress` stderr 解析器（openrsync/GNU 双方言）。
/// 行形态（实测样例见 DirectRsyncTests）：文件名行 + `<done> [total] <pct>% <rate>
/// <eta> (xfer#N, to-check=i/T)` 行。喂文本（可半行），事件回调。
///
/// 拍板规则：
/// - 首字段纯数字 = 数值行；否则当文件名挂起。
/// - total：GNU 五字段式 = 第二字段；openrsync 式（done 后直接 pct）= done*100/pct 反推。
///   done/total/pct 三者不一致时信 total（UI 只用百分比，整型够用）。
/// - 尾巴 `(xfer#N, to-check=i/T)`（GNU ≥3.1 印 `xfr#`/`to-chk=`——两种拼写都认，
///   实测差异见 DirectRsyncTests 的 GNU3 样例）：**i = 剩余待检数**（真机收尾行
///   `to-check=0/T`），i==0 → fileDone=T，否则 fileDone=N（xfer 计数）；
///   尾巴缺失 → fileDone/fileTotal 保持前值，不报错。
/// - 累计推进（**幂等**）：完成行（pct==100 或 done>=total）把 done 并进 cumulative，
///   基线是**当前文件已折叠字节**（换文件归零）——真机 openrsync 对 >1s 传输每文件发
///   两条 100% 行（周期刷新行 + 完成行，done 相同），全量累加会把字节翻倍；
///   同名重列（done 更大的完成行）只并差量（1000→1500 并 500，单调不减）。
///   无名字行的换文件边界 = done 回退（rsync 换文件必回退）。
/// - 铁律：**任何解析失败 = 忽略该段文本**，绝不抛错、绝不判传输失败（spec §2）。
final class RsyncProgressParser {
    struct Event { let fileName: String?; let fileBytesDone: Int64
                   let fileBytesTotal: Int64; let fileDone: Int; let fileTotal: Int }
    var onEvent: ((Event) -> Void)?
    private(set) var fileBytesDone: Int64 = 0   // 已完成文件累计 + 当前行 done
    /// 当前文件最新已知字节总量（= Event.fileBytesTotal）。
    private(set) var fileBytesTotal: Int64 = 0
    private(set) var totalKnown = false
    private(set) var fileDone = 0
    private(set) var fileTotal = 0
    /// 进度桥消费本字段拉取「刚被数值行消费掉的文件名」（spec 决策 #2 上抛面板）。
    /// 每次数值行发出且该行带挂起文件名时置值；调用方读取后须置 nil（拉取式）。
    var consumedFileName: String?
    private var tail = ""            // 跨 chunk 半行缓冲
    private var pendingName: String? // 文件名行挂起
    private var cumulative: Int64 = 0      // 已折叠（替换语义）完成字节和
    private var currentCompleted: Int64 = 0   // **当前文件**已折叠字节（换文件归零；替换基线）
    private var currentName: String?          // 最后一条数值行的归属名（换文件边界判定）

    func feed(_ text: String) {
        tail += text
        // rsync 用 \r 原地刷新：\r 与 \n 都是行界，每行当最新态（事件幂等覆盖）。
        var lines = tail.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        tail = lines.removeLast()                 // 末段可能半行，留缓冲
        for line in lines { ingest(line) }
    }

    private func ingest(_ line: String) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return }
        // 数值行判定：首字段是数字。不是 → 当文件名行挂起。
        let fields = t.split(separator: " ", omittingEmptySubsequences: true)
        guard let first = fields.first, first.allSatisfy(\.isNumber),
              let done = Int64(first) else {
            pendingName = t
            return
        }
        // done 后跟 [total] <pct>%：第二字段是纯数字 = GNU total；否则 openrsync 式
        // （done 后直接 <pct>%，total 由 pct 反推）。字段形态认不全 → 忽略该行不抛。
        var total: Int64?
        var percent: Int64?
        if fields.count >= 3, fields[1].allSatisfy(\.isNumber), fields[2].hasSuffix("%"),
           let p = Int64(fields[2].dropLast()) {
            total = Int64(fields[1]); percent = p
        } else if fields.count >= 2, fields[1].hasSuffix("%"),
                  let p = Int64(fields[1].dropLast()) {
            total = p > 0 ? done * 100 / p : done          // openrsync 反推（整型够用）
            percent = p
        } else { return }                                   // 认不全 = 忽略，绝不抛
        // 尾巴（两种方言拼写都认：openrsync `xfer#`/`to-check=`，GNU ≥3.1
        // `xfr#`/`to-chk=`）。**i 是剩余待检数**（真机收尾行 `to-check=0/T`）：
        // i==0 = 全部检完 → fileDone=T；否则取 xfer 计数（已完成传输数）。
        // 尾巴缺失容忍（fileDone/fileTotal 保持前值）。
        var xfer: Int?
        for marker in ["xfer#", "xfr#"] {
            if let xr = t.range(of: marker) {
                xfer = Int(t[xr.upperBound...].prefix(while: { $0.isNumber }))
                break
            }
        }
        for marker in ["to-check=", "to-chk="] {
            guard let tc = t.range(of: marker),
                  let slash = t[tc.upperBound...].firstIndex(of: "/") else { continue }
            let iStr = String(t[tc.upperBound..<slash]).trimmingCharacters(in: .whitespaces)
            let rest = t[t.index(after: slash)...]
            let tStr = String(rest.prefix(while: { $0.isNumber }))
            if let i = Int(iStr), let tot = Int(tStr), tot > 0 {
                fileTotal = tot
                fileDone = i == 0 ? tot : (xfer ?? fileDone)
            }
            break
        }
        // 新文件边界：文件名行且**名字变了** = 新文件（同名重列 = 同文件更大 done，
        // 折叠基线须保留）；无名字行时 done 回退 = 换文件兜底。
        if let pn = pendingName {
            if pn != currentName { currentCompleted = 0 }
            currentName = pn
        } else if done < currentCompleted {
            currentCompleted = 0
        }
        let evTotal = max(total ?? done, done)     // 不一致时信 total；无 total 信 done
        if total != nil { totalKnown = true }
        fileBytesTotal = evTotal                   // 持久态：当前文件总量（消费方 = 进度桥）
        let completing = (percent == 100) || (total.map { done >= $0 } ?? false)
        // 幂等折叠（见头注，替换语义，基线 = 当前文件）：同 done 重复 100% 行增量 0；
        // 同名更大 done 只并差量（1000→1500 并 500）；换文件后基线归零全量并入。
        if completing {
            let delta = max(0, done - currentCompleted)
            cumulative += delta
            currentCompleted = done
        }
        fileBytesDone = cumulative + (completing ? 0 : done)
        let event = Event(fileName: pendingName, fileBytesDone: fileBytesDone,
                          fileBytesTotal: evTotal, fileDone: fileDone, fileTotal: fileTotal)
        consumedFileName = pendingName   // 拉取式上抛面板（见属性注）
        pendingName = nil
        onEvent?(event)
    }
}
