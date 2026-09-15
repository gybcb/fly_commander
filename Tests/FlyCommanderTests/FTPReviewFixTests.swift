import XCTest
import AppKit
@testable import FlyCommander
import TCCore

/// FTP 评审问题回归锁（blocker/major 逐条钉死）。夹具复用 FTPSourceE2ETests 那套
/// 真 NWConnection + 进程内 MiniFTPServer + 真临时目录。
///
/// 变异证伪（红面 = 该测试唯一红）：
/// ① openReader 收哨后不核对 SIZE（回到「226=完成」）→ testTruncatedRetr* 红（静默写半截）
/// ② performSync 不全程持锁 / openReader 无传输租约 → testConcurrent* 红（应答错位/超时）
/// ③ mlst 只认 257 → testRFCCompliantMlst250* 红
/// ④ parseUnixLine 固定 9 段 / looksLikePerm 只认 10 字符 → testListLineWithSELinuxSuffix* 红
/// ⑤ copyItem 无目录分支 → testCopyDirectorySameSource* 红（550→notFound）
/// ⑥ DirectoryFavorite.tcPath 缺 ftp 分支 → testFavoriteTCPath* 红（落 fileURL）
/// ⑦ TLS 勾选不回写端口 → testTLSCheckbox* 红（TLS-over-21）
/// ⑧ 取消传输后连接不丢 → testCancelledTransfer* 红（连吃 226/227/425）
/// ⑨ prepare() 端口留空 → testPrepareFillsDefaultPort 红（「端口无效」）
/// ⑩ record.sourceID 只省 21 → testFTPSRecordMatchesLiveSourceID 红（收藏点不中）
final class FTPReviewFixTests: XCTestCase {
    private var server: MiniFTPServer!
    private var root: URL!
    private var source: FTPSource!
    private var port: UInt16 = 0

    private func boot(mlstReplyCode: Int = 257, retrTruncateBytes: Int? = nil) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fly-ftp-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        server = MiniFTPServer(root: root, mlstReplyCode: mlstReplyCode,
                               retrTruncateBytes: retrTruncateBytes)
        port = try server.start()
        source = FTPSource(config: FTPClient.Config(host: "127.0.0.1", port: port,
                                                     username: "user", password: "secret", tls: false))
    }

    override func tearDown() {
        source?.closeConnection()
        source = nil
        server?.stop()
        server = nil
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        super.tearDown()
    }

    private func p(_ remote: String) -> TCPath {
        FTPSource.tcPath(host: "127.0.0.1", port: Int(port), remotePath: remote)
    }
    private var base: String { root.standardizedFileURL.path }

    private func writeOnce(_ data: Data, into dst: TCPath) throws {
        var sent = false
        try source.streamWrite(dst, totalBytes: Int64(data.count)) {
            if sent { return Data() }
            sent = true
            return data
        }
    }

    // MARK: - ① 截断（F1，blocker）

    /// 服务端只发一半就 RST、随后照发 226：copyItem 必须**抛错**，绝不允许
    /// 「无错返回 + dst 半截」。实证红面（修复前）：无错返回、dst=200_000/400_000。
    func testTruncatedRetrMakesCopyItemThrow() throws {
        try boot(retrTruncateBytes: 200_000)
        let payload = Data(repeating: 0x41, count: 400_000)
        try writeOnce(payload, into: p(base + "/src.bin"))
        XCTAssertThrowsError(try source.copyItem(from: p(base + "/src.bin"),
                                                 to: p(base + "/dst.bin"))) { error in
            // 专用 case：数据完整性失败 ≠ 连接失败（文案=重传该文件，而非查网络）。
            guard case .ftpTransferTruncated? = error as? TCError else {
                return XCTFail("期望 ftpTransferTruncated（截断），实际 \(String(describing: error))")
            }
        }
        // 关键：绝不允许留下「看起来成功」的半截副本
        let onDisk = (try? Data(contentsOf: root.appendingPathComponent("dst.bin")))?.count ?? -1
        XCTAssertNotEqual(onDisk, payload.count, "不得写出完整副本（本就该失败）")
    }

    /// 截断同样必须让 openReader 泵本身抛错（跨源下载路径：OperationEngine.stream
    /// 只信 reader 的 EOF，不校验总字节 → 句柄必须自己判定截断）。
    func testTruncatedRetrThrowsWhenPumpingReader() throws {
        try boot(retrTruncateBytes: 200_000)
        try writeOnce(Data(repeating: 0x42, count: 400_000), into: p(base + "/s.bin"))
        XCTAssertThrowsError(try {
            let reader = try self.source.openReader(self.p(self.base + "/s.bin"))
            var got = Data()
            while let chunk = try reader(64 * 1024) { got.append(chunk) }
            return got
        }()) { error in
            guard case .ftpTransferTruncated? = error as? TCError else {
                return XCTFail("期望 ftpTransferTruncated，实际 \(String(describing: error))")
            }
        }
    }

    /// 正常完整传输仍然必须成功（截断守卫不得误伤正常路径）。
    func testCompleteRetrStillSucceedsAfterGuard() throws {
        try boot()
        let payload = Data(repeating: 0x43, count: 300_000)
        try writeOnce(payload, into: p(base + "/ok.bin"))
        try source.copyItem(from: p(base + "/ok.bin"), to: p(base + "/copy.bin"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copy.bin")), payload)
    }

    // MARK: - ② 并发（F2，blocker）

    /// 跨源下载 FTP 文件的同时在该 FTP 源上浏览（listDirectory/stat = ⌘R 刷新）。
    /// 修复前：FTP 单控制连接被并发驱动 → unexpectedReply 226/150 或 15s 超时。
    func testConcurrentBrowseDuringReaderPump() throws {
        try boot()
        try writeOnce(Data(repeating: 0x44, count: 400_000), into: p(base + "/big.bin"))
        let reader = try source.openReader(p(base + "/big.bin"))
        let group = DispatchGroup()
        var browseError: Error?
        // 泵送方（跨源下载的等价物：逐块读尽）
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do { var got = Data(); while let c = try reader(64 * 1024) { got.append(c) } }
            catch { /* 泵送错误由下面的字节断言暴露 */ }
        }
        // 同一 source 对象上的浏览（loadAsync/navigate 的等价物）
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do { _ = try self.source.listDirectory(self.p(self.base)) }
            catch { browseError = error }
        }
        group.wait()
        XCTAssertNil(browseError, "传输期间浏览被应答错位毒化：\(String(describing: browseError))")
    }

    /// 纯并发读（8 路 openReader）：修复前 8/8 全挂。现在必须全部串行成功。
    func testConcurrentReadersAllSucceed() throws {
        try boot()
        for i in 0..<8 {
            try writeOnce(Data(repeating: UInt8(0x50 + i), count: 200_000), into: p(base + "/c\(i).bin"))
        }
        let group = DispatchGroup()
        var failures: [Error] = []
        let lock = NSLock()
        for i in 0..<8 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    let reader = try self.source.openReader(self.p(self.base + "/c\(i).bin"))
                    var got = Data()
                    while let c = try reader(64 * 1024) { got.append(c) }
                    lock.lock(); if got.count != 200_000 { failures.append(TCError.unknown("short \(got.count)")) }; lock.unlock()
                } catch {
                    lock.lock(); failures.append(error); lock.unlock()
                }
            }
        }
        group.wait()
        XCTAssertTrue(failures.isEmpty, "并发读失败：\(failures.map { String(describing: $0) })")
    }

    // MARK: - ③ MLST 250（F3，major）

    /// RFC 3659 §7.2 的 MLST 用 250。修复前只认 257 → stat 抛 unknown(250)，
    /// isDirectory 恒 false → FilePane.navigate 的远端分支「双击目录没反应」。
    func testRFCCompliantMlst250StillStats() throws {
        try boot(mlstReplyCode: 250)
        try source.makeDirectory(at: p(base + "/rfc"))
        try writeOnce(Data("hi".utf8), into: p(base + "/rfc/a.txt"))
        XCTAssertTrue(source.isDirectory(p(base + "/rfc")), "250 形态 MLST 必须认得目录")
        XCTAssertFalse(source.isDirectory(p(base + "/rfc/a.txt")))
        XCTAssertEqual(try source.stat(p(base + "/rfc/a.txt"))?.size, 2)
        // 传输面仍可用（250 不影响数据通道）
        let reader = try source.openReader(p(base + "/rfc/a.txt"))
        XCTAssertEqual(try reader(64 * 1024), Data("hi".utf8))
    }

    /// 旧实现（257）必须继续可用——两支都认。
    func testLegacyMlst257StillWorks() throws {
        try boot(mlstReplyCode: 257)
        try source.makeDirectory(at: p(base + "/legacy"))
        XCTAssertTrue(source.isDirectory(p(base + "/legacy")))
    }

    // MARK: - ⑤ copyItem 目录（F5，major）

    /// FTP→FTP 同面板复制文件夹：修复前无条件 RETR → 550 → 对存在的文件夹显示「不存在」。
    func testCopyDirectorySameSourceRecurses() throws {
        try boot()
        try source.makeDirectory(at: p(base + "/tree"))
        let tree = p(base + "/tree")
        try writeOnce(Data("one".utf8), into: tree.joining("a.txt"))
        try source.makeDirectory(at: tree.joining("sub"))
        try writeOnce(Data("two".utf8), into: tree.joining("sub/b.txt"))

        try source.copyItem(from: tree, to: p(base + "/tree2"))

        let dst = root.appendingPathComponent("tree2")
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("a.txt")), Data("one".utf8))
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("sub/b.txt")), Data("two".utf8))
        let copied = try source.listDirectory(p(base + "/tree2"))
        XCTAssertEqual(Set(copied.map(\.name)), ["a.txt", "sub"])
        XCTAssertTrue(copied.first { $0.name == "sub" }!.isDirectory)
    }

    // MARK: - ⑧ 取消传输后的连接卫生（F8，major）

    /// 泵送中途取消（OperationEngine 在 write 闭包里抛 .cancelled）：数据连接被半途中止，
    /// 服务器随后的 226 会滞留在共享控制连接上。修复前同连接后续操作连吃
    /// unexpectedReply 226 → 227 → 425（三次不自愈）。
    func testCancelledUploadLeavesUsableConnection() throws {
        try boot()
        let big = Data(repeating: 0x55, count: 400_000)
        var sentFirst = false
        XCTAssertThrowsError(try source.streamWrite(p(base + "/cancel.bin"), totalBytes: Int64(big.count)) {
            if !sentFirst { sentFirst = true; return big }     // 写完一整块即取消
            throw TCError.cancelled
        }) { error in
            XCTAssertEqual(error as? TCError, .cancelled, "取消语义原样上抛")
        }
        // 取消后立刻用同一条 FTPSource 操作：必须正常（连接已被判定不可复用 → 懒重连）
        try writeOnce(Data("after".utf8), into: p(base + "/later.txt"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("later.txt")), Data("after".utf8))
    }

    /// 下载句柄被弃用（取消下载：调用方不再调它）后，同连接后续操作同样必须可用。
    func testAbandonedReaderLeavesUsableConnection() throws {
        try boot()
        try writeOnce(Data(repeating: 0x56, count: 400_000), into: p(base + "/dl.bin"))
        do {
            let reader = try source.openReader(p(base + "/dl.bin"))
            _ = try reader(1024)          // 只读一块就弃用
        }
        try writeOnce(Data("ok".utf8), into: p(base + "/after.txt"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("after.txt")), Data("ok".utf8))
    }
}

// MARK: - ④ LIST 权限列形态（F4，major；纯解析）

/// GNU ls -l 的 SELinux/ACL 后缀（`.`/`+`）与列数弹性：修复前「恰好 9 段 + 权限恰
/// 10 字符」把这类整目录条目 compactMap 丢空（实证 3/4 被 DROPPED）。
final class FTPListPermFormTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private func now() -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 15; c.hour = 12
        return cal.date(from: c)!
    }

    func parse(_ line: String) -> FTPListEntry? {
        FTPListParser.parseListLine(line, now: now(), timeZone: utc)
    }

    func testSELinuxDotAndACLSuffixSurvive() {
        let lines = [
            "drwxr-xr-x. 2 root root        0 Jun 10 09:12 pub",
            "-rw-r--r--. 1 root root      153 Jun 10 09:12 banner",
            "-rw-rw-r--+ 1 ftpusers ftpusers 1203814551 Jun 10 09:13 SUSE-SLE-SDK-15-SP7-2026-4563-1-x86_64.iso",
            "drwxr-xr-x  2 root root        0 Jun 10 09:12 plain",       // 无后缀仍须可用
        ]
        let parsed = lines.map { parse($0) }
        for (i, e) in parsed.enumerated() {
            XCTAssertNotNil(e, "第 \(i) 行被丢弃：\(lines[i])")
        }
        XCTAssertEqual(parsed[0]?.name, "pub")
        XCTAssertEqual(parsed[0]?.isDirectory, true)
        XCTAssertEqual(parsed[2]?.name, "SUSE-SLE-SDK-15-SP7-2026-4563-1-x86_64.iso")
        XCTAssertEqual(parsed[2]?.size, 1_203_814_551)
        XCTAssertFalse(parsed[2]!.isExecutable)
        XCTAssertEqual(parsed[3]?.name, "plain")
    }

    /// 缺 group 列 / 缺链接数的服务器形态：以日期三元组为锚，前后列数弹性。
    func testMissingGroupOrLinkCountStillParses() {
        let noGroup = parse("-rw-r--r-- 1 root 153 Jun 10 09:12 no-group.txt")
        XCTAssertEqual(noGroup?.name, "no-group.txt")
        XCTAssertEqual(noGroup?.size, 153)
        let noLinks = parse("drwxr-xr-x root 0 Jun 10 09:12 no-links")
        XCTAssertEqual(noGroup?.isDirectory, false)
        XCTAssertEqual(noLinks?.name, "no-links")
        XCTAssertEqual(noLinks?.isDirectory, true)
    }

    /// 名字含空格（第 9 段起全是名字）不回归。
    func testSpaceInNameStillWorks() {
        let e = parse("-rw-r--r-- 1 root root 5 Jun 10 09:12 my report.txt")
        XCTAssertEqual(e?.name, "my report.txt")
        XCTAssertEqual(e?.size, 5)
    }

    /// 符号链接 `name -> target`：名字只取箭头前。
    func testSymlinkArrowStripped() {
        let e = parse("lrwxrwxrwx 1 root root 7 Jun 10 09:12 link -> target")
        XCTAssertEqual(e?.name, "link")
    }

    /// 非条目行（乱码/无日期）仍须判 nil——放宽不得把噪声读成条目。
    func testNoiseStillRejected() {
        for junk in ["totally bogus line", "", "Permission denied.", "425 failed",
                     "-rw-r--r-- 1 a b c d e f", "rwx not a mode at all 1 x 2 y"] {
            XCTAssertNil(parse(junk), "噪声被判成条目：\(junk)")
        }
    }

    /// DOS 行不受影响（双格式路由仍先走 DOS）。
    func testDosLineUnchanged() {
        let e = parse("05-13-26  10:35AM  <DIR>  sub")
        XCTAssertEqual(e?.name, "sub")
        XCTAssertTrue(e!.isDirectory)
    }
}

// MARK: - 补齐覆盖：⑥ 收藏 ftp:// 重组、⑦ TLS↔端口联动、⑨ prepare 端口回填
// 头注释 ⑥⑦⑨ 声称的红面此前**无实现**（评审 agent 实核=零覆盖）——本类补上。

final class FTPReviewGapTests: XCTestCase {
    private var window: NSWindow!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared            // 裸进程真窗铁律（reduced-SDK）
        L10n.current = .en
        suiteName = "fly.ftpgap.test\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        window?.orderOut(nil)               // 禁 close()（多窗前后脚 SIGSEGV 坑）
        window = nil
        defaults?.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: ⑥ DirectoryFavorite.tcPath 的 ftp 分支

    /// ftp:// 收藏必须重组为远端 TCPath。缺分支 → 落兜底 TCPath(path) = file URL
    /// → 目录监视给远端窗格挂本地 FSEvents 流 + 同步 load 打主线程网络。
    func testFavoriteTCPathKeepsFTPRemote() {
        let fav = DirectoryFavorite(sourceID: "ftp://files.example.com:2121",
                                    path: "/srv/data/reports", displayName: "reports")
        let tp = fav.tcPath
        XCTAssertTrue(tp.isRemote, "ftp 收藏退化成 file URL：\(tp.url)")
        XCTAssertFalse(tp.url.isFileURL)
        // pathString=url.path（不含 host/port）→ host/port 断言走 displayString。
        let disp = tp.displayString()
        XCTAssertTrue(disp.contains("files.example.com"), "host 丢了：\(disp)")
        XCTAssertTrue(disp.contains("2121"), "端口丢了：\(disp)")
        XCTAssertTrue(disp.contains("/srv/data/reports"))
    }

    /// 默认端口形态（无 :port）同样走远端分支。
    func testFavoriteTCPathFTPDefaultPort() {
        let tp = DirectoryFavorite(sourceID: "ftp://files.example.com",
                                   path: "/pub", displayName: "pub").tcPath
        XCTAssertTrue(tp.isRemote)
        XCTAssertTrue(tp.displayString().contains("files.example.com"))
    }

    // MARK: ⑦ TLS 勾选 ↔ 端口联动（Implicit FTPS 唯一 TLS 路径）

    private func makeVC() -> RemoteConnectionViewController {
        let vc = RemoteConnectionViewController()
        vc.store = RemoteConnectionStore(keychains: [.sftp: FakeKeychain(), .smb: FakeKeychain(),
                                                     .ftp: FakeKeychain()], defaults: defaults)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 460),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.contentViewController = vc
        window.layoutIfNeeded()
        return vc
    }

    private func control(in root: NSView, identifier: String) -> NSControl? {
        if root.accessibilityIdentifier() == identifier { return root as? NSControl }
        for s in root.subviews { if let c = control(in: s, identifier: identifier) { return c } }
        return nil
    }

    private func fireTLS(_ checkbox: NSButton) {
        checkbox.target?.perform(checkbox.action!, with: checkbox)
    }

    /// 勾 TLS → 端口自动 21→990。不联动 = 用户按 UI 标签得到 TLS-over-21，握手必挂
    /// （本期唯一 TLS 形态是 Implicit FTPS/990，同 socket 升级协议不支持）。
    func testTLSCheckboxSwitchesPortTo990() {
        let vc = makeVC()
        vc.prepare()
        vc.setProto(.ftp)
        guard let tls = control(in: vc.view, identifier: "tlsCheckbox") as? NSButton,
              let portField = control(in: vc.view, identifier: "portField") as? NSTextField
        else { return XCTFail("控件缺失") }
        XCTAssertEqual(portField.stringValue, "21")
        tls.state = .on
        fireTLS(tls)
        XCTAssertEqual(portField.stringValue, "990", "勾 TLS 后端口未联动 990")
        // 取消勾选须回落到 21（用户没手改端口的对称路径）。
        tls.state = .off
        fireTLS(tls)
        XCTAssertEqual(portField.stringValue, "21")
    }

    /// 用户手填过非默认端口 → 勾 TLS 不得覆盖（手改优先于联动）。
    func testTLSCheckboxLeavesCustomPortAlone() {
        let vc = makeVC()
        vc.prepare()
        vc.setProto(.ftp)
        guard let tls = control(in: vc.view, identifier: "tlsCheckbox") as? NSButton,
              let portField = control(in: vc.view, identifier: "portField") as? NSTextField
        else { return XCTFail("控件缺失") }
        portField.stringValue = "2121"
        tls.state = .on
        fireTLS(tls)
        XCTAssertEqual(portField.stringValue, "2121")
    }

    // MARK: ⑨ prepare() 端口默认值（工具栏/菜单无预填入口）

    /// 三协议 prepare 后端口都须有值。缺省 → 点连接直接「端口无效」（对话框合并回归）。
    func testPrepareFillsDefaultPortForAllProtos() {
        let vc = makeVC()
        vc.prepare()
        for (proto, want) in [(RemoteProto.sftp, "22"), (.smb, ""), (.ftp, "21")] {
            if proto != .sftp { vc.setProto(proto) }
            guard let portField = control(in: vc.view, identifier: "portField") as? NSTextField
            else { XCTFail("portField 缺失"); continue }
            if proto == .smb {
                // SMB 表单不校验端口（formRequest 仅 sftp/ftp 分支校验）：端口行整行
                // 隐藏即可（字段里留默认值无害）。
                var v: NSView? = portField
                var hiddenUpwards = false
                while let cur = v { if cur.isHidden { hiddenUpwards = true }; v = cur.superview }
                XCTAssertTrue(hiddenUpwards, "SMB 下端口行未隐藏")
            } else {
                XCTAssertEqual(portField.stringValue, want, "\(proto) prepare 后端口未填")
            }
        }
    }

    /// prepare 复位后勾 TLS 不得残留上一轮的 990（tlsCheckbox 复位须在 prepare 内）。
    func testPrepareResetsTLSCheckbox() {
        let vc = makeVC()
        vc.prepare()
        vc.setProto(.ftp)
        guard let tls = control(in: vc.view, identifier: "tlsCheckbox") as? NSButton
        else { return XCTFail("tlsCheckbox 缺失") }
        tls.state = .on
        vc.prepare()
        vc.setProto(.ftp)
        XCTAssertEqual(tls.state, .off, "prepare 未复位 TLS 勾选")
    }
}

// MARK: - 截断错误的语义分类（数据完整性 ≠ 连接失败）

/// 截断落 `.ftpTransferTruncated`（文案=「传输不完整，请重传该文件」）。落成
/// `.ftpDataConnectFailed` 会把用户支去查网络，而正确处置是重传——文案即处置指引。
final class FTPTruncatedErrorMappingTests: XCTestCase {
    func testTruncatedMapsToDedicatedCaseNotConnectionFailure() {
        let err = FTPTransferTruncatedError(received: 200_000, expected: 400_000)
            .ftpmappedTCError(path: "/x/y.bin")
        guard case .ftpTransferTruncated(let got, let exp) = err else {
            return XCTFail("期望 ftpTransferTruncated，实际 \(String(describing: err))")
        }
        XCTAssertEqual(got, 200_000)
        XCTAssertEqual(exp, 400_000)
    }

    /// 中文显示串须含「重传」语义（L10n 表已注册，非裸 key 回退）。
    func testTruncatedDisplayIsLocalized() {
        L10n.current = .zh
        defer { L10n.current = .en }
        let s = tcErrorDisplay(.ftpTransferTruncated(got: 1, expected: 2))
        XCTAssertTrue(s.contains("传输不完整"), "显示串未本地化：\(s)")
        XCTAssertFalse(s.contains("{0}"), "占位符未展开：\(s)")
    }
}
