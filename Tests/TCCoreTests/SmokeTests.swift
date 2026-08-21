import XCTest
@testable import TCCore

final class SmokeTests: XCTestCase {
    func testLibraryLoads() {
        XCTAssertEqual(TCCore.name, "TCCore")
    }
}
