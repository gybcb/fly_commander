import XCTest
import Foundation
@testable import TCCore

final class TCErrorTests: XCTestCase {
    // MARK: - message 稳定英文（内部契约面，非 UI）

    func testMessageForNotFound() {
        XCTAssertEqual(TCError.notFound("/a").message, "Not found: /a")
    }
    func testMessageForPermissionDenied() {
        XCTAssertEqual(TCError.permissionDenied("/a").message, "Permission denied: /a")
    }
    func testMessageForBusy() {
        XCTAssertEqual(TCError.busy("/x").message, "Busy: /x")
    }
    func testMessageForInvalidPath() {
        XCTAssertEqual(TCError.invalidPath("a/b").message, "Invalid path: a/b")
    }
    func testMessageForCancelled() {
        XCTAssertEqual(TCError.cancelled.message, "Cancelled")
    }
    func testMessageForAlreadyExistsWithSubject() {
        XCTAssertEqual(TCError.alreadyExists("a.txt").message, "Already exists: a.txt")
    }
    func testMessageForAlreadyExistsBare() {
        XCTAssertEqual(TCError.alreadyExists(nil).message, "Already exists")
    }
    func testMessageForDirExists() {
        XCTAssertEqual(TCError.dirExists("nd").message, "Directory already exists: nd")
    }
    func testMessageForCrossSourceDir() {
        XCTAssertEqual(TCError.crossSourceDir("sub").message,
                       "Cross-source directory transfer unsupported: sub")
    }
    func testMessageForNoSpace() {
        XCTAssertEqual(TCError.noSpace.message, "No space left on device")
    }
    func testMessageForSFTPNotExecuted() {
        XCTAssertEqual(TCError.sftpNotExecuted.message, "SFTP operation did not execute")
    }
    func testMessageForSMBMountFailed() {
        XCTAssertEqual(TCError.smbMountFailed(code: 7, diag: "boom").message,
                       "SMB mount failed (exit 7): boom")
    }
    func testMessageForPutBackFailed() {
        XCTAssertEqual(TCError.putBackFailed(code: 3, diag: "nope").message,
                       "Put-back mount failed (exit 3): nope")
    }
    func testMessageForUnknownIsPassthrough() {
        XCTAssertEqual(TCError.unknown("File exists").message, "File exists")
    }

    // MARK: - 新语义 case（T3：SMB 路径/挂载点）

    func testMessageForPathOutsideShare() {
        XCTAssertEqual(TCError.pathOutsideShare("/other").message,
                       "Path outside share: /other")
    }
    func testMessageForPathEscaped() {
        XCTAssertEqual(TCError.pathEscaped("/downloads/../../etc").message,
                       "Path escaped the mount point: /downloads/../../etc")
    }
    func testMessageForMountPointNotWritable() {
        // 多行模板：含 \n + 命令行，root 出现 3 次（message 版逐字展开）。
        XCTAssertEqual(TCError.mountPointNotWritable(root: "/Volumes/FlyCommander").message,
                       "Cannot create mount point /Volumes/FlyCommander "
                       + "(/Volumes not writable for current user). Run this once in Terminal:\n"
                       + "sudo mkdir -p /Volumes/FlyCommander && sudo chown \"$(whoami)\" /Volumes/FlyCommander")
    }

    /// diag 截断 200：message 与 l10nArgs 一致（两脸同步）。
    func testDiagTruncatedTo200() {
        let long = String(repeating: "x", count: 300)
        let e = TCError.smbMountFailed(code: 1, diag: long)
        XCTAssertEqual(e.message, "SMB mount failed (exit 1): " + String(repeating: "x", count: 200))
        XCTAssertEqual(e.l10nArgs, ["1", String(repeating: "x", count: 200)])
    }

    // MARK: - l10nKey / l10nArgs（语义键 + 插值参数）

    func testL10nKeyMapping() {
        XCTAssertEqual(TCError.notFound("/a").l10nKey, .errNotFound)
        XCTAssertEqual(TCError.permissionDenied("/a").l10nKey, .errPermissionDenied)
        XCTAssertEqual(TCError.busy("/x").l10nKey, .errBusy)
        XCTAssertEqual(TCError.invalidPath("a/b").l10nKey, .errInvalidPath)
        XCTAssertEqual(TCError.cancelled.l10nKey, .errCancelled)
        XCTAssertEqual(TCError.alreadyExists("a.txt").l10nKey, .errAlreadyExists)
        XCTAssertEqual(TCError.alreadyExists(nil).l10nKey, .errAlreadyExistsBare)
        XCTAssertEqual(TCError.dirExists("nd").l10nKey, .errDirExists)
        XCTAssertEqual(TCError.crossSourceDir("sub").l10nKey, .errCrossSourceDir)
        XCTAssertEqual(TCError.noSpace.l10nKey, .errNoSpace)
        XCTAssertEqual(TCError.sftpNotExecuted.l10nKey, .errSFTPNotExecuted)
        XCTAssertEqual(TCError.smbMountFailed(code: 7, diag: "boom").l10nKey, .errSMBMountFailed)
        XCTAssertEqual(TCError.putBackFailed(code: 3, diag: "nope").l10nKey, .errPutBackFailed)
        XCTAssertEqual(TCError.unknown("boom").l10nKey, .errUnknown)
        XCTAssertEqual(TCError.pathOutsideShare("/other").l10nKey, .errPathOutsideShare)
        XCTAssertEqual(TCError.pathEscaped("/downloads/../../etc").l10nKey, .errPathEscaped)
        XCTAssertEqual(TCError.mountPointNotWritable(root: "/Volumes/FlyCommander").l10nKey,
                       .errMountPointHint)
    }
    func testL10nArgs() {
        XCTAssertEqual(TCError.notFound("/a").l10nArgs, ["/a"])
        XCTAssertEqual(TCError.permissionDenied("/a").l10nArgs, ["/a"])
        XCTAssertEqual(TCError.busy("/x").l10nArgs, ["/x"])
        XCTAssertEqual(TCError.invalidPath("a/b").l10nArgs, ["a/b"])
        XCTAssertEqual(TCError.cancelled.l10nArgs, [])
        XCTAssertEqual(TCError.alreadyExists("a.txt").l10nArgs, ["a.txt"])
        XCTAssertEqual(TCError.alreadyExists(nil).l10nArgs, [])
        XCTAssertEqual(TCError.dirExists("nd").l10nArgs, ["nd"])
        XCTAssertEqual(TCError.crossSourceDir("sub").l10nArgs, ["sub"])
        XCTAssertEqual(TCError.noSpace.l10nArgs, [])
        XCTAssertEqual(TCError.sftpNotExecuted.l10nArgs, [])
        XCTAssertEqual(TCError.smbMountFailed(code: 7, diag: "boom").l10nArgs, ["7", "boom"])
        XCTAssertEqual(TCError.putBackFailed(code: 3, diag: "nope").l10nArgs, ["3", "nope"])
        XCTAssertEqual(TCError.unknown("boom").l10nArgs, ["boom"])
        XCTAssertEqual(TCError.pathOutsideShare("/other").l10nArgs, ["/other"])
        XCTAssertEqual(TCError.pathEscaped("/downloads/../../etc").l10nArgs,
                       ["/downloads/../../etc"])
        // mountPointNotWritable：单参数 root，模板里 {0} 出现 3 次（t() 全量替换）。
        XCTAssertEqual(TCError.mountPointNotWritable(root: "/Volumes/FlyCommander").l10nArgs,
                       ["/Volumes/FlyCommander"])
    }

    // MARK: - Equatable（流控 e == .cancelled 依赖）

    func testCancelledEquality() {
        XCTAssertEqual(TCError.cancelled, TCError.cancelled)
        XCTAssertNotEqual(TCError.cancelled, TCError.noSpace)
    }

    // MARK: - asTCError 映射

    func testPassthrough() {
        XCTAssertEqual(asTCError(TCError.busy("/x")), TCError.busy("/x"))
    }
    func testMapsNoSuchFile() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, userInfo: nil)
        if case .notFound = asTCError(err) {
            // expected
        } else {
            XCTFail("expected .notFound, got \(asTCError(err))")
        }
    }

    /// 256 是 Cocoa 通用读错误（原因不明），映射 invalidPath 会误导用户。
    func testMapsReadUnknownToUnknownNotInvalidPath() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: nil)
        XCTAssertEqual(asTCError(err), .unknown(err.localizedDescription))
        if case .invalidPath = asTCError(err) {
            XCTFail("256 不应映射为 invalidPath")
        }
    }

    func testMapsFileExistsCode() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError, userInfo: nil)
        XCTAssertEqual(asTCError(err), .alreadyExists(nil))
    }

    func testMapsOutOfSpaceCode() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        XCTAssertEqual(asTCError(err), .noSpace)
    }
}
