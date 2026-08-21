import XCTest
import Foundation
@testable import TCCore

final class TCPathTests: XCTestCase {
    func testParentOfNested() {
        let p = TCPath("/a/b/c")
        XCTAssertEqual(p.parent?.pathString, "/a/b")
    }
    func testRootHasNoParent() {
        XCTAssertEqual(TCPath("/").parent, nil)
    }
    func testJoining() {
        XCTAssertEqual(TCPath("/a/b").joining("c").pathString, "/a/b/c")
    }
    func testIsHiddenDotfile() {
        XCTAssertTrue(TCPath("/a/.zshrc").isHidden)
        XCTAssertFalse(TCPath("/a/file").isHidden)
    }
    func testTildeExpansion() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let p = TCPath("~/dev")
        XCTAssertEqual(p.pathString, home.appendingPathComponent("dev").path)
    }
    func testDisplayStringUsesTilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(TCPath(home + "/dev").displayString(), "~/dev")
        XCTAssertEqual(TCPath(home).displayString(), "~")
    }
}
