import XCTest
import TCCore
@testable import FlyCommander

/// DirectRsync 纯函数回归：rsync 命令构造、失败分类、`--progress` 输出解析。
/// 全部无 IO 无线程——跨机直传 e2e 之外的行为都锁在这层。
final class DirectRsyncTests: XCTestCase {
    private func peer(_ port: UInt16 = 22) -> DirectRsync.Peer {
        DirectRsync.Peer(host: "10.0.0.2", port: port, username: "bob")
    }

    // MARK: 命令构造（spec §2；变异证伪：删 BatchMode/-p/尾斜杠/quote 任一 → 对应断言红）

    func testCommandFileStandardPort() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/a.txt", dstPath: "/srv2/a.txt", isDirectory: false),
            peer: peer())
        // dstPath 是全路径（接缝传 destDir.joining(name)）；user@host: 前缀裸露，
        // 仅对冒号后的路径 shellQuote（远端 ssh 在 B 上再解一层引用）。
        XCTAssertEqual(cmd,
            #"rsync -a --progress -e 'ssh -oBatchMode=yes' -- '/srv/a.txt' bob@10.0.0.2:'/srv2/a.txt'"#)
    }

    func testCommandDirectoryTrailingSlashes() {
        // 目录：源尾斜杠=拷内容不嵌套（spec 拍板）；目标同样带尾斜杠
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/sub", dstPath: "/srv2/sub", isDirectory: true),
            peer: peer(2222))
        XCTAssertEqual(cmd,
            #"rsync -a --progress -e 'ssh -oBatchMode=yes -p 2222' -- '/srv/sub/' bob@10.0.0.2:'/srv2/sub/'"#)
    }

    func testCommandQuotesEvilPaths() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/srv/it's $(rm -rf /)", dstPath: "/srv2/x", isDirectory: false),
            peer: peer())
        XCTAssertTrue(cmd.contains(#"'/srv/it'\''s $(rm -rf /)'"#), "shellQuote 语义必须生效: \(cmd)")
    }

    /// 密码/凭据绝不入命令行——命令行里除 user@host 外不含 auth 材料（结构性保证：
    /// Peer 根本没有 auth 字段；此锁防未来有人往 Peer 塞密码再拼 -e sshpass）。
    func testNoSecretInCommand() {
        let cmd = DirectRsync.command(
            item: .init(remotePath: "/a", dstPath: "/b", isDirectory: false), peer: peer())
        for needle in ["sshpass", "password"] {
            XCTAssertFalse(cmd.lowercased().contains(needle), "命令行出现 \(needle)：密码泄漏面")
        }
    }

    // MARK: classify（exit/stderr → Result；与 ServerSideCopy.classify 同形状、不同分类表）

    func testClassifyOk() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 0, stderr: ""), .ok)
    }
    func testClassifyRsyncMissing() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 127, stderr: "rsync: command not found"),
                       .relay(.rsyncMissing))
    }
    func testClassifyNeedsAuthPatterns() {
        for s in ["Permission denied (publickey,password).",
                  "Host key verification failed.",
                  "Connection refused",
                  "Could not resolve hostname bogus",
                  "ssh: Could not resolve hostname"] {
            XCTAssertEqual(DirectRsync.classify(exitStatus: 1, stderr: s), .relay(.needsAuth), s)
        }
    }
    func testClassifyGenericFailureNoFallback() {
        // 磁盘满/权限等真失败 → fail 不回退（与同源 cp 政策逐字一致）
        if case .fail = DirectRsync.classify(exitStatus: 1, stderr: "rsync: write failed: No space left on device") { }
        else { XCTFail("应为 .fail") }
    }
    func testClassifyNoExitStatusChannelGone() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: nil, stderr: "x"), .relay(.channelGone))
    }
    func testClassifyEmptyStderrNonZeroChannelGone() {
        XCTAssertEqual(DirectRsync.classify(exitStatus: 1, stderr: "  "), .relay(.channelGone))
    }

    // MARK: --progress 解析器（真机实测样例）

    /// openrsync 实测双行式（macOS 源机，无 tty）：
    func testParserOpenrsyncRealSample() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("a.txt\n              6 100%  390.10KB/s   00:00:00 (xfer#1, to-check=1/2)\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fileName, "a.txt")
        XCTAssertEqual(events[0].fileBytesDone, 6)
        XCTAssertEqual(events[0].fileBytesTotal, 6)   // 100% → done == total
        XCTAssertEqual(events[0].fileDone, 1)
        XCTAssertEqual(events[0].fileTotal, 2)
        XCTAssertTrue(p.totalKnown)
    }

    /// GNU rsync 3.x 中间态：done/total/percent 三者一致样例（不一致时信 total）。
    func testParserGnuPartialPercent() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("dir/b.bin\n     1000 1176  85%  1.23MB/s   00:00:02\n")
        XCTAssertEqual(events.last?.fileBytesDone, 1000)
        XCTAssertEqual(events.last?.fileBytesTotal, 1176)
    }

    /// done/total/pct 三者矛盾 → 信 total（拍板规则；一致样例区分不了「读 total 字段」
    /// 和「pct 反推」两实现，矛盾样例才能钉死读的是 total 字段）。
    func testParserInconsistentTrustsTotal() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("f\n  1000 1500  40%  1MB/s  00:00:01\n")   // 40% 与 1000/1500 矛盾
        XCTAssertEqual(events.last?.fileBytesTotal, 1500, "矛盾时信 total 字段，不采信 pct 反推的 1000*100/40=2500")
    }

    /// openrsync 式中间态（done 后直接 pct，无 total 字段）：total 由 pct 反推。
    func testParserOpenrsyncPartialReverseDerivesTotal() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("c.bin\n   250  25%  10KB/s  00:00:30\n")
        XCTAssertEqual(events.last?.fileBytesTotal, 1000)   // 250*100/25
        XCTAssertEqual(events.last?.fileBytesDone, 250)
    }

    /// 跨 chunk 半行拼接 + 尾巴缺失容忍。
    func testParserSplitAcrossChunksAndNoTail() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("b.txt\n   500 1000  50%  9")
        XCTAssertTrue(events.isEmpty, "半行不得出事件")
        p.feed(".9KB/s   00:00:00\n")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].fileBytesTotal, 1000)
        XCTAssertEqual(p.fileDone, 0, "尾巴缺失 → fileDone 保持 0（面板不显示文件计数）")
    }

    /// 多文件累计：文件间字节单调。
    func testParserMultiFileMonotonic() {
        let p = RsyncProgressParser()
        p.feed("a\n   6   6 100%  10B/s  0:00 (xfer#1, to-check=1/2)\n")
        p.feed("b\n  10  10 100%  10B/s  0:00 (xfer#2, to-check=2/2)\n")
        XCTAssertEqual(p.fileBytesDone, 16)   // 末行 done + 前文件累计
        XCTAssertEqual(p.fileDone, 2)
        XCTAssertEqual(p.fileTotal, 2)
    }

    /// 垃圾输入不抛不产事件（降级无进度，绝不判失败）。
    func testParserGarbageIgnored() {
        let p = RsyncProgressParser()
        var n = 0
        p.onEvent = { _ in n += 1 }
        p.feed("rsync: hello\u{FF}乱码???\n\n")
        XCTAssertEqual(n, 0)
    }

    /// 数字开头但形态认不全的行 → 同样忽略（`testParserGarbageIgnored` 走的是
    /// 「非数字首字段 = 文件名」分支，此条钉死数值行的「认不全 = 不抛不发布」分支）。
    func testParserNumericButMalformedIgnored() {
        let p = RsyncProgressParser()
        var n = 0
        p.onEvent = { _ in n += 1 }
        p.feed("12345 ??? 无百分比无 total\n")
        p.feed("678\n")                       // 只有 done，后面什么都没有
        XCTAssertEqual(n, 0)
        XCTAssertEqual(p.fileBytesDone, 0)
    }

    // MARK: 终审波 B1/B5 —— 真机逐字转写（重复 100% 行 + 多文件目录 + GNU3 拼写）

    /// **B1 主锁（真机 openrsync 逐字转写）**：>1s 传输每文件有**两条** 100% 行
    /// ——周期刷新行（`… 100% … 0:00:00\r`，无尾巴）与完成行（`… (xfer#N, …)\n`），
    /// done 相同。旧实现两条都判 completing → cumulative 全量累加两次 = 字节翻倍
    /// （实测 800KB 单文件 → 1600KB，面板 "1.6 MB / 819 KB"）。
    /// 现锁 = 累计必须等于真实字节和。变异证伪：删幂等折叠（改回 `cumulative += done`）
    /// → 单文件断言 819200≠1638400 红、目录断言 409600≠819200 红。
    func testParserRealTranscriptionDuplicateCompletionLines() {
        // 场景一：单文件 800 KB，周期刷新 + 完成各一条 100%（真机 \r 刷新形态）。
        let p1 = RsyncProgressParser()
        p1.feed("big.bin\n   409600  50%  1.95MB/s   0:00:00\r")
        p1.feed("   819200 100%  1.95MB/s   0:00:00\r")          // 周期刷新 100%
        p1.feed("   819200 100%  1.95MB/s   0:00:04 (xfer#1, to-check=0/1)\n")   // 完成行
        XCTAssertEqual(p1.fileBytesDone, 819_200,
                       "重复 100% 行不得重复计字节（真机单文件 800KB → 819200）")

        // 场景二：目录多文件（300KB + 100KB），每个都有重复 100% 行 → 真实和 409600。
        let p2 = RsyncProgressParser()
        p2.feed("dir/\ndir/a.bin\n   204800  68%  1.95MB/s   0:00:00\r")
        p2.feed("   307200 100%  1.95MB/s   0:00:01\r")
        p2.feed("   307200 100%  1.95MB/s   0:00:01 (xfer#1, to-check=1/3)\n")
        p2.feed("dir/b.bin\n   102400 100%  1.95MB/s   0:00:00\r")
        p2.feed("   102400 100%  1.95MB/s   0:00:00 (xfer#2, to-check=0/3)\n")
        XCTAssertEqual(p2.fileBytesDone, 409_600, "多文件重复 100% 行 → 真实字节和")
        XCTAssertEqual(p2.fileBytesTotal, 102_400, "当前文件总量语义（非整目录和）")
    }

    /// **B1 配套锁（幂等 ≠ 冻结）**：同名重列（如 `--progress` 对同一文件的更大
    /// done 完成态）仍须单调推进——「重复行不重复计」的实现若是「见过就跳过」，
    /// 此锁挂。变异证伪：把折叠写成「folded>0 后恒跳过」→ 1500 断言红。
    func testParserReListedLargerCompletionStillAdvances() {
        let p = RsyncProgressParser()
        p.feed("a.bin\n   1000 100%  10B/s  0:00:00 (xfer#1, to-check=0/2)\n")
        XCTAssertEqual(p.fileBytesDone, 1000)
        p.feed("a.bin\n   1500 100%  10B/s  0:00:00 (xfer#1, to-check=0/2)\n")
        XCTAssertEqual(p.fileBytesDone, 1500, "更大 done 的同名完成行必须继续推进")
    }

    /// **B5 配套（GNU ≥3.1 尾巴拼写）**：GNU 3.x 印 `xfr#`/`to-chk=`（非
    /// `xfer#`/`to-check=`）——两种拼写都要认，否则 fileDone/fileTotal 永远 0。
    /// 变异证伪：删 `xfr#`/`to-chk=` 变体 → fileDone/fileTotal 断言红（0/0）。
    func testParserGnu3TailSpellings() {
        let p = RsyncProgressParser()
        var events: [RsyncProgressParser.Event] = []
        p.onEvent = { events.append($0) }
        p.feed("dir/f.bin\n   1000 1176  85%  1.23MB/s   0:00:02 (xfr#1, to-chk=5/7)\n")
        XCTAssertEqual(p.fileTotal, 7, "to-chk= 拼写必须认得")
        XCTAssertEqual(p.fileDone, 1, "to-chk 未满 → fileDone 取 xfr# 计数")
        p.feed("dir/f.bin\n   1176 1176 100%  1.23MB/s   0:00:02 (xfr#1, to-chk=0/7)\n")
        XCTAssertEqual(p.fileDone, 7, "to-chk=0/T（i==T）→ fileDone=T")
        XCTAssertEqual(events.count, 2)
    }

    // MARK: B2 组合锁 ① —— progressFrame 逐条目帧矩阵（纯函数）

    /// 帧范围矩阵（spec §1 逐条目合同，终审 B2 裁定）：
    /// - 目录条目：无预扫描，total 恒 0（不定量）——旧实现拿**当前文件** total 当
    ///   分母 + 引擎跨条目基线 → done>total 稳态恒 100%（实测 "717KB/102KB"）；
    /// - 文件条目：分母 = totalHint（item.size），done 夹紧不超分母；
    /// - size 拿不到（hint nil/0）→ 不定量。
    /// 变异证伪：目录分支返回 (entryDone, fileTotal) → dir 断言红；
    /// 删 min 夹紧 → done>hint 断言红。
    func testProgressFrameMatrix() {
        typealias F = DirectRsync.Frame
        // 目录：无视 hint，恒 (done, 0)
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: true, entryDone: 700_000,
                                                 totalHint: nil).total, 0)
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: true, entryDone: 5,
                                                 totalHint: 999), F(done: 5, total: 0))
        // 文件：定量 + 夹紧
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: false, entryDone: 5,
                                                 totalHint: 10), F(done: 5, total: 10))
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: false, entryDone: 15,
                                                 totalHint: 10), F(done: 10, total: 10),
                       "done 超 hint（解析器反推误差）→ 夹紧，面板不得 >100%")
        // 文件无 hint / hint=0 → 不定量
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: false, entryDone: 7,
                                                 totalHint: nil), F(done: 7, total: 0))
        XCTAssertEqual(DirectRsync.progressFrame(isDirectory: false, entryDone: 7,
                                                 totalHint: 0), F(done: 7, total: 0))
    }

    /// **B5 主锁（parser→桥→帧名链，spec 决策 #2「当前文件名取 --progress 文件名行」）**：
    /// 逐字模拟 runDirectRsync 桥的拉取语义（consumedFileName → onFile 写盒 → 置 nil），
    /// 帧名经 TransferEngine.directName 出。变异证伪：桥里删 `onFile?(name)` →
    /// 中段 "report.pdf" 断言红；directName 把 nil 转成非空 → 首尾断言红。
    func testParserFileNameReachesFrameName() {
        let p = RsyncProgressParser()
        let box = DirectNameBox()
        // 桥语义：fileBytesDone>0 时拉名 → onFile → 清空。
        func bridgeOnce() {
            guard p.fileBytesDone > 0, let n = p.consumedFileName else { return }
            box.name = n
            p.consumedFileName = nil
        }
        XCTAssertEqual(TransferEngine.directName(from: box), "", "无帧 = 无名（面板沿用上一帧）")
        p.feed("report.pdf\n   100 1000  10%  10B/s  0:00:01\n")
        bridgeOnce()
        XCTAssertEqual(TransferEngine.directName(from: box), "report.pdf")
        bridgeOnce()   // 名字已拉走：后续帧不带名
        XCTAssertEqual(TransferEngine.directName(from: box), "report.pdf",
                       "盒是持久展示态（沿用），拉取清空的是 parser 侧")
        p.feed("   200 1000  20%  10B/s  0:00:01\n")   // 无名数值行
        bridgeOnce()
        XCTAssertNil(p.consumedFileName, "无新文件名行 → 不产名")
    }
}
