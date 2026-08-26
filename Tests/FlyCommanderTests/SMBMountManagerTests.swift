import XCTest
@testable import FlyCommander
import TCCore

final class SMBMountManagerTests: XCTestCase {
    private func cfg(server: String = "truenas", share: String = "downloads",
                     domain: String? = nil, username: String = "shaogaoyang") -> SMBConnectionConfig {
        SMBConnectionConfig(server: server, share: share, domain: domain, username: username)
    }

    func testMountPointPathSanitized() {
        // 非法字符（. _ / 等）替换成 -
        XCTAssertEqual(SMBMountManager.mountPointPath(cfg(server: "a.b.local", share: "my share")),
                       "/Volumes/FlyCommander/a-b-local--my-share")
        // 常规名保留
        XCTAssertEqual(SMBMountManager.mountPointPath(cfg(server: "truenas", share: "downloads")),
                       "/Volumes/FlyCommander/truenas--downloads")
    }

    func testMountArgsEmbedsCredentialsInURL() {
        let args = SMBMountManager.mountArgs(config: cfg(), secret: "s3cret")
        XCTAssertEqual(args[0], "/sbin/mount_smbfs")
        XCTAssertTrue(args.contains("-N"), "非交互")
        XCTAssertEqual(args[2], "//shaogaoyang:s3cret@truenas/downloads", "user:pass@server/share")
        XCTAssertEqual(args[3], SMBMountManager.mountPointPath(cfg()))
    }

    func testMountArgsWithDomainSeparator() {
        let args = SMBMountManager.mountArgs(config: cfg(domain: "WORKGROUP"), secret: "p")
        XCTAssertEqual(args[2], "//WORKGROUP;shaogaoyang:p@truenas/downloads", "domain;user:pass@")
    }

    func testMountArgsEmptySecretOmitsColon() {
        let args = SMBMountManager.mountArgs(config: cfg(), secret: "")
        XCTAssertEqual(args[2], "//shaogaoyang@truenas/downloads", "无密码 → user@ 不带冒号")
    }

    func testMountArgsPercentEncodesCredentials() {
        // 分隔符 ; @ : 及空格本身是保留字符，必须 percent-encode
        let args = SMBMountManager.mountArgs(config: cfg(username: "we;ird user"), secret: "p a@ss")
        XCTAssertEqual(args[2], "//we%3Bird%20user:p%20a%40ss@truenas/downloads")
        // 合法字符（字母数字 $ - . ! * ' ( )）原样保留
        let args2 = SMBMountManager.mountArgs(config: cfg(username: "a$b-c.d!e"), secret: "p")
        XCTAssertEqual(args2[2], "//a$b-c.d!e:p@truenas/downloads")
    }

    func testRedactRemovesMountURLEcho() {
        let url = "//shaogaoyang:s3cret@truenas/downloads"
        let stderr = "mount_smbfs: //shaogaoyang:s3cret@truenas/downloads: Access denied"
        let out = SMBMountManager.redact(stderr, url: url, secret: "s3cret")
        XCTAssertEqual(out, "mount_smbfs: [REDACTED]: Access denied")
        XCTAssertFalse(out.contains("s3cret"), "错误信息里不得残留密码")
    }

    func testRedactRemovesPercentEncodedAndRawPassword() {
        // mount_smbfs 若只回显密码片段（未带完整 URL），encoded 与 raw 形态都要抹掉
        let stderr = "password p%20a%40ss rejected (tried raw: p a@ss)"
        let out = SMBMountManager.redact(stderr, url: "//u@truenas/downloads", secret: "p a@ss")
        XCTAssertEqual(out, "password *** rejected (tried raw: ***)")
        XCTAssertFalse(out.contains("a@ss"))
    }

    func testRedactNilOrEmptySecretOnlyRemovesURL() {
        let url = "//shaogaoyang@truenas/downloads"
        let stderr = "connect failed for \(url)"
        XCTAssertEqual(SMBMountManager.redact(stderr, url: url, secret: nil),
                       "connect failed for [REDACTED]")
        XCTAssertEqual(SMBMountManager.redact(stderr, url: url, secret: ""),
                       "connect failed for [REDACTED]")
    }

    func testStaleMountsOnlyOwnRoot() {
        let out = """
        devfs on /dev (nfs, local)
        //u@truenas/downloads on /Volumes/downloads (smbfs)
        //u@truenas/downloads on /Volumes/FlyCommander/truenas--downloads (smbfs)
        //x@nas/backup on /Volumes/FlyCommander/nas--backup (smbfs)
        """
        let got = SMBMountManager.staleMounts(fromMountOutput: out)
        XCTAssertEqual(Set(got), Set(["/Volumes/FlyCommander/truenas--downloads",
                                      "/Volumes/FlyCommander/nas--backup"]),
                       "只收 /Volumes/FlyCommander 下，不碰 /Volumes/downloads")
    }

    func testShareIdentifierParsesUserAtServerShare() {
        // 常规 user@server/share
        XCTAssertEqual(
            SMBMountManager.shareIdentifier(
                fromMountLine: "//shaogaoyang@truenas._smb._tcp.local/downloads on /Volumes/downloads (smbfs, nodev, nosuid, mapping=derived)"),
            "truenas._smb._tcp.local/downloads")
        // 带域 + user:pass（分隔符 ; : 与 percent-encode 不影响 lastIndex("@") 取尾部）
        XCTAssertEqual(
            SMBMountManager.shareIdentifier(
                fromMountLine: "//WORKGROUP;user:p%40ss@host/share on /Volumes/share (smbfs)"),
            "host/share")
        // 非 smb 行（无 // 前缀）→ nil
        XCTAssertNil(
            SMBMountManager.shareIdentifier(
                fromMountLine: "/dev/disk3s1 on /Volumes/Macintosh HD (apfs, journaled)"))
    }

    func testShareMountedPointFindsExternalMount() {
        let out = """
        devfs on /dev (nfs, local)
        //shaogaoyang@truenas._smb._tcp.local/downloads on /Volumes/downloads (smbfs, nodev)
        """
        XCTAssertEqual(
            SMBMountManager.shareMountedPoint(server: "truenas._smb._tcp.local",
                                              share: "downloads", fromMountOutput: out),
            "/Volumes/downloads",
            "命中 Finder 已挂载的共享 → 返回其挂载点")
    }

    func testShareMountedPointIgnoresOtherShareAndServer() {
        let out = """
        //u@truenas._smb._tcp.local/videos on /Volumes/videos (smbfs)
        //u@other-host/downloads on /Volumes/downloads (smbfs)
        """
        XCTAssertNil(
            SMBMountManager.shareMountedPoint(server: "truenas._smb._tcp.local",
                                              share: "downloads", fromMountOutput: out),
            "不同共享（videos）/不同服务器（other-host）都不命中")
    }

    func testMountOwnMountPointNotReportedAsExternal() {
        let out = """
        //u@truenas._smb._tcp.local/downloads on /Volumes/FlyCommander/truenas--downloads (smbfs)
        """
        XCTAssertNil(
            SMBMountManager.shareMountedPoint(server: "truenas._smb._tcp.local",
                                              share: "downloads", fromMountOutput: out),
            "已挂在本挂载点（root 下）返回 nil —— 由 isMounted 复用分支处理")
    }

    func testMountReusesExternalMountWithoutCallingMount() throws {
        // Finder 已挂 /Volumes/downloads：mount() 须复用之，绝不触发 runMount。
        let finderLine = """
        //shaogaoyang@truenas._smb._tcp.local/downloads on /Volumes/downloads (smbfs, nodev)
        """
        var mountCalls = 0
        let manager = SMBMountManager(
            runMount: { _ in mountCalls += 1; return (0, "") },
            runList: { finderLine },
            ensureDirectories: { _ in }   // 免触 /Volumes（hermetic）
        )
        let mp = try manager.mount(cfg(server: "truenas._smb._tcp.local", share: "downloads"),
                                   secret: nil)
        XCTAssertEqual(mp, URL(fileURLWithPath: "/Volumes/downloads"), "复用外部挂载点")
        XCTAssertEqual(mountCalls, 0, "外部已挂载 → 不得调用 mount_smbfs")
    }

    func testPutBackMountRemountsAtOriginalExternalPoint() throws {
        // 复用 Finder 卷断连：umount 后须把共享挂回**原挂载点**（/Volumes/downloads），
        // 而不是 app 根 /Volumes/FlyCommander/…（旧实现 _ = try mount(config:) 的 bug）。
        let finderLine = """
        //shaogaoyang@truenas._smb._tcp.local/downloads on /Volumes/downloads (smbfs, nodev, nosuid, mounted by user)
        """
        var unmountArgs: [[String]] = []
        var mountArgs: [[String]] = []
        var ensureCalls = 0
        let manager = SMBMountManager(
            runMount: { args in mountArgs.append(args); return (0, "") },
            runUnmount: { args in unmountArgs.append(args); return (0, "") },
            runList: { finderLine },
            ensureDirectories: { _ in ensureCalls += 1 }   // 外部路径 umount 后目录仍在，不该建目录
        )
        let mp = URL(fileURLWithPath: "/Volumes/downloads")
        try manager.putBackMount(mp,
                                 config: cfg(server: "truenas._smb._tcp.local"),
                                 secret: "pw")
        XCTAssertEqual(unmountArgs, [["/sbin/umount", "-f", "/Volumes/downloads"]], "先强卸原挂载点")
        XCTAssertEqual(mountArgs.count, 1, "重挂恰好一次")
        let args = mountArgs[0]
        XCTAssertEqual(args[3], "/Volumes/downloads", "挂回原挂载点，不是 app 根")
        XCTAssertTrue(args[2].contains("@truenas._smb._tcp.local/downloads"), "URL 仍是同共享")
        XCTAssertEqual(ensureCalls, 0, "原路径（Finder 留下的目录）不需要 ensureDirectories")
    }

    func testPutBackMountInsideRootOnlyUnmounts() throws {
        // app 根内的挂载点：只卸载，不得重挂（app 自己的卷，断连即消失）。
        var mountCalls = 0
        var unmountArgs: [[String]] = []
        let manager = SMBMountManager(
            runMount: { _ in mountCalls += 1; return (0, "") },
            runUnmount: { args in unmountArgs.append(args); return (0, "") },
            runList: { "" },
            ensureDirectories: { _ in }
        )
        try manager.putBackMount(URL(fileURLWithPath: "/Volumes/FlyCommander/truenas--downloads"),
                                 config: cfg(), secret: nil)
        XCTAssertEqual(unmountArgs, [["/sbin/umount", "-f", "/Volumes/FlyCommander/truenas--downloads"]])
        XCTAssertEqual(mountCalls, 0, "root 内挂载点 → 只 unmount，零 runMount")
    }

    func testPutBackMountFailureThrowsWithoutLeakingSecret() {
        // 重挂失败（exit 非 0 且 mount 表里没有该共享）→ 抛错；消息经 redact，不得残留密码/URL。
        var mountArgs: [[String]] = []
        let manager = SMBMountManager(
            runMount: { args in mountArgs.append(args); return (32, "boom") },
            runUnmount: { _ in (0, "") },
            runList: { "" },
            ensureDirectories: { _ in }
        )
        XCTAssertThrowsError(
            try manager.putBackMount(URL(fileURLWithPath: "/Volumes/downloads"),
                                     config: cfg(server: "truenas._smb._tcp.local"), secret: "pw")) { error in
            let tc = asTCError(error)
            guard case .unknown(let m) = tc else {
                return XCTFail("期望 unknown（挂回失败），实际 \(tc)")
            }
            XCTAssertTrue(m.contains("挂回原处失败"), "消息应说明挂回失败：\(m)")
            XCTAssertFalse(m.contains("pw"), "错误信息不得残留密码")
            XCTAssertFalse(m.contains("@truenas._smb._tcp.local/downloads"), "不得残留完整挂载 URL")
        }
        XCTAssertEqual(mountArgs.last?[3], "/Volumes/downloads", "失败分支同样针对原挂载点重挂")
    }

    func testMountPermissionDeniedMessageOnEnsureDirectories() {
        // 无外部挂载 → 走建目录 → /Volumes 不可写（EACCES）→ 一次性 sudo 提示。
        var ensureCalls = 0
        let manager = SMBMountManager(
            runMount: { _ in (0, "") },
            runUnmount: { _ in (0, "") },
            runList: { "" },
            ensureDirectories: { mp in
                ensureCalls += 1
                XCTAssertEqual(mp, "/Volumes/FlyCommander/truenas--downloads")
                throw NSError(domain: NSCocoaErrorDomain,
                              code: NSFileWriteNoPermissionError)
            }
        )
        XCTAssertThrowsError(try manager.mount(cfg(), secret: nil)) { error in
            guard case .permissionDenied(let m) = asTCError(error) else {
                return XCTFail("期望 permissionDenied，实际 \(asTCError(error))")
            }
            XCTAssertTrue(m.contains("sudo mkdir -p /Volumes/FlyCommander"),
                          "应给出一次性提权命令：\(m)")
        }
        XCTAssertEqual(ensureCalls, 1, "无外部挂载时才建目录")
    }
}
