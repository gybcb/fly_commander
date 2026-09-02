import XCTest
import Foundation
@testable import TCCore

/// T7：CommandLineParser 纯函数单测（分词/引号/转义/错误）。
final class CommandLineParserTests: XCTestCase {
    func testSingleWordNoArgs() throws {
        let c = try CommandLineParser.parse("ls")
        XCTAssertEqual(c.name, "ls")
        XCTAssertEqual(c.args, [])
    }

    func testCommandWithArgs() throws {
        let c = try CommandLineParser.parse("cd /Users/bob/docs")
        XCTAssertEqual(c.name, "cd")
        XCTAssertEqual(c.args, ["/Users/bob/docs"])
    }

    func testMultipleArgsSplitOnSpaces() throws {
        let c = try CommandLineParser.parse("del a.txt b.txt c.txt")
        XCTAssertEqual(c.name, "del")
        XCTAssertEqual(c.args, ["a.txt", "b.txt", "c.txt"])
    }

    func testTabsSeparateTokens() throws {
        let c = try CommandLineParser.parse("cd\t/tmp")
        XCTAssertEqual(c.name, "cd")
        XCTAssertEqual(c.args, ["/tmp"])
    }

    func testLeadingAndTrailingWhitespaceIgnored() throws {
        let c = try CommandLineParser.parse("   ls   ")
        XCTAssertEqual(c.name, "ls")
        XCTAssertEqual(c.args, [])
    }

    func testConsecutiveSpacesCollapse() throws {
        let c = try CommandLineParser.parse("mkdir   new  dir")
        XCTAssertEqual(c.name, "mkdir")
        XCTAssertEqual(c.args, ["new", "dir"])
    }

    func testQuotedArgWithSpaces() throws {
        let c = try CommandLineParser.parse("mkdir \"my folder\"")
        XCTAssertEqual(c.name, "mkdir")
        XCTAssertEqual(c.args, ["my folder"])
    }

    func testQuotedArgWithLeadingTrailingSpacesInside() throws {
        let c = try CommandLineParser.parse("cd \"  spaced  \"")
        XCTAssertEqual(c.args, ["  spaced  "])
    }

    func testQuotesAdjacentToText() throws {
        // a" b"c → a + " b" + c = "a bc"（引号片段与裸文本直接拼接）
        let c = try CommandLineParser.parse("cd a\" b\"c")
        XCTAssertEqual(c.args, ["a bc"])
    }

    func testEmptyQuotedProducesNoArg() throws {
        // 空引号不产生 token（与"无参数"等价；引擎层对空名统一拒绝）
        let c = try CommandLineParser.parse("mkdir \"\"")
        XCTAssertEqual(c.args, [])
    }

    func testBackslashEscapesSpaceOutsideQuotes() throws {
        let c = try CommandLineParser.parse("mkdir my\\ folder")
        XCTAssertEqual(c.args, ["my folder"])
    }

    func testBackslashEscapesQuoteOutsideQuotes() throws {
        let c = try CommandLineParser.parse("echo a\\\"b")
        XCTAssertEqual(c.args, ["a\"b"])
    }

    func testBackslashInsideQuotes() throws {
        let c = try CommandLineParser.parse("echo \"a\\\"b\"")
        XCTAssertEqual(c.args, ["a\"b"])
        let d = try CommandLineParser.parse("echo \"a\\\\b\"")
        XCTAssertEqual(d.args, ["a\\b"])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try CommandLineParser.parse("cd \"abc")) {
            XCTAssertEqual($0 as? CommandLineError, .unterminatedQuote)
        }
    }

    func testEmptyLineThrowsEmpty() {
        XCTAssertThrowsError(try CommandLineParser.parse("")) {
            XCTAssertEqual($0 as? CommandLineError, .empty)
        }
        XCTAssertThrowsError(try CommandLineParser.parse("   \t ")) {
            XCTAssertEqual($0 as? CommandLineError, .empty)
        }
    }

    func testTrailingBackslashKeepsLiteral() throws {
        // 行尾孤立反斜杠：无下一字符可转义，按字面保留（shell 行续接不在本工具范围）
        let c = try CommandLineParser.parse("cd a\\")
        XCTAssertEqual(c.args, ["a\\"])
    }

    func testUnicodeAndChineseArgs() throws {
        let c = try CommandLineParser.parse("cd 文档/照片 2026")
        XCTAssertEqual(c.args, ["文档/照片", "2026"])
        let q = try CommandLineParser.parse("mkdir \"中文 目录\"")
        XCTAssertEqual(q.args, ["中文 目录"])
    }

    func testSftpPathArgPreserved() throws {
        let c = try CommandLineParser.parse("cd sftp://10.0.0.1:2222/home/bob")
        XCTAssertEqual(c.args, ["sftp://10.0.0.1:2222/home/bob"])
    }

    func testLangCommandParses() throws {
        let en = try CommandLineParser.parse("lang en")
        XCTAssertEqual(en.name, "lang")
        XCTAssertEqual(en.args, ["en"])
        let bare = try CommandLineParser.parse("lang")
        XCTAssertEqual(bare.name, "lang")
        XCTAssertEqual(bare.args, [])
    }

    // MARK: - encodeToken（cd 补全把文件名写回命令栏，须 round-trip 成单个 token）

    func testEncodePlainUnchanged() {
        XCTAssertEqual(CommandLineParser.encodeToken("Down"), "Down")
        XCTAssertEqual(CommandLineParser.encodeToken("a.txt"), "a.txt")
        XCTAssertEqual(CommandLineParser.encodeToken("sftp://h:22/x"), "sftp://h:22/x")
    }

    func testEncodeSpaceQuoted() {
        XCTAssertEqual(CommandLineParser.encodeToken("My Documents"), "\"My Documents\"")
    }

    func testEncodeQuotesAndBackslash() {
        XCTAssertEqual(CommandLineParser.encodeToken("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(CommandLineParser.encodeToken("a\\b"), "\"a\\\\b\"")
    }

    func testEncodeEmptyQuoted() {
        // 空串须加引号，否则 "cd " 解析为无参（doCd 回 home）而非空目标
        XCTAssertEqual(CommandLineParser.encodeToken(""), "\"\"")
    }

    /// 关键契约：编码后的字符串经 parse 必须还原为**单个**、且等于原串的参数。
    /// 覆盖含空格/引号/反斜杠/中文/混合的文件名。
    func testEncodeTokenRoundTripsThroughParse() throws {
        let names = [
            "My Documents", "a\"b", "a\\b", "中文 目录", "文档/照片 2026",
            "weird\\\"mix", "tab\there", "spaces   around", "quote\" and \\ backslash",
        ]
        for name in names {
            let line = "cd " + CommandLineParser.encodeToken(name)
            let c = try CommandLineParser.parse(line)
            XCTAssertEqual(c.name, "cd")
            XCTAssertEqual(c.args.count, 1, "「\(name)」应解析成 1 个参数，实际 \(c.args)")
            XCTAssertEqual(c.args[0], name, "「\(name)」round-trip 失败：\(c.args)")
        }
    }
}
