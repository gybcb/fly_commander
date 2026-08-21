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
}
