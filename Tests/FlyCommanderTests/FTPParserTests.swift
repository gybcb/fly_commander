import XCTest
import Foundation
@testable import FlyCommander
import TCCore

/// 纯解析单测：分帧 / PASV / 时间 / LIST 双格式 / MLSD。全部无 IO、无网络。
final class FTPParserTests: XCTestCase {
    // MARK: 应答分帧

    func testSingleLineReply() {
        let p = FTPReplyParser()
        p.append(Data("220 Welcome\r\n".utf8))
        let r = p.nextReply()
        XCTAssertEqual(r?.code, 220)
        XCTAssertEqual(r?.message, "220 Welcome")
    }

    func testMultiLineReply() {
        let p = FTPReplyParser()
        // 显式拼接而非多行字面量：多行字面量不给最后一行尾随换行，而分帧器要按行切
        let text = "211-Features:\r\n MDTM\r\n UTF8\r\n211 End\r\n"
        p.append(Data(text.utf8))
        let r = p.nextReply()
        XCTAssertEqual(r?.code, 211)
        XCTAssertEqual(r?.lines.count, 4)
        XCTAssertEqual(r?.lines.last, "211 End")
    }

    /// 半条应答分批到达：前一批 nextReply() 返回 nil，补齐后才出。
    func testMultiLineSplitAcrossChunks() {
        let p = FTPReplyParser()
        p.append(Data("211-Features:\r\n SIZE=5;".utf8))
        XCTAssertNil(p.nextReply())
        p.append(Data("\r\n211 End\r\n".utf8))
        let r = p.nextReply()
        XCTAssertEqual(r?.code, 211)
    }

    /// 缓冲里连发两条应答：逐条取出。
    func testTwoRepliesInOneChunk() {
        let p = FTPReplyParser()
        p.append(Data("220 hi\r\n331 need pass\r\n".utf8))
        XCTAssertEqual(p.nextReply()?.code, 220)
        XCTAssertEqual(p.nextReply()?.code, 331)
        XCTAssertNil(p.nextReply())
    }

    func testBannerWithoutCodeIsSkipped() {
        let p = FTPReplyParser()
        p.append(Data("# comment line\r\n220 real\r\n".utf8))
        XCTAssertEqual(p.nextReply()?.code, 220)
    }

    func testParseCodeAndPredicates() {
        XCTAssertEqual(FTPReplyParser.parseCode("220 hi"), 220)
        XCTAssertNil(FTPReplyParser.parseCode("hi"))
        XCTAssertTrue(FTPReplyParser.isSingleLine("220 hi"))
        XCTAssertTrue(FTPReplyParser.isSingleLine("220"))       // 省略尾随空格
        XCTAssertTrue(FTPReplyParser.isMultiLineStart("211-Feats"))
        XCTAssertFalse(FTPReplyParser.isSingleLine("211-Feats"))
    }

    // MARK: PASV / EPSV

    func testPasvParse() {
        let r = FTPReply(code: 227, lines: ["227 Entering Passive Mode (192,168,1,10,197,26)."])
        let ep = FTPPasv.parse(r, fallbackHost: "x")
        XCTAssertEqual(ep?.host, "192.168.1.10")
        XCTAssertEqual(ep?.port, 197 * 256 + 26)   // 50458
    }

    func testPasvParseSpacedNoClose() {
        // 个别实现：括号内空格分隔、无右括号
        let r = FTPReply(code: 227, lines: ["227 Entering Passive Mode (10 0 0 5 4 1"])
        let ep = FTPPasv.parse(r, fallbackHost: "x")
        XCTAssertEqual(ep?.host, "10.0.0.5")
        XCTAssertEqual(ep?.port, 4 * 256 + 1)
    }

    func testPasvRejectsGarbage() {
        let r = FTPReply(code: 227, lines: ["227 nonsense"])
        XCTAssertNil(FTPPasv.parse(r, fallbackHost: "h"))
    }

    func testEpsvParse() {
        let r = FTPReply(code: 229, lines: ["229 Entering Extended Passive Mode (|||50021|)."])
        let ep = FTPPasv.parseEpsv(r, fallbackHost: "srv")
        XCTAssertEqual(ep?.host, "srv")          // EPSV 不带地址，回落控制主机
        XCTAssertEqual(ep?.port, 50021)
    }

    // MARK: 时间

    func testTimestampParse() {
        let d = FTPDate.parseTimestamp("20260131143059")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual(c.year, 2026); XCTAssertEqual(c.month, 1); XCTAssertEqual(c.day, 31)
        XCTAssertEqual(c.hour, 14); XCTAssertEqual(c.minute, 30); XCTAssertEqual(c.second, 59)
    }

    func testTimestampToleratesFractionAndZ() {
        XCTAssertNotNil(FTPDate.parseTimestamp("20260131143059.5Z"))
        XCTAssertNil(FTPDate.parseTimestamp("2026"))      // 不足 14 位
    }

    // MARK: LIST —— UNIX

    /// 固定「现在」：2026-06-15 12:00 UTC，时区 UTC（测当年/年份分支不依赖真机时钟）。
    private func fixedNow() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = 12
        return cal.date(from: c)!
    }
    private let utc = TimeZone(secondsFromGMT: 0)!

    func testUnixFileWithYearAndSpaceName() {
        let line = "-rw-r--r-- 1 owner group 12345 Jun 01 2024 my report.txt"
        let e = FTPListParser.parseListLine(line, now: fixedNow(), timeZone: utc)!
        XCTAssertEqual(e.name, "my report.txt")
        XCTAssertFalse(e.isDirectory)
        XCTAssertEqual(e.size, 12345)
        XCTAssertFalse(e.isExecutable)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day], from: e.modificationDate)
        XCTAssertEqual(c.year, 2024); XCTAssertEqual(c.month, 6); XCTAssertEqual(c.day, 1)
    }

    func testUnixHHMMWithinSixMonthsIsThisYear() {
        // now=2026-06-15；Jun 01 12:34 在今年且 <6 月内 → 2026
        let e = FTPListParser.parseListLine("drwxr-xr-x 2 o g 4096 Jun 01 12:34 sub",
                                            now: fixedNow(), timeZone: utc)!
        XCTAssertTrue(e.isDirectory)
        XCTAssertTrue(e.isExecutable)
        XCTAssertEqual(e.size, 0)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        XCTAssertEqual(cal.component(.year, from: e.modificationDate), 2026)
    }

    func testUnixHHMMDistantFutureFallsBackToLastYear() {
        // now=2026-06-15；Dec 25 算在今年是未来 >6 月 → 应为 2025
        let e = FTPListParser.parseListLine("-rw-r--r-- 1 o g 1 Dec 25 09:00 f",
                                            now: fixedNow(), timeZone: utc)!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        XCTAssertEqual(cal.component(.year, from: e.modificationDate), 2025)
    }

    func testUnixSymlinkStripsArrowTarget() {
        let e = FTPListParser.parseListLine("lrwxrwxrwx 1 o g 7 Jan 01 2024 link -> target",
                                            now: fixedNow(), timeZone: utc)!
        XCTAssertEqual(e.name, "link")
        XCTAssertFalse(e.isDirectory)   // 符号链接按文件处理
    }

    func testUnixExecutableFlag() {
        let e = FTPListParser.parseListLine("-rwxr-xr-x 1 o g 100 Jan 01 2024 run.sh",
                                            now: fixedNow(), timeZone: utc)!
        XCTAssertTrue(e.isExecutable)
    }

    func testUnixSkipsTotalLine() {
        XCTAssertNil(FTPListParser.parseListLine("total 42", now: fixedNow(), timeZone: utc))
    }

    // MARK: LIST —— MS-DOS

    func testDosDirectory() {
        let e = FTPListParser.parseListLine("06-01-24  10:35AM  <DIR>          sub",
                                            now: fixedNow(), timeZone: utc)!
        XCTAssertEqual(e.name, "sub")
        XCTAssertTrue(e.isDirectory)
        XCTAssertTrue(e.isExecutable)
        XCTAssertEqual(e.size, 0)
    }

    func testDosFileWithSizeAndPM() {
        let e = FTPListParser.parseListLine("06-01-24  02:07PM  1234 my file.bin",
                                            now: fixedNow(), timeZone: utc)!
        XCTAssertEqual(e.name, "my file.bin")
        XCTAssertFalse(e.isDirectory)
        XCTAssertEqual(e.size, 1234)
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        XCTAssertEqual(cal.component(.hour, from: e.modificationDate), 14)   // 2 PM
        XCTAssertEqual(cal.component(.minute, from: e.modificationDate), 7)
    }

    /// 一批 DOS 混合行 → 条目（含目录/文件，噪声行丢弃）。
    func testDosBatch() {
        let text = "06-01-24  10:35AM  <DIR>          sub\n"
            + "06-01-24  02:07PM  9 a.txt\n"
        let items = FTPListParser.parseList(text, now: fixedNow(), timeZone: utc)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].name, "sub")
        XCTAssertEqual(items[1].size, 9)
    }

    // MARK: MLSD

    func testMlsdLine() {
        let e = FTPListParser.parseMlsdLine("type=file;size=5;modify=20260131143059; report.txt")!
        XCTAssertEqual(e.name, "report.txt")
        XCTAssertFalse(e.isDirectory)
        XCTAssertEqual(e.size, 5)
    }

    func testMlsdDirAndSpaceName() {
        let e = FTPListParser.parseMlsdLine("type=dir;modify=20260131143059; My Docs")!
        XCTAssertEqual(e.name, "My Docs")
        XCTAssertTrue(e.isDirectory)
        XCTAssertTrue(e.isExecutable)
        XCTAssertEqual(e.size, 0)
    }

    /// 主流服务器（vsftpd/ProFTPD/FileZilla）的 MLSD **不发** `name=` 事实——条目名就是
    /// 事实区之后的文本。此条锁「事实解析不被名称污染」+「名称区含空格完整保留」。
    func testMlsdNameComesAfterFactsSection() {
        let e = FTPListParser.parseMlsdLine("type=file;size=1;modify=20260131143059; two words.txt")!
        XCTAssertEqual(e.name, "two words.txt")
        XCTAssertEqual(e.size, 1)   // size 事实须仍解析出（早期用第一个 ';' 切会把名称吃掉）
    }

    /// 名称里带 ';' 的条目：名称区原样保留（服务器若发这种名字，事实区收尾仍是首个 `; `）。
    func testMlsdNameContainingSemicolon() {
        let e = FTPListParser.parseMlsdLine("type=file;size=2; a;b.txt")!
        XCTAssertEqual(e.name, "a;b.txt")
    }

    func testMlsdSkipsCdirPdir() {
        XCTAssertNil(FTPListParser.parseMlsdLine("type=cdir;modify=20260101000000; ."))
        XCTAssertNil(FTPListParser.parseMlsdLine("type=pdir;modify=20260101000000; .."))
    }

    // MARK: PWD 去引号

    func testUnquotePath() {
        XCTAssertEqual(FTPClient.unquotePath("257 \"/a/b/c\" is current"), "/a/b/c")
        XCTAssertEqual(FTPClient.unquotePath("257 \"/\""), "/")
        XCTAssertEqual(FTPClient.unquotePath("257 \"/a\"\"b\" x"), "/a\"b")   // "" → "
    }
}
