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
}
