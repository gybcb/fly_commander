import XCTest
import Foundation
@testable import TCCore

final class FilePaneTests: XCTestCase {
    private let source = LocalFileSource()
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pane_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("dir1"), withIntermediateDirectories: false)
        try FileManager.default.createFile(atPath: tmp.appendingPathComponent("file.txt").path, contents: Data([1,2,3]))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testLoadPopulatesItemsAndSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        var fired = 0
        pane.onReload = { _ in fired += 1 }
        pane.load()
        XCTAssertEqual(pane.itemCount, 2)                 // dir1, file.txt
        XCTAssertEqual(pane.selection.focusIndex, 0)
        XCTAssertEqual(pane.page?.items.first?.name, "dir1")
        XCTAssertEqual(fired, 1)
    }

    func testNavigateAndParent() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 0, mode: .simple)              // focus dir1
        pane.enterFocusedDirectory()
        XCTAssertEqual(pane.path.url.lastPathComponent, "dir1")
        pane.gotoParent()
        XCTAssertEqual(pane.path.url.lastPathComponent, tmp.lastPathComponent)
        XCTAssertEqual(pane.selection.focusIndex, 0)      // navigation resets focus
    }

    func testReloadSameDirectoryPreservesFocus() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 1, mode: .simple)              // focus file.txt
        pane.load()                                       // same directory relist
        XCTAssertEqual(pane.selection.focusIndex, 1)
        XCTAssertTrue(pane.selection.focusID?.hasSuffix("file.txt") ?? false,
                      "focus: \(String(describing: pane.selection.focusID))")
    }

    func testRevealItem() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        let fileID = pane.page!.items[1].id               // file.txt
        XCTAssertTrue(pane.revealItem(id: fileID))
        XCTAssertEqual(pane.selection.focusIndex, 1)
        XCTAssertFalse(pane.revealItem(id: "/no/such/id"))
    }

    func testOperationTargetsUsesSelection() {
        let pane = FilePane(id: .left, source: source, startPath: TCPath(url: tmp))
        pane.load()
        pane.moveFocus(to: 1, mode: .simple)              // focus file.txt
        XCTAssertEqual(pane.operationTargets.map { $0.name }, ["file.txt"])
        pane.toggleMark()                                  // mark file.txt
        pane.moveFocus(to: 0, mode: .additive)            // focus+mark dir1
        XCTAssertEqual(Set(pane.operationTargets.map { $0.name }), ["dir1", "file.txt"])
    }

    func testWorkspaceSwitchActive() {
        let a = FilePane(id: .left, source: source, startPath: TCPath("~"))
        let b = FilePane(id: .right, source: source, startPath: TCPath("~"))
        let ws = Workspace(left: a, right: b, active: .left)
        var fired = 0
        ws.onActiveChange = { _ in fired += 1 }
        XCTAssertEqual(ws.active, .left)
        ws.switchActive()
        XCTAssertEqual(ws.active, .right)
        XCTAssert(ws.activePane === b)
        XCTAssert(ws.inactivePane === a)
        XCTAssertEqual(fired, 1)
    }
}
