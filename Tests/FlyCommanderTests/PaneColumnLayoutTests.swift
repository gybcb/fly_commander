import XCTest
import Foundation
@testable import FlyCommander

final class PaneColumnLayoutTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: #function + UUID().uuidString)!
        defaults.removeObject(forKey: "fc.col.size")
        defaults.removeObject(forKey: "fc.col.date")
    }

    override func tearDown() {
        defaults.removeObject(forKey: "fc.col.size")
        defaults.removeObject(forKey: "fc.col.date")
        defaults = nil
    }

    func testDefaults() {
        let layout = PaneColumnLayout(defaults: defaults)
        XCTAssertEqual(layout.sizeWidth, 72)
        XCTAssertEqual(layout.dateWidth, 160)
    }

    func testClampsSize() {
        let layout = PaneColumnLayout(defaults: defaults)
        layout.sizeWidth = 5
        XCTAssertEqual(layout.sizeWidth, 40)
        layout.sizeWidth = 999
        XCTAssertEqual(layout.sizeWidth, 400)
        layout.sizeWidth = 120
        XCTAssertEqual(layout.sizeWidth, 120)
    }

    func testClampsDate() {
        let layout = PaneColumnLayout(defaults: defaults)
        layout.dateWidth = 10
        XCTAssertEqual(layout.dateWidth, 80)
        layout.dateWidth = 999
        XCTAssertEqual(layout.dateWidth, 400)
        layout.dateWidth = 200
        XCTAssertEqual(layout.dateWidth, 200)
    }

    func testPersistsAcrossInstances() {
        let a = PaneColumnLayout(defaults: defaults)
        a.sizeWidth = 111
        a.dateWidth = 222
        let b = PaneColumnLayout(defaults: defaults)
        XCTAssertEqual(b.sizeWidth, 111)
        XCTAssertEqual(b.dateWidth, 222)
    }
}
