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
}
