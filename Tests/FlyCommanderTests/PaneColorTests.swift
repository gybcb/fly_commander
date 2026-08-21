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
    func testMarkedTextIsWhite() {
        XCTAssertEqual(PaneColor.text(for: .marked, dark: true), NSColor.white)
    }
    func testMarkedBackgroundIsBlue() {
        XCTAssertEqual(PaneColor.background(for: .marked, active: true, dark: false), PaneColor.markedBlue)
    }
    func testFocusTextIsWhite() {
        XCTAssertEqual(PaneColor.text(for: .focus, dark: false), NSColor.white)
    }
    func testFocusBorderIsWhite() {
        XCTAssertEqual(PaneColor.border(for: .focus), NSColor.white)
        XCTAssertNil(PaneColor.border(for: .normal))
        XCTAssertNil(PaneColor.border(for: .marked))
    }
    func testDirectoryBold() {
        XCTAssertTrue(PaneColor.isBold(.directory))
        XCTAssertTrue(PaneColor.isBold(.focus))
        XCTAssertFalse(PaneColor.isBold(.normal))
    }
    func testHiddenTextSecondary() {
        XCTAssertEqual(PaneColor.text(for: .hidden, dark: false), NSColor.secondaryLabelColor)
        XCTAssertEqual(PaneColor.text(for: .readOnly, dark: true), NSColor.secondaryLabelColor)
    }
    func testNormalAndDirectoryUseLabelColor() {
        XCTAssertEqual(PaneColor.text(for: .normal, dark: false), NSColor.labelColor)
        XCTAssertEqual(PaneColor.text(for: .directory, dark: true), NSColor.labelColor)
    }
}
