import XCTest
import AppKit
import TCCore
@testable import FlyCommander

final class PaneColorTests: XCTestCase {
    func testFocusBackgroundIsNavy() {
        XCTAssertEqual(PaneColor.background(for: .focus, active: true, dark: false), PaneColor.navy)
    }
    func testNonFocusBackgroundClear() {
        XCTAssertEqual(PaneColor.background(for: .normal, active: true, dark: false), NSColor.clear)
    }
    func testMarkedTextIsBlue() {
        XCTAssertEqual(PaneColor.text(for: .marked, dark: true), PaneColor.markedBlue)
    }
    func testFocusTextIsWhite() {
        XCTAssertEqual(PaneColor.text(for: .focus, dark: false), NSColor.white)
    }
    func testDirectoryBold() {
        XCTAssertTrue(PaneColor.isBold(.directory))
        XCTAssertTrue(PaneColor.isBold(.focus))
        XCTAssertFalse(PaneColor.isBold(.normal))
    }
    func testHiddenTextGray() {
        XCTAssertEqual(PaneColor.text(for: .hidden, dark: false), NSColor.gray)
    }
}
