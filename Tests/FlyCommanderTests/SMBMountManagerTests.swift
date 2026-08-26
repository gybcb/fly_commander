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
}
