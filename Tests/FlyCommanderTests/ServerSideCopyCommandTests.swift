import XCTest
import TCCore
@testable import FlyCommander

/// ServerSideCopy 纯函数回归：shell 引用、cp 命令拼装、exit 分类。
/// 可证伪性逐条注在测试里；核心不变量——**任意路径经 shellQuote 后只能是
/// 单引号字面量**，注入面（$、反引号、;、换行、以 - 开头）全被引号+`--` 封死。
final class ServerSideCopyCommandTests: XCTestCase {

    // MARK: - shellQuote / command

    func testSimplePath() {
        XCTAssertEqual(ServerSideCopy.command(src: "/tmp/a.txt", dst: "/tmp/b.txt", useA: true),
                       #"cp -a -- '/tmp/a.txt' '/tmp/b.txt'"#,
                       "基本引用形态钉死；丢掉单引号或 -- 都红")
    }

    func testPathWithSpaces() {
        XCTAssertEqual(ServerSideCopy.command(src: "/tmp/my file.txt", dst: "/tmp/d.txt", useA: true),
                       #"cp -a -- '/tmp/my file.txt' '/tmp/d.txt'"#)
    }

    func testSingleQuoteEscaping() {
        // it's → 'it'\''s'：闭引号 + 转义单引号 + 重开引号三段拼接。
        // 期望字符串逐字：'/tmp/it'\''s.txt'
        XCTAssertEqual(ServerSideCopy.shellQuote("/tmp/it's.txt"),
                       "'/tmp/it'\\''s.txt'",
                       "内部单引号必须转义成 '\\''，否则引号配对被打穿 = 注入回归")
    }

    func testDashLeadingPath() {
        // `--` 终止选项：-rf.txt 不得被 cp 当 flag。
        XCTAssertTrue(ServerSideCopy.command(src: "/tmp/-rf.txt", dst: "/tmp/x", useA: true)
                        .contains("cp -a -- '/tmp/-rf.txt'"))
    }

    func testShellMetacharsStayLiteral() {
        let cmd = ServerSideCopy.command(src: "/tmp/$(rm -rf `IFS`;x).txt", dst: "/tmp/y", useA: true)
        XCTAssertTrue(cmd.contains("'/tmp/$(rm -rf `IFS`;x).txt'"),
                      "$ `` ; 在单引号内必须原样，出现脱离引号的形态 = 注入回归")
    }

    func testBackslashLiteral() {
        XCTAssertEqual(ServerSideCopy.shellQuote("/tmp/a\\b.txt"), "'/tmp/a\\b.txt'",
                       "单引号内反斜杠不转义（POSIX），双反斜杠输入不得被吞")
    }

    func testRpFallbackForm() {
        XCTAssertEqual(ServerSideCopy.command(src: "/a", dst: "/b", useA: false),
                       "cp -Rp -- '/a' '/b'")
    }

    // MARK: - classify

    func testZeroIsOk() {
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: 0, stderr: ""), .ok)
    }

    func testNilStatusRelaysChannelGone() {
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: nil, stderr: "whatever"),
                       .relay(.channelGone),
                       "无 exit 状态 = 通道异常，必须回退 pump（原因 channelGone）")
    }

    func testMissingCpRelaysCpMissing() {
        // 变异：127 若仍归 channelGone（旧行为）→ 本条红（丢失「服务器无 cp」这一独立原因）。
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: 127, stderr: "sh: cp: not found"),
                       .relay(.cpMissing), "cp 不存在属服务器能力缺失，pump 还能干活")
    }

    func testGNUUnsupportedFlags() {
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: 1,
                                               stderr: "cp: invalid option -- 'a'"),
                       .relay(.unsupportedFlags), "GNU -a 不认 → 触发 -Rp 重试")
    }

    func testBSDUnsupportedFlags() {
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: 1,
                                               stderr: "cp: illegal option -- a"),
                       .relay(.unsupportedFlags), "BSD 措辞同判")
    }

    func testPermissionDeniedIsFail() {
        let r = ServerSideCopy.classify(exitStatus: 1,
                                        stderr: "cp: cannot create 'x': Permission denied")
        guard case .fail(let msg) = r else {
            return XCTFail("权限失败必须归 fail（不回退），实际 \(r)")
        }
        XCTAssertTrue(msg.contains("Permission denied"))
    }

    func testEmptyStderrNonZeroRelaysChannelGone() {
        // 受限 shell 可能把话说到 stdout 或干脆沉默——没诊断可保留就交 pump。
        XCTAssertEqual(ServerSideCopy.classify(exitStatus: 1, stderr: "  \n"), .relay(.channelGone))
    }

    // MARK: - relayReason(for:)（execute 抛错 → 回退原因）

    /// 构造 SSHClientError.operationFailed（用 Traversio public 结构 + 最小诊断）。
    /// 直接构造 SSHOperationFailureDiagnostics 需要公开 init；退而用真实连接错误不可行，
    /// 故仅验证**非 operationFailed** 的错误一律归 channelGone（可达且可证伪的那条分支），
    /// requestFailed→execRejected 的映射由注释核对 Traversio 源码保证（见 SFTPClient.swift）。
    func testNonOperationFailedErrorIsChannelGone() {
        // 变异：把 default 分支改成 .execRejected → 本条红（任意错误都被误报「服务器拒命令」）。
        XCTAssertEqual(ServerSideCopy.relayReason(for: TCError.unknown("boom")), .channelGone,
                       "非 SSHClientError.operationFailed 的错误只能归 channelGone")
    }
}
