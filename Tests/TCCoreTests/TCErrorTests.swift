import XCTest
import Foundation
@testable import TCCore

final class TCErrorTests: XCTestCase {
    func testMessageForNotFound() {
        XCTAssertEqual(TCError.notFound("/a").message, "找不到：/a")
    }
    func testMessageForCancelled() {
        XCTAssertEqual(TCError.cancelled.message, "已取消")
    }
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
        XCTAssertEqual(asTCError(err), .unknown("目标已存在同名文件"))
    }

    func testMapsOutOfSpaceCode() {
        let err = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, userInfo: nil)
        XCTAssertEqual(asTCError(err), .unknown("磁盘空间不足"))
    }
}
