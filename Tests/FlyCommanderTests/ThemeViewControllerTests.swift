import XCTest
import AppKit
@testable import FlyCommander
import TCCore

final class ThemeViewControllerTests: XCTestCase {
    func testParseExtensions() {
        XCTAssertEqual(ThemeViewController.parseExtensions("png, jpg, GIF"), ["png", "jpg", "gif"])
        XCTAssertEqual(ThemeViewController.parseExtensions("txt"), ["txt"])
        XCTAssertEqual(ThemeViewController.parseExtensions(" a , , b ,"), ["a", "b"])
        XCTAssertEqual(ThemeViewController.parseExtensions(""), [])
    }

    func testJoinParseRoundTrip() {
        let exts = ["png", "jpg", "gif"]
        XCTAssertEqual(ThemeViewController.parseExtensions(ThemeViewController.joinExtensions(exts)), exts)
    }

    func testAppearanceIndexRoundTrip() {
        for a in Theme.Appearance.allCases {
            XCTAssertEqual(ThemeViewController.appearanceFromIndex(ThemeViewController.appearanceIndex(a)), a)
        }
    }

    func testColorWellToThemeColor() {
        let tc = ThemeViewController.colorWellToThemeColor(NSColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        XCTAssertEqual(tc.red, 0.25, accuracy: 0.01)
        XCTAssertEqual(tc.green, 0.5, accuracy: 0.01)
        XCTAssertEqual(tc.blue, 0.75, accuracy: 0.01)
    }
}
